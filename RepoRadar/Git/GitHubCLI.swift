import Foundation

/// GitHub's own command-line tool, `gh`, if it's installed. RepoRadar uses it
/// for Put on GitHub, with the account gh is already signed in to, so it never
/// handles a GitHub password or token itself.
struct GitHubCLI: Sendable {
    let executable: URL

    static func locate(fileManager: FileManager = .default) -> GitHubCLI? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where fileManager.isExecutableFile(atPath: path) {
            return GitHubCLI(executable: URL(fileURLWithPath: path))
        }
        return nil
    }

    /// A GitHub repo name from a folder name: letters, digits, ".", "-" and "_"
    static func repoName(for folder: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let mapped = folder.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        let collapsed = mapped.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Creates the GitHub repo, adds it as origin and pushes the current branch
    func publish(_ repo: RepoStatus, name: String, isPrivate: Bool, git: Git) async -> RepoActions.Outcome {
        var environment = Git.environment()
        // gh runs git itself: make it the same git RepoRadar uses
        let gitFolder = git.executable.deletingLastPathComponent().path
        environment["PATH"] = ([gitFolder] + (environment["PATH"].map { [$0] } ?? ["/usr/bin:/bin"])).joined(separator: ":")
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"

        let arguments = ["repo", "create", name, isPrivate ? "--private" : "--public",
                         "--source", repo.path, "--remote", "origin", "--push"]
        let result: Result<Git.Output, Error>
        do {
            result = .success(try await Git.runInBackground(executable: executable, arguments: arguments,
                                                            directory: repo.path, environment: environment, timeout: 120))
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let output) where output.succeeded:
            let page = output.text.split(whereSeparator: \.isWhitespace)
                .first { $0.hasPrefix("https://github.com/") }
                .map { String($0.dropFirst("https://github.com/".count)) }
            return .init(succeeded: true, message: "On GitHub as \(page ?? name).")
        case .success(let output):
            return .init(succeeded: false, message: Self.explain(output.stderr + "\n" + output.text, name: name))
        case .failure(Git.Failure.timedOut):
            return .init(succeeded: false, message: "GitHub took too long to answer.")
        case .failure:
            return .init(succeeded: false, message: "GitHub CLI couldn't run.")
        }
    }

    static func explain(_ output: String, name: String) -> String {
        if output.contains("gh auth login") || output.contains("not logged in") {
            return "GitHub CLI isn't signed in. Run gh auth login in a terminal, then try again."
        }
        if output.contains("Name already exists") || output.contains("already exists on this account") {
            return "You already have a repo called \(name) on GitHub. Pick another name."
        }
        if let connection = RepoActions.explainConnection(output) {
            return connection
        }
        return "Couldn't put it on GitHub: \(RepoActions.firstError(in: output))"
    }
}
