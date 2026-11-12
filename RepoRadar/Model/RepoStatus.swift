import Foundation

/// Everything RepoRadar knows about one repo on this Mac
struct RepoStatus: Identifiable, Equatable, Sendable {
    /// Something git is in the middle of, which needs finishing or aborting
    enum Operation: String, Sendable {
        case merging, rebasing, cherryPicking, reverting, bisecting

        var label: String {
            switch self {
            case .merging: return "Merging"
            case .rebasing: return "Rebasing"
            case .cherryPicking: return "Cherry-picking"
            case .reverting: return "Reverting"
            case .bisecting: return "Bisecting"
            }
        }
    }

    /// The folder the repo lives in, which is also its identity
    let path: String
    var name: String { (path as NSString).lastPathComponent }

    /// The current branch, nil when HEAD is detached
    var branch: String?
    var upstream: String?
    /// The upstream branch was deleted on the remote (often after a merged pull request)
    var upstreamGone = false
    var ahead = 0
    var behind = 0
    /// Tracked files with changes, staged or not
    var changed = 0
    var untracked = 0
    var conflicts = 0
    var stashes = 0
    /// Commits on any local branch that aren't on any remote: the work that
    /// only exists on this Mac
    var unpushed = 0
    var remotes: [Remote] = []
    var operation: Operation?
    var hasCommits = true
    var lastCommit: Date?
    /// Set when git couldn't read the repo at all
    var error: String?
    /// The last background fetch's failure, if it failed
    var fetchError: String?
    /// The files that aren't committed, up to `StatusParser.fileLimit`
    var changedFiles: [ChangedFile] = []
    /// The local branches with commits no remote has
    var unpushedBranches: [UnpushedBranch] = []
    /// When the oldest work that isn't committed or pushed was done: the
    /// oldest changed file's edit or unpushed commit
    var looseSince: Date?

    struct Remote: Equatable, Sendable {
        let name: String
        let url: String
    }

    struct ChangedFile: Equatable, Hashable, Sendable {
        enum Kind: Sendable {
            case modified, added, deleted, renamed, conflict, untracked

            /// The letter `git status --short` would show
            var letter: String {
                switch self {
                case .modified: return "M"
                case .added: return "A"
                case .deleted: return "D"
                case .renamed: return "R"
                case .conflict: return "U"
                case .untracked: return "?"
                }
            }

            var label: String {
                switch self {
                case .modified: return "changed"
                case .added: return "added"
                case .deleted: return "deleted"
                case .renamed: return "renamed"
                case .conflict: return "conflict"
                case .untracked: return "new"
                }
            }
        }

        let path: String
        let kind: Kind
    }

    struct UnpushedBranch: Equatable, Sendable {
        let name: String
        /// Commits on this branch that no remote has
        let commits: Int
        /// e.g. "origin/main", nil if the branch was never pushed
        var upstream: String?
        /// The upstream's remote and branch, for pushing back to it
        var remote: String?
        var remoteRef: String?
        var upstreamGone = false
    }

    var id: String { path }
    var isDetached: Bool { branch == nil && hasCommits }
    var hasChanges: Bool { changed + untracked > 0 }
    var hasRemote: Bool { !remotes.isEmpty }

    /// Work that isn't safe on a remote yet. These repos count in the menu bar.
    var needsAttention: Bool {
        error == nil && (operation != nil || conflicts > 0 || hasChanges || unpushed > 0 || (!hasRemote && hasCommits))
    }

    /// Worth knowing but not your unfinished work: commits to pull, stashes,
    /// a deleted upstream. Shown in the list, not counted.
    var worthALook: Bool {
        !needsAttention && (behind > 0 || stashes > 0 || upstreamGone || error != nil)
    }

    var isClear: Bool { !needsAttention && !worthALook }

    // MARK: - What can be done about it

    /// Branches Push sends. One whose remote branch was deleted is left alone,
    /// so a merged pull request's branch doesn't come back.
    var pushableBranches: [UnpushedBranch] { unpushedBranches.filter { !$0.upstreamGone } }

