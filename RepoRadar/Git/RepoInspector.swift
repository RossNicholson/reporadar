import Foundation

/// Reads one repo's state with a handful of read-only git commands
enum RepoInspector {
    static func inspect(_ path: String, git: Git) async -> RepoStatus {
        var repo = RepoStatus(path: path)
        do {
            async let status = git.run(["status", "--porcelain=v2", "--branch", "--show-stash", "--untracked-files=normal", "-z"], in: path)
            async let remotes = git.run(["config", "--get-regexp", #"^remote\..*\.url$"#], in: path)
            async let last = git.run(["log", "-1", "--format=%ct"], in: path)

            let statusOutput = try await status
            guard statusOutput.succeeded else {
                repo.error = shortError(statusOutput.stderr)
                return repo
            }
            StatusParser.apply(statusOutput.stdout, to: &repo)
            repo.remotes = StatusParser.remotes(try await remotes.text)
            if let seconds = TimeInterval(try await last.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                repo.lastCommit = Date(timeIntervalSince1970: seconds)
            }

            // Every commit on a local branch that no remote has, with its time
            // and the branch it was found on. Without a remote that's every
            // commit, which "No remote" already says.
            var oldestCommit: Date?
            if repo.hasRemote && repo.hasCommits {
                let log = try await git.run(["log", "--branches", "--not", "--remotes", "--source", "--format=%ct%x09%S"], in: path)
                let commits = StatusParser.unpushedCommits(log.text)
                repo.unpushed = commits.count
                oldestCommit = commits.map(\.date).min()
                if !commits.isEmpty {
                    let refs = try await git.run(["for-each-ref", "refs/heads",
                                                  "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(upstream:remotename)%09%(upstream:remoteref)"],
                                                 in: path)
                    repo.unpushedBranches = StatusParser.unpushedBranches(commits, refs: refs.text, current: repo.branch)
                }
            }
            repo.looseSince = ([oldestCommit] + editDates(of: repo.changedFiles, in: path)).compactMap { $0 }.min()
        } catch Git.Failure.timedOut {
            repo.error = "git took too long to answer"
        } catch {
            repo.error = "git couldn't run (\(error))"
        }
        repo.operation = operation(in: gitDirectory(for: path))
        return repo
    }

    /// When each changed file was last edited. Deleted files have no date.
    static func editDates(of files: [RepoStatus.ChangedFile], in path: String,
                          fileManager: FileManager = .default) -> [Date?] {
        files.filter { $0.kind != .deleted }.map { file in
            let full = (path as NSString).appendingPathComponent(file.path)
            return (try? fileManager.attributesOfItem(atPath: full))?[.modificationDate] as? Date
        }
    }

    /// The repo's .git folder. In a worktree or submodule .git is a file
    /// pointing at the real one.
    static func gitDirectory(for path: String, fileManager: FileManager = .default) -> String? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : ((path as NSString).appendingPathComponent(target) as NSString).standardizingPath
    }

    /// What git is in the middle of, from the marker files it leaves in .git
    static func operation(in gitDirectory: String?, fileManager: FileManager = .default) -> RepoStatus.Operation? {
        guard let gitDirectory else { return nil }
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: (gitDirectory as NSString).appendingPathComponent(name))
        }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebasing }
        if exists("MERGE_HEAD") { return .merging }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        if exists("BISECT_LOG") { return .bisecting }
        return nil
    }

    /// git's first error line, without the "fatal: " prefix
    static func shortError(_ stderr: String) -> String {
        let line = stderr.split(separator: "\n").first.map(String.init) ?? "unknown error"
        for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }
}

/// Reads `git status --porcelain=v2 --branch --show-stash -z`
enum StatusParser {
    /// How many changed files a repo keeps the names of. The counts go on past it.
    static let fileLimit = 200

