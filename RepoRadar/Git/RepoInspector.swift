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

            // Every commit on a local branch that no remote has. Without a
            // remote that's every commit, which "No remote" already says.
            if repo.hasRemote && repo.hasCommits {
                let count = try await git.run(["rev-list", "--count", "--branches", "--not", "--remotes"], in: path)
                repo.unpushed = Int(count.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        } catch Git.Failure.timedOut {
            repo.error = "git took too long to answer"
        } catch {
            repo.error = "git couldn't run (\(error))"
        }
        repo.operation = operation(in: gitDirectory(for: path))
        return repo
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
            switch field.first {
            case "1": repo.changed += 1
            case "2":
                repo.changed += 1
                index += 1      // a rename's original path follows as its own field
            case "u": repo.conflicts += 1
            case "?": repo.untracked += 1
            default: break
            }
        }
        // git leaves out ahead/behind when the upstream branch no longer exists
        repo.upstreamGone = repo.upstream != nil && !sawAheadBehind
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