    var canPush: Bool { error == nil && operation == nil && hasRemote && !pushableBranches.isEmpty }

    /// Only a fast-forward: the current branch is behind and has nothing of its own
    var canPull: Bool {
        error == nil && operation == nil && conflicts == 0 && branch != nil && upstream != nil
            && !upstreamGone && behind > 0 && ahead == 0
    }

    var canPublish: Bool { error == nil && operation == nil && !hasRemote && hasCommits }

    /// What's going on, most pressing first, for the row's tags
    var issues: [Issue] {
        var list: [Issue] = []
        if let error { list.append(.unreadable(error)) }
        if let operation { list.append(.operation(operation)) }
        if conflicts > 0 { list.append(.conflicts(conflicts)) }
        if changed > 0 { list.append(.changed(changed)) }
        if untracked > 0 { list.append(.untracked(untracked)) }
        if unpushed > 0 { list.append(.unpushed(unpushed)) }
        if !hasRemote && hasCommits { list.append(.noRemote) }
        if behind > 0 { list.append(.behind(behind)) }
        if upstreamGone { list.append(.upstreamGone) }
        if stashes > 0 { list.append(.stashes(stashes)) }
        return list
    }

    /// How pressing the repo is, for its colour and its place in the list
    var level: Level {
        if error != nil || operation != nil || conflicts > 0 { return .stuck }
        if hasChanges { return .uncommitted }
        if unpushed > 0 || (!hasRemote && hasCommits) { return .unpushed }
        if behind > 0 || upstreamGone { return .behind }
        if stashes > 0 { return .stashed }
        return .clear
    }

    enum Level: Int, Comparable, Sendable {
        case stuck, uncommitted, unpushed, behind, stashed, clear
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where `Open on GitHub` goes: origin if there is one, else the first remote
    var webURL: URL? {
        let remote = remotes.first { $0.name == "origin" } ?? remotes.first
        return remote.flatMap { RemoteURL.web(for: $0.url) }
    }
}

enum Issue: Equatable, Hashable, Sendable {
    case unreadable(String)
    case operation(RepoStatus.Operation)
    case conflicts(Int)
    case changed(Int)
    case untracked(Int)
    case unpushed(Int)
    case noRemote
    case behind(Int)
    case upstreamGone
    case stashes(Int)

    /// The short tag on the row
    var tag: String {
        switch self {
        case .unreadable: return "Can't read"
        case .operation(let operation): return operation.label
        case .conflicts(let n): return "\(n) conflict\(n == 1 ? "" : "s")"
        case .changed(let n): return "\(n) changed"
        case .untracked(let n): return "\(n) new"
        case .unpushed(let n): return "\(n) unpushed"
        case .noRemote: return "No remote"
        case .behind(let n): return "\(n) behind"
        case .upstreamGone: return "Upstream gone"
        case .stashes(let n): return "\(n) stash\(n == 1 ? "" : "es")"
        }
    }

    /// A sentence for the tag's tooltip and VoiceOver
    var explanation: String {
        switch self {
        case .unreadable(let message): return "Git couldn't read this repo: \(message)"
        case .operation(let operation): return "Git is partway through \(operation.label.lowercased()). Finish it or abort it."
        case .conflicts(let n): return "\(n) file\(n == 1 ? " has" : "s have") merge conflicts."
        case .changed(let n): return "\(n) tracked file\(n == 1 ? " has" : "s have") changes that aren't committed."
        case .untracked(let n): return "\(n) new file\(n == 1 ? "" : "s") or folder\(n == 1 ? "" : "s") git isn't tracking yet."
        case .unpushed(let n): return "\(n) commit\(n == 1 ? " is" : "s are") only on this Mac, not on any remote."
        case .noRemote: return "This repo has no remote, so nothing in it is backed up anywhere else."
        case .behind(let n): return "The remote has \(n) commit\(n == 1 ? "" : "s") you haven't pulled (as of the last fetch)."
        case .upstreamGone: return "This branch's upstream was deleted on the remote, often after a merged pull request."
        case .stashes(let n): return "\(n) stash\(n == 1 ? "" : "es") saved in this repo."
        }
    }
}
