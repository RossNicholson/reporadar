import Foundation

/// The things RepoRadar does to a repo, only when you click them. Each one
/// only ever makes the safe move: Push never forces, Pull only fast-forwards.
enum RepoActions {
    struct Outcome: Equatable, Sendable {
        let succeeded: Bool
        let message: String
    }

    // MARK: - Push

    /// Pushes every branch with commits no remote has: to its upstream, or for
    /// a branch never pushed, to origin (or the only remote), setting it as
    /// the upstream. A branch whose remote branch was deleted is left alone.
    static func push(_ repo: RepoStatus, git: Git) async -> Outcome {
        var pushed: [String] = []
        var problems: [String] = []
        for branch in repo.pushableBranches {
            var arguments = ["push", "--porcelain"]
            if let remote = branch.remote, let remoteRef = branch.remoteRef {
                arguments += [remote, "refs/heads/\(branch.name):\(remoteRef)"]
            } else if let remote = defaultRemote(of: repo) {
                // Only claim it as the upstream if the branch has none (not one tracking a local branch)
                if branch.upstream == nil { arguments.append("--set-upstream") }
                arguments += [remote, "refs/heads/\(branch.name):refs/heads/\(branch.name)"]
            } else {
                problems.append("\(branch.name) was never pushed and this repo has several remotes. Push it once in a terminal to pick one.")
                continue
            }
            do {
                let output = try await git.run(arguments, in: repo.path, timeout: 90)
                if output.succeeded {
                    pushed.append(branch.name)
                } else {
                    problems.append(explainPush(output.stderr + "\n" + output.text, branch: branch.name))
                }
            } catch Git.Failure.timedOut {
                problems.append("Pushing \(branch.name) took too long.")
            } catch {
                problems.append("Git couldn't run.")
            }
        }

        var lines: [String] = []
        if !pushed.isEmpty { lines.append("Pushed \(Reminder.names(pushed)).") }
        lines += problems
        let left = repo.unpushedBranches.filter(\.upstreamGone).map(\.name)
        if !left.isEmpty {
            lines.append("Left \(Reminder.names(left)) alone: \(left.count == 1 ? "its remote branch was" : "their remote branches were") deleted.")
        }
        return Outcome(succeeded: problems.isEmpty && !pushed.isEmpty, message: lines.joined(separator: " "))
    }

    /// origin, or the only remote
    static func defaultRemote(of repo: RepoStatus) -> String? {
        if repo.remotes.contains(where: { $0.name == "origin" }) { return "origin" }
        return repo.remotes.count == 1 ? repo.remotes[0].name : nil
    }

    static func explainPush(_ output: String, branch: String) -> String {
        if output.contains("[rejected]") || output.contains("non-fast-forward") || output.contains("fetch first") {
            return "The remote has commits on \(branch) that you don't have. Pull them in first."
        }
        if output.contains("hook declined") || output.contains("pre-push hook") {
            return "A pre-push hook stopped \(branch) being pushed."
        }
        return explainConnection(output) ?? "Couldn't push \(branch): \(firstError(in: output))"
    }

    // MARK: - Pull

    /// Pulls the current branch, only if that's a fast-forward
    static func pull(_ repo: RepoStatus, git: Git) async -> Outcome {
        do {
            let output = try await git.run(["pull", "--ff-only", "--no-rebase"], in: repo.path, timeout: 90)
            if output.succeeded {
                let n = repo.behind
                return Outcome(succeeded: true, message: "Pulled \(n) commit\(n == 1 ? "" : "s").")
            }
            return Outcome(succeeded: false, message: explainPull(output.stderr + "\n" + output.text))
        } catch Git.Failure.timedOut {
            return Outcome(succeeded: false, message: "Pulling took too long.")
        } catch {
            return Outcome(succeeded: false, message: "Git couldn't run.")
        }
    }

    static func explainPull(_ output: String) -> String {
        if output.contains("would be overwritten") {
            return "Pulling would overwrite files you've changed. Commit or stash them first."
        }
        if output.contains("Not possible to fast-forward") || output.contains("diverg") {
            return "Your branch and the remote have both moved on. Merge or rebase in a terminal."
        }
        return explainConnection(output) ?? "Couldn't pull: \(firstError(in: output))"
    }

    // MARK: - Messages

    /// Sign-in and network failures, which look the same for push, pull and fetch
    static func explainConnection(_ output: String) -> String? {
        let signIn = ["Permission denied", "could not read Username", "Authentication failed",
                      "terminal prompts disabled", "Host key verification failed", "Repository not found"]
        if signIn.contains(where: output.contains) {
            return "Git couldn't sign in to the remote. Try it once in a terminal to check your sign-in."
        }
        if output.contains("Could not resolve host") || output.contains("Connection timed out")
            || output.contains("Operation timed out") {
            return "Couldn't reach the remote. Check your connection."
        }
        return nil
    }

    /// The first "error:" or "fatal:" line, or else the first line
    static func firstError(in output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.first { $0.hasPrefix("error: ") || $0.hasPrefix("fatal: ") } ?? lines.first ?? "unknown error"
        return RepoInspector.shortError(line)
    }
}