    static func apply(_ output: Data, to repo: inout RepoStatus) {
        let fields = output.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var sawAheadBehind = false
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            if field.hasPrefix("# ") {
                let parts = field.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let (key, value) = (parts[0], parts[1])
                switch key {
                case "branch.oid": repo.hasCommits = value != "(initial)"
                case "branch.head": repo.branch = value == "(detached)" ? nil : value
                case "branch.upstream": repo.upstream = value
                case "branch.ab":
                    sawAheadBehind = true
                    for number in value.split(separator: " ") {
                        if number.hasPrefix("+") { repo.ahead = Int(number.dropFirst()) ?? 0 }
                        if number.hasPrefix("-") { repo.behind = Int(number.dropFirst()) ?? 0 }
                    }
                case "stash": repo.stashes = Int(value) ?? 0
                default: break
                }
                continue
            }
            // Each entry is space-separated fields, then the path, which may itself have spaces
            func path(after fieldCount: Int) -> String? {
                let parts = field.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
                return parts.count > fieldCount ? String(parts[fieldCount]) : nil
            }
            func add(_ path: String?, _ kind: RepoStatus.ChangedFile.Kind) {
                guard let path, repo.changedFiles.count < fileLimit else { return }
                repo.changedFiles.append(.init(path: path, kind: kind))
            }
            switch field.first {
            case "1":
                repo.changed += 1
                let xy = Array(field.dropFirst(2).prefix(2))
                let kind: RepoStatus.ChangedFile.Kind = xy.first == "A" ? .added : xy.contains("D") ? .deleted : .modified
                add(path(after: 8), kind)
            case "2":
                repo.changed += 1
                add(path(after: 9), .renamed)
                index += 1      // a rename's original path follows as its own field
            case "u":
                repo.conflicts += 1
                add(path(after: 10), .conflict)
            case "?":
                repo.untracked += 1
                add(String(field.dropFirst(2)), .untracked)
            default: break
            }
        }
        // git leaves out ahead/behind when the upstream branch no longer
        // exists, and also before the first commit, when there's nothing to compare
        repo.upstreamGone = repo.upstream != nil && !sawAheadBehind && repo.hasCommits
    }

    struct UnpushedCommit: Equatable {
        let date: Date
        /// The branch git reached it from first
        let branch: String
    }

    /// Reads `git log --source --format=%ct%x09%S`
    static func unpushedCommits(_ output: String) -> [UnpushedCommit] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = TimeInterval(parts[0]) else { return nil }
            let branch = parts[1].hasPrefix("refs/heads/") ? String(parts[1].dropFirst("refs/heads/".count)) : parts[1]
            return UnpushedCommit(date: Date(timeIntervalSince1970: seconds), branch: branch)
        }
    }

    /// The branches the unpushed commits are on, the current one first, with
    /// each one's upstream from `git for-each-ref` (name, upstream, track,
    /// remote, remote branch, tab-separated)
    static func unpushedBranches(_ commits: [UnpushedCommit], refs: String, current: String?) -> [RepoStatus.UnpushedBranch] {
        var upstreams: [String: (upstream: String, track: String, remote: String, remoteRef: String)] = [:]
        for line in refs.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5 else { continue }
            upstreams[parts[0]] = (parts[1], parts[2], parts[3], parts[4])
        }
        let counts = Dictionary(commits.map { ($0.branch, 1) }, uniquingKeysWith: +)
        return counts.map { name, count in
            var branch = RepoStatus.UnpushedBranch(name: name, commits: count)
            if let info = upstreams[name], !info.upstream.isEmpty {
                branch.upstream = info.upstream
                branch.upstreamGone = info.track == "[gone]"
                // "." is a branch tracking another local branch: no remote to push back to
                if info.remote != "." && !info.remote.isEmpty && !info.remoteRef.isEmpty {
                    branch.remote = info.remote
                    branch.remoteRef = info.remoteRef
                }
            }
            return branch
        }
        .sorted { a, b in
            if (a.name == current) != (b.name == current) { return a.name == current }
            if a.commits != b.commits { return a.commits > b.commits }
            return a.name < b.name
        }
    }

    /// Reads `git config --get-regexp ^remote\..*\.url$`
    static func remotes(_ output: String) -> [RepoStatus.Remote] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("remote."), parts[0].hasSuffix(".url") else { return nil }
            let name = String(parts[0].dropFirst("remote.".count).dropLast(".url".count))
            return RepoStatus.Remote(name: name, url: parts[1])
        }
    }
}
