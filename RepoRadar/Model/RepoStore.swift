import AppKit
import Combine
import Foundation

/// The repos in the watched folders and their state. Finds them, keeps them
/// up to date as files change, and fetches when asked.
@MainActor
final class RepoStore: ObservableObject {
    @Published private(set) var repos: [RepoStatus] = []
    /// Watched folders that aren't there right now, such as an unplugged drive
    @Published private(set) var unavailableFolders: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var fetchProgress: (done: Int, total: Int)?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var gitMissing = false
    /// Push, Pull or Put on GitHub running in a repo: path → "Pushing…"
    @Published private(set) var working: [String: String] = [:]
    /// How the last one went, until it's dismissed (or, if it worked, a few seconds)
    @Published private(set) var outcomes: [String: RepoActions.Outcome] = [:]

    let prefs: Preferences
    private var git: Git?
    private lazy var watcher = FolderWatcher { [weak self] paths in self?.filesChanged(paths) }
    private var timers: [Timer] = []
    private var cancellables = Set<AnyCancellable>()
    private var refreshing: Set<String> = []
    private var dirty: Set<String> = []
    private var discoveryPending = false
    private var rescanQueued = false
    private var lastDiscovery: Date?
    private var isDemo = false

    var isFetching: Bool { fetchProgress != nil }

    init(prefs: Preferences, git: Git? = nil) {
        self.prefs = prefs
        self.git = git
    }

    // MARK: - What the panel shows

    /// Repos that aren't ignored, in the order they're listed
    var visible: [RepoStatus] {
        repos.filter { !prefs.ignored.contains($0.path) }
    }

    var attention: [RepoStatus] { visible.filter { $0.needsAttention && !prefs.isSnoozed($0.path) } }
    var worthALook: [RepoStatus] { visible.filter { $0.worthALook && !prefs.isSnoozed($0.path) } }
    var clear: [RepoStatus] { visible.filter(\.isClear) }
    var snoozed: [RepoStatus] { visible.filter { !$0.isClear && prefs.isSnoozed($0.path) } }

    var attentionCount: Int { attention.count }

