import XCTest
@testable import RepoRadar

/// Real git against throwaway repos in a temporary folder: a bare "remote",
/// clones of it, and every state RepoRadar flags
final class GitTests: XCTestCase {
    private var root: URL!
    private var git: Git!

    override func setUpWithError() throws {
        git = try XCTUnwrap(Git.locate(), "these tests need git")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoRadarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths match what git reports
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// Runs git for setting up, ignoring the user's own git config (signing,
    /// hooks, default branch) so the tests behave the same on any Mac
    @discardableResult
    private func sh(_ arguments: [String], in folder: String, allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = git.executable
        process.arguments = ["-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "Test"
        env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"
        env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        env["GIT_EDITOR"] = "true"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if !allowFailure && process.terminationStatus != 0 {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(text)")
        }
        return text
    }

    private func folder(_ name: String) -> String {
        root.appendingPathComponent(name).path
    }

    private func write(_ text: String, to file: String, in repo: String) throws {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(_ file: String, _ text: String, in repo: String) throws {
        try write(text, to: file, in: repo)
        try sh(["add", file], in: repo)
        try sh(["commit", "-m", "Change \(file)"], in: repo)
    }

    /// A bare remote with one commit on main, and a clone of it
    private func clonedRepo(_ name: String = "work") throws -> (remote: String, clone: String) {
        let remote = folder("\(name)-remote.git")
        try sh(["init", "--bare", remote], in: root.path)
        let seed = folder("\(name)-seed")
        try sh(["clone", remote, seed], in: root.path, allowFailure: true)
        try commit("README.md", "hello", in: seed)
        try sh(["push", "origin", "main"], in: seed)
        let clone = folder(name)
        try sh(["clone", remote, clone], in: root.path)
        return (remote, clone)
    }

    private func inspect(_ path: String) async -> RepoStatus {
        await RepoInspector.inspect(path, git: git)
    }

    // MARK: - States

    func testCleanClone() async throws {
        let (_, clone) = try clonedRepo()
        let repo = await inspect(clone)
        XCTAssertNil(repo.error)
        XCTAssertEqual(repo.branch, "main")
        XCTAssertEqual(repo.upstream, "origin/main")
        XCTAssertEqual(repo.remotes.map(\.name), ["origin"])
        XCTAssertEqual(repo.unpushed, 0)
        XCTAssertNotNil(repo.lastCommit)
        XCTAssertTrue(repo.isClear)
        XCTAssertEqual(repo.level, .clear)
        XCTAssertEqual(repo.issues, [])
    }

    func testChangedAndUntracked() async throws {
        let (_, clone) = try clonedRepo()
        try write("changed", to: "README.md", in: clone)
        try write("new", to: "notes.txt", in: clone)
        try write("new", to: "assets/a.png", in: clone)
        try write("staged", to: "staged.txt", in: clone)
        try sh(["add", "staged.txt"], in: clone)
        let repo = await inspect(clone)
        XCTAssertEqual(repo.changed, 2)      // README.md, staged.txt
        XCTAssertEqual(repo.untracked, 2)    // notes.txt, assets/
        XCTAssertTrue(repo.needsAttention)
        XCTAssertEqual(repo.level, .uncommitted)
    }

    func testRenameCountsOnce() async throws {
        let (_, clone) = try clonedRepo()
        try sh(["mv", "README.md", "READ.md"], in: clone)
        let repo = await inspect(clone)
        XCTAssertEqual(repo.changed, 1)
        XCTAssertEqual(repo.untracked, 0)
    }

    func testUnpushedCommits() async throws {
        let (_, clone) = try clonedRepo()
        try commit("a.txt", "a", in: clone)
        try commit("b.txt", "b", in: clone)
        let repo = await inspect(clone)
        XCTAssertEqual(repo.ahead, 2)
        XCTAssertEqual(repo.unpushed, 2)
        XCTAssertEqual(repo.level, .unpushed)
        XCTAssertTrue(repo.needsAttention)
    }

    func testUnpushedOnAnotherBranch() async throws {
        let (_, clone) = try clonedRepo()
        try sh(["switch", "-c", "feature"], in: clone)
        try commit("f.txt", "f", in: clone)
        try sh(["switch", "main"], in: clone)
        let repo = await inspect(clone)
        XCTAssertEqual(repo.ahead, 0)
        XCTAssertEqual(repo.unpushed, 1, "the feature branch's commit is only on this Mac")
        XCTAssertTrue(repo.needsAttention)
    }

    func testNewBranchWithNothingNewIsClear() async throws {
        let (_, clone) = try clonedRepo()
        try sh(["switch", "-c", "empty-branch"], in: clone)
        let repo = await inspect(clone)
        XCTAssertNil(repo.upstream)
        XCTAssertEqual(repo.unpushed, 0)
        XCTAssertFalse(repo.needsAttention)
    }

    func testBehindAfterFetch() async throws {
        let (remote, clone) = try clonedRepo()
        let other = folder("other")
        try sh(["clone", remote, other], in: root.path)
        try commit("x.txt", "x", in: other)
        try sh(["push"], in: other)

        let before = await inspect(clone)
        XCTAssertEqual(before.behind, 0, "nothing's known until a fetch")
        let fetch = try await git.run(["fetch", "--all", "--prune", "--quiet"], in: clone)
        XCTAssertTrue(fetch.succeeded, fetch.stderr)
        let after = await inspect(clone)
        XCTAssertEqual(after.behind, 1)
        XCTAssertFalse(after.needsAttention)
        XCTAssertTrue(after.worthALook)
        XCTAssertEqual(after.level, .behind)
    }

    func testNoRemote() async throws {
        let repoPath = folder("local-only")
        try sh(["init", repoPath], in: root.path)
        try commit("a.txt", "a", in: repoPath)
        let repo = await inspect(repoPath)
        XCTAssertEqual(repo.remotes, [])
        XCTAssertEqual(repo.unpushed, 0)
        XCTAssertTrue(repo.issues.contains(.noRemote))
        XCTAssertTrue(repo.needsAttention)
        XCTAssertEqual(repo.level, .unpushed)
    }

    func testEmptyRepo() async throws {
        let repoPath = folder("empty")
        try sh(["init", repoPath], in: root.path)
        let repo = await inspect(repoPath)
        XCTAssertNil(repo.error)
        XCTAssertFalse(repo.hasCommits)
        XCTAssertEqual(repo.branch, "main")
        XCTAssertNil(repo.lastCommit)
        XCTAssertFalse(repo.needsAttention, "an empty repo with no remote has nothing to lose")
    }

    func testEmptyCloneHasNoGoneUpstream() async throws {
        let remote = folder("bare.git")
        try sh(["init", "--bare", remote], in: root.path)
        let clone = folder("empty-clone")
        try sh(["clone", remote, clone], in: root.path, allowFailure: true)
        try write("x", to: "a.txt", in: clone)
        let repo = await inspect(clone)
        XCTAssertFalse(repo.hasCommits)
        XCTAssertFalse(repo.upstreamGone, "before the first commit there's nothing for the upstream to be")
        XCTAssertEqual(repo.untracked, 1)
        XCTAssertTrue(repo.needsAttention)
    }

    func testStash() async throws {
        let (_, clone) = try clonedRepo()
        try write("wip", to: "README.md", in: clone)
        try sh(["stash"], in: clone)
        let repo = await inspect(clone)
        XCTAssertEqual(repo.stashes, 1)
        XCTAssertEqual(repo.changed, 0)
        XCTAssertTrue(repo.worthALook)
        XCTAssertEqual(repo.level, .stashed)
    }

    func testMergeConflict() async throws {
        let (_, clone) = try clonedRepo()
        try sh(["switch", "-c", "other"], in: clone)
        try commit("README.md", "theirs", in: clone)
        try sh(["switch", "main"], in: clone)
        try commit("README.md", "ours", in: clone)
        try sh(["merge", "other"], in: clone, allowFailure: true)
        let repo = await inspect(clone)
        XCTAssertEqual(repo.operation, .merging)
        XCTAssertEqual(repo.conflicts, 1)
        XCTAssertEqual(repo.level, .stuck)
        XCTAssertEqual(repo.issues.first, .operation(.merging))
    }

    func testRebaseInProgress() async throws {
        let (_, clone) = try clonedRepo()
        try sh(["switch", "-c", "other"], in: clone)
        try commit("README.md", "theirs", in: clone)
        try sh(["switch", "main"], in: clone)
        try commit("README.md", "ours", in: clone)
        try sh(["rebase", "other"], in: clone, allowFailure: true)
        let repo = await inspect(clone)
        XCTAssertEqual(repo.operation, .rebasing)
        XCTAssertNil(repo.branch, "HEAD is detached during a rebase")
    }

    func testDetachedHead() async throws {
        let (_, clone) = try clonedRepo()
        try commit("a.txt", "a", in: clone)
        try sh(["push"], in: clone)
        try sh(["checkout", "--detach", "HEAD~1"], in: clone)
        let repo = await inspect(clone)
        XCTAssertNil(repo.branch)
        XCTAssertTrue(repo.isDetached)
        XCTAssertTrue(repo.isClear)
    }

    func testUpstreamGone() async throws {
        let (_, clone) = try clonedRepo()
        try sh(["switch", "-c", "feature"], in: clone)
        try commit("f.txt", "f", in: clone)
        try sh(["push", "-u", "origin", "feature"], in: clone)
        try sh(["push", "origin", "--delete", "feature"], in: clone)
        try sh(["fetch", "--prune"], in: clone)
        let repo = await inspect(clone)
        XCTAssertEqual(repo.upstream, "origin/feature")
        XCTAssertTrue(repo.upstreamGone)
        XCTAssertTrue(repo.issues.contains(.upstreamGone))
    }

    func testNotARepo() async throws {
        let plain = folder("plain")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let repo = await inspect(plain)
        XCTAssertNotNil(repo.error)
        XCTAssertFalse(repo.needsAttention)
        XCTAssertTrue(repo.worthALook)
    }

    func testWorktreeGitDirectory() async throws {
        let (_, clone) = try clonedRepo()
        let tree = folder("tree")
        try sh(["worktree", "add", tree, "-b", "tree-branch"], in: clone)
        let gitDir = try XCTUnwrap(RepoInspector.gitDirectory(for: tree))
        XCTAssertTrue(gitDir.hasSuffix(".git/worktrees/tree"), gitDir)
        let repo = await inspect(tree)
        XCTAssertEqual(repo.branch, "tree-branch")
    }

    func testStatusDoesNotTouchTheIndex() async throws {
        let (_, clone) = try clonedRepo()
        let index = URL(fileURLWithPath: clone).appendingPathComponent(".git/index")
        // Make the index's cached file times stale, so a normal status would rewrite it
        try write("hello", to: "README.md", in: clone)
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = await inspect(clone)
        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    // MARK: - Finding repos

    func testScannerFindsReposAndSkipsTheRest() throws {
        let projects = folder("Projects")
        for path in ["app", "group/lib", "group/deep/a/b/c", "web/node_modules/pkg", "game/Library/thing"] {
            try sh(["init", "\(projects)/\(path)"], in: root.path)
        }
        // A repo inside a repo (vendored) isn't listed on its own
        try sh(["init", "\(projects)/app/vendor-copy"], in: root.path)
        try FileManager.default.createDirectory(atPath: "\(projects)/empty/folder", withIntermediateDirectories: true)
        // A link to a repo isn't followed
        try FileManager.default.createSymbolicLink(atPath: "\(projects)/link", withDestinationPath: "\(projects)/app")

        let found = RepoScanner.repos(in: projects).map { String($0.dropFirst(projects.count + 1)) }
        XCTAssertEqual(found, ["app", "group/deep/a/b/c", "group/lib"])
    }

    func testScannerRootCanBeARepo() throws {
        let repoPath = folder("solo")
        try sh(["init", repoPath], in: root.path)
        XCTAssertEqual(RepoScanner.repos(in: repoPath), [repoPath])
    }

    func testInspectAllReadsEveryRepo() async throws {
        var paths: [String] = []
        for index in 0..<9 {
            let path = folder("many/r\(index)")
            try sh(["init", path], in: root.path)
            paths.append(path)
        }
        let statuses = await RepoStore.inspectAll(paths, git: git, limit: 3)
        XCTAssertEqual(Set(statuses.map(\.path)), Set(paths))
    }
}
