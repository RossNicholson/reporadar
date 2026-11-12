import Foundation

/// Finds the repos inside the watched folders
enum RepoScanner {
    /// Folders that are never worth looking inside: dependencies, build
    /// output and caches, which can hold thousands of folders
    static let skipped: Set<String> = [
        "node_modules", "Library", "DerivedData", "Pods", "Carthage", "build", ".build",
        "dist", "target", "vendor", "venv", ".venv", "__pycache__", "Temp", "Logs", "obj",
        "Intermediate", "Binaries", "Saved", "DerivedDataCache",
    ]

    static let maximumDepth = 6

    /// Every repo under `root`, sorted by path. A repo's own folders aren't
    /// searched further, so submodules and vendored repos inside it don't
    /// show up as repos of their own. `root` itself can be a repo.
    static func repos(in root: String, fileManager: FileManager = .default) -> [String] {
        var found: [String] = []
        search(root, depth: 0, into: &found, fileManager: fileManager)
        return found.sorted()
    }

    private static func search(_ folder: String, depth: Int, into found: inout [String], fileManager: FileManager) {
        if isRepo(folder, fileManager: fileManager) {
            found.append(folder)
            return
        }
        guard depth < maximumDepth,
              let names = try? fileManager.contentsOfDirectory(atPath: folder) else { return }
        for name in names where !name.hasPrefix(".") && !skipped.contains(name) {
            let child = (folder as NSString).appendingPathComponent(name)
            // Real folders only: following links could loop, and packages
            // such as .app bundles aren't projects
            guard let values = try? URL(fileURLWithPath: child).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                  values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { continue }
            search(child, depth: depth + 1, into: &found, fileManager: fileManager)
        }
    }

    /// A folder with a .git folder, or a .git file (a worktree or submodule)
    static func isRepo(_ folder: String, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(".git"))
    }
}
