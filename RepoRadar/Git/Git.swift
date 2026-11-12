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
        let executable = self.executable
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try Self.runProcess(executable: executable,
                                        arguments: ["-c", "core.quotePath=false", "-c", "color.ui=false"] + arguments,
                                        directory: directory, environment: Self.environment(), timeout: timeout)
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

        do { try process.run() } catch { throw Failure.couldNotStart(error.localizedDescription) }

        // Read both pipes while git runs: one filling up would block it
        let reads = DispatchGroup()
        let collected = Collected()
        DispatchQueue.global(qos: .utility).async(group: reads) {
            collected.stdout = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: reads) {
            collected.stderr = err.fileHandleForReading.readDataToEndOfFile()
        }

        let timer = DispatchWorkItem { [process] in
            if process.isRunning {
                collected.timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        reads.wait()

        if collected.timedOut { throw Failure.timedOut }
        return Output(status: process.terminationStatus, stdout: collected.stdout,
                      stderr: String(decoding: collected.stderr, as: UTF8.self))
    }

    /// Filled in by the reading threads, read once they've all finished
    private final class Collected: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
        var timedOut = false
    }
}