    /// Most pressing first, then the most recently worked on
    nonisolated static func sorted(_ repos: [RepoStatus]) -> [RepoStatus] {
        repos.sorted { a, b in
            if a.level != b.level { return a.level < b.level }
            switch (a.lastCommit, b.lastCommit) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: - Starting

    func start() {
        if git == nil { git = Git.locate() }
        gitMissing = git == nil
        guard !gitMissing else { return }

        prefs.$folders.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.rescan() } }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            workspace.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in Task { await self?.rescan() } }
                .store(in: &cancellables)
        }

        // A safety net under the folder watcher, plus background fetches
        timers = [
            Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = Task { await self?.refreshAll() } }
            },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fetchIfDue() }
            },
        ]
        Task { await rescan() }
    }

    /// Git is installed now (the Command Line Tools finished installing)
    func retryGit() {
        git = Git.locate()
        if git != nil { start() }
    }

    /// On opening the panel: catch up if the last check is over a minute old
    func refreshIfStale() {
        guard !isDemo, !isScanning, lastChecked.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        Task { await refreshAll() }
    }

    // MARK: - Scanning

    /// Find the repos in every watched folder again, then read them all
    func rescan() async {
        guard let git, !isDemo else { return }
        // One scan at a time; asking during one runs another straight after
        guard !isScanning else { rescanQueued = true; return }
        isScanning = true
        defer {
            isScanning = false
            if rescanQueued {
                rescanQueued = false
                Task { await rescan() }
            }
        }

        let folders = prefs.folders
        let found = await Task.detached(priority: .utility) { () -> (repos: [String], missing: [String]) in
            var repos: [String] = []
            var missing: [String] = []
            for folder in folders {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                    missing.append(folder)
                    continue
                }
                repos += RepoScanner.repos(in: folder)
            }
            return (Array(Set(repos)).sorted(), missing)
        }.value
        lastDiscovery = Date()
        unavailableFolders = found.missing
        watcher.watch(folders.filter { !found.missing.contains($0) })

        let statuses = await Self.inspectAll(found.repos, git: git)
        // Keep each repo's last fetch error until its next fetch
        let fetchErrors = Dictionary(repos.compactMap { r in r.fetchError.map { (r.path, $0) } }, uniquingKeysWith: { a, _ in a })
        repos = Self.sorted(statuses.map { status in
            var status = status
            status.fetchError = fetchErrors[status.path]
            return status
        })
        prefs.clearEndedSnoozes()
        lastChecked = Date()
    }

    /// Read every known repo again, without looking for new ones
    func refreshAll() async {
        guard let git, !isDemo else { return }
        // Now and then, look for repos that were cloned or created as well
        if lastDiscovery.map({ Date().timeIntervalSince($0) > 30 * 60 }) ?? true {
            await rescan()
            return
        }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let statuses = await Self.inspectAll(repos.map(\.path), git: git)
        for status in statuses { replace(status) }
        prefs.clearEndedSnoozes()
        lastChecked = Date()
    }

    /// Read some repos again. A repo already being read is read once more
    /// when that finishes, so a change in the middle isn't missed.
    func refresh(_ paths: [String]) async {
        guard let git else { return }
        let todo = paths.filter { !refreshing.contains($0) }
        paths.filter { refreshing.contains($0) }.forEach { dirty.insert($0) }
        guard !todo.isEmpty else { return }
        refreshing.formUnion(todo)
        let statuses = await Self.inspectAll(todo, git: git)
        refreshing.subtract(todo)
        for status in statuses { replace(status) }
        lastChecked = Date()

        let again = dirty.intersection(todo)
        dirty.subtract(again)
        if !again.isEmpty { await refresh(Array(again)) }
    }

    private func replace(_ status: RepoStatus) {
        guard let index = repos.firstIndex(where: { $0.path == status.path }) else { return }
        var status = status
        status.fetchError = repos[index].fetchError
        guard repos[index] != status else { return }
        repos[index] = status
        repos = Self.sorted(repos)
    }

    nonisolated static func inspectAll(_ paths: [String], git: Git, limit: Int = 6) async -> [RepoStatus] {
        await withTaskGroup(of: RepoStatus.self) { group in
            var results: [RepoStatus] = []
            var next = paths.makeIterator()
            for _ in 0..<limit {
                guard let path = next.next() else { break }
                group.addTask { await RepoInspector.inspect(path, git: git) }
            }
            for await status in group {
                results.append(status)
                if let path = next.next() {
                    group.addTask { await RepoInspector.inspect(path, git: git) }
                }
            }
            return results
        }
    }

    // MARK: - Watching

    private func filesChanged(_ paths: [String]) {
        var touched = Set<String>()
        var outside = false
        for path in paths {
            if let repo = repos.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                touched.insert(repo.path)
            } else {
                outside = true
            }
        }
        if !touched.isEmpty { Task { await refresh(Array(touched)) } }
        // A change outside every known repo may be a new one being cloned
        if outside && !discoveryPending {
            discoveryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated {
                    self?.discoveryPending = false
                    Task { await self?.rescan() }
                }
            }
        }
    }

    // MARK: - Fetching

    private func fetchIfDue() {
        let interval = prefs.fetchInterval
        guard interval > 0, !isFetching, !isDemo else { return }
        if let last = prefs.lastFetched, Date().timeIntervalSince(last) < interval { return }
        Task { await fetchAll() }
    }

    /// `git fetch --all --prune` in every repo with a remote, a few at a time
    func fetchAll() async {
        guard let git, !isFetching, !isDemo else { return }
        let targets = visible.filter(\.hasRemote).map(\.path)
        guard !targets.isEmpty else { return }
        fetchProgress = (0, targets.count)
        defer { fetchProgress = nil }

        await withTaskGroup(of: (String, String?).self) { group in
            var next = targets.makeIterator()
            for _ in 0..<4 {
                guard let path = next.next() else { break }
                group.addTask { await Self.fetch(path, git: git) }
            }
            for await (path, error) in group {
                if let index = repos.firstIndex(where: { $0.path == path }) { repos[index].fetchError = error }
                fetchProgress = (min((fetchProgress?.done ?? 0) + 1, targets.count), targets.count)
                if let path = next.next() {
                    group.addTask { await Self.fetch(path, git: git) }
                }
            }
        }
        prefs.lastFetched = Date()
        await refresh(targets)
    }

    nonisolated private static func fetch(_ path: String, git: Git) async -> (String, String?) {
        do {
            let output = try await git.run(["fetch", "--all", "--prune", "--quiet"], in: path, timeout: 90)
            return (path, output.succeeded ? nil : RepoInspector.shortError(output.stderr))
        } catch Git.Failure.timedOut {
            return (path, "the fetch took too long")
        } catch {
            return (path, "git couldn't run")
        }
    }

    // MARK: - Push, Pull, Put on GitHub

    /// Whether Put on GitHub can be offered: it needs GitHub CLI
    var hasGitHubCLI: Bool { isDemo || GitHubCLI.locate() != nil }

    func push(_ repo: RepoStatus) async {
        await perform(repo, "Pushing…") { git in await RepoActions.push(repo, git: git) }
    }

    func pull(_ repo: RepoStatus) async {
        await perform(repo, "Pulling…") { git in await RepoActions.pull(repo, git: git) }
    }

    func publish(_ repo: RepoStatus, name: String, isPrivate: Bool) async {
        guard let gh = GitHubCLI.locate() else {
            outcomes[repo.path] = .init(succeeded: false, message: "GitHub CLI isn't installed. Install it with brew install gh.")
            return
        }
        await perform(repo, "Putting it on GitHub…") { git in
            await gh.publish(repo, name: name, isPrivate: isPrivate, git: git)
        }
    }

    func dismissOutcome(_ path: String) {
        outcomes[path] = nil
    }

    private func perform(_ repo: RepoStatus, _ label: String,
                         _ work: @escaping @Sendable (Git) async -> RepoActions.Outcome) async {
        guard let git, !isDemo, working[repo.path] == nil else { return }
        let path = repo.path
        working[path] = label
        outcomes[path] = nil
        let outcome = await work(git)
        working[path] = nil
        outcomes[path] = outcome
        await refresh([path])
        // A success says so briefly; a problem stays until it's dismissed
        if outcome.succeeded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated {
                    if self?.outcomes[path] == outcome { self?.outcomes[path] = nil }
                }
            }
        }
    }

    // MARK: - Demo

    /// Sample repos without git, for screenshots and checking the design
    func showDemo(_ sample: [RepoStatus], unavailable: [String] = [], outcomes: [String: RepoActions.Outcome] = [:]) {
        isDemo = true
        self.outcomes = outcomes
        repos = Self.sorted(sample)
        unavailableFolders = unavailable
        lastChecked = Date().addingTimeInterval(-12)
    }
}
