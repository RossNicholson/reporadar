import Foundation

/// Runs the git that's already on this Mac. Reading a repo never changes it;
/// `fetch` only updates the remote-tracking branches. The only commands that
/// change a repo are the Push and Pull you click (see `RepoActions`).
struct Git: Sendable {
    let executable: URL

    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var succeeded: Bool { status == 0 }
    }

    enum Failure: Error, Equatable {
        case timedOut
        case couldNotStart(String)
    }

    /// Homebrew's git if there is one, otherwise Apple's. Apple's /usr/bin/git
    /// is only a stub until the Command Line Tools (or Xcode) are installed,
    /// and running it then pops up the installer, so it's checked first.
    static func locate(fileManager: FileManager = .default) -> Git? {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: path) {
            return Git(executable: URL(fileURLWithPath: path))
        }
        guard developerToolsInstalled() else { return nil }
        return Git(executable: URL(fileURLWithPath: "/usr/bin/git"))
    }

    private static func developerToolsInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The environment every command runs with. Optional locks off, so
    /// `status` never rewrites the index (which would also wake the folder
    /// watcher); no prompts, so a fetch that needs a password fails instead
    /// of hanging; and plain English output.
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["SSH_ASKPASS"] = "/usr/bin/true"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        return env
    }

    func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 20) async throws -> Output {
        try await Self.runInBackground(executable: executable,
                                       arguments: ["-c", "core.quotePath=false", "-c", "color.ui=false"] + arguments,
                                       directory: directory, environment: Self.environment(), timeout: timeout)
    }

    /// Runs a command on a thread of its own. Waiting for it blocks that
    /// thread, so it stays off the shared dispatch pool, which a few dozen
    /// git commands at once (a refresh and a fetch together) could use up.
    static func runInBackground(executable: URL, arguments: [String], directory: String,
                                environment: [String: String], timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try runProcess(executable: executable, arguments: arguments, directory: directory,
                                   environment: environment, timeout: timeout)
                })
            }
        }
    }

    /// Runs a command to the end, or until the timeout. Shared with `GitHubCLI`.
    static func runProcess(executable: URL, arguments: [String], directory: String,
                           environment: [String: String], timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw Failure.couldNotStart(error.localizedDescription) }

        // Read both pipes while git runs, each on its own thread: one filling
        // up would block git
        let collected = Collected()
        let read = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            collected.stdout = out.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        Thread.detachNewThread {
            collected.stderr = err.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            // Something git started (ssh) may still hold the pipes open, so
            // don't wait long for the rest of its output
            _ = read.wait(timeout: .now() + 2)
            _ = read.wait(timeout: .now() + 2)
            throw Failure.timedOut
        }
        read.wait()
        read.wait()
        return Output(status: process.terminationStatus, stdout: collected.stdout,
                      stderr: String(decoding: collected.stderr, as: UTF8.self))
    }

    /// Filled in by the reading threads, read once they've both finished
    private final class Collected: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
    }
}
