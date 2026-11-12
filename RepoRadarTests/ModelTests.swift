import XCTest
@testable import RepoRadar

final class ParserTests: XCTestCase {
    private func parse(_ fields: [String]) -> RepoStatus {
        var repo = RepoStatus(path: "/tmp/x")
        StatusParser.apply(Data((fields.joined(separator: "\0") + "\0").utf8), to: &repo)
        return repo
    }

    func testBranchHeaders() {
        let repo = parse([
            "# branch.oid 1234abcd", "# branch.head main", "# branch.upstream origin/main",
            "# branch.ab +2 -5", "# stash 3",
        ])
        XCTAssertEqual(repo.branch, "main")
        XCTAssertEqual(repo.upstream, "origin/main")
        XCTAssertEqual(repo.ahead, 2)
        XCTAssertEqual(repo.behind, 5)
        XCTAssertEqual(repo.stashes, 3)
        XCTAssertTrue(repo.hasCommits)
        XCTAssertFalse(repo.upstreamGone)
    }

    func testEntries() {
        let repo = parse([
            "# branch.oid (initial)", "# branch.head (detached)",
            "1 .M N... 100644 100644 100644 aaa bbb file one.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? untracked file.txt", "! ignored.log",
        ])
        XCTAssertFalse(repo.hasCommits)
        XCTAssertNil(repo.branch)
        XCTAssertEqual(repo.changed, 2)
        XCTAssertEqual(repo.conflicts, 1)
        XCTAssertEqual(repo.untracked, 1, "the rename's old path isn't read as an entry")
    }

    func testUpstreamGoneWhenNoAheadBehind() {
        let repo = parse(["# branch.oid abc", "# branch.head feature", "# branch.upstream origin/feature"])
        XCTAssertTrue(repo.upstreamGone)
    }

    func testRemotes() {
        let remotes = StatusParser.remotes("remote.origin.url git@github.com:a/b.git\nremote.my.fork.url https://x.org/y\n")
        XCTAssertEqual(remotes, [.init(name: "origin", url: "git@github.com:a/b.git"), .init(name: "my.fork", url: "https://x.org/y")])
    }

    func testShortError() {
        XCTAssertEqual(RepoInspector.shortError("fatal: not a git repository (or any of the parent directories): .git\n"),
                       "not a git repository (or any of the parent directories): .git")
    }
}

final class RemoteURLTests: XCTestCase {
    func testForms() {
        let cases: [(String, String?)] = [
            ("git@github.com:RossNicholson/reporadar.git", "https://github.com/RossNicholson/reporadar"),
            ("https://github.com/RossNicholson/reporadar.git", "https://github.com/RossNicholson/reporadar"),
            ("https://user:token@github.com/a/b", "https://github.com/a/b"),
            ("ssh://git@github.com:22/a/b.git", "https://github.com/a/b"),
            ("ssh://git@gitlab.example.com/group/sub/project.git", "https://gitlab.example.com/group/sub/project"),
            ("git@bitbucket.org:team/repo.git", "https://bitbucket.org/team/repo"),
            ("github-work:a/b.git", "https://github.com/a/b"),
            ("myserver:repos/thing.git", nil),
            ("/Volumes/Backup/thing.git", nil),
            ("file:///Users/me/thing.git", nil),
            ("../relative.git", nil),
        ]
        for (remote, web) in cases {
            XCTAssertEqual(RemoteURL.web(for: remote)?.absoluteString, web, remote)
        }
    }
}

final class StatusModelTests: XCTestCase {
    private func repo(_ name: String, _ change: (inout RepoStatus) -> Void = { _ in }) -> RepoStatus {
        var repo = RepoStatus(path: "/p/\(name)")
        repo.branch = "main"
        repo.remotes = [.init(name: "origin", url: "git@github.com:a/\(name).git")]
        change(&repo)
        return repo
    }

    func testLevels() {
        XCTAssertEqual(repo("a").level, .clear)
        XCTAssertEqual(repo("a") { $0.stashes = 1 }.level, .stashed)
        XCTAssertEqual(repo("a") { $0.behind = 1 }.level, .behind)
        XCTAssertEqual(repo("a") { $0.unpushed = 1 }.level, .unpushed)
        XCTAssertEqual(repo("a") { $0.remotes = [] }.level, .unpushed)
        XCTAssertEqual(repo("a") { $0.untracked = 1; $0.unpushed = 4 }.level, .uncommitted)
        XCTAssertEqual(repo("a") { $0.changed = 1; $0.operation = .merging }.level, .stuck)
    }

    func testIssueOrder() {
        let issues = repo("a") { $0.stashes = 1; $0.behind = 2; $0.changed = 3; $0.unpushed = 1 }.issues
        XCTAssertEqual(issues, [.changed(3), .unpushed(1), .behind(2), .stashes(1)])
        XCTAssertEqual(Issue.changed(1).tag, "1 changed")
        XCTAssertEqual(Issue.stashes(2).tag, "2 stashes")
    }

    func testSorting() {
        let now = Date()
        let list = RepoStore.sorted([
            repo("clear"),
            repo("old-changes") { $0.changed = 1; $0.lastCommit = now.addingTimeInterval(-9000) },
            repo("unpushed") { $0.unpushed = 1 },
            repo("new-changes") { $0.changed = 1; $0.lastCommit = now },
            repo("merging") { $0.operation = .merging },
        ])
        XCTAssertEqual(list.map(\.name), ["merging", "new-changes", "old-changes", "unpushed", "clear"])
    }

    func testWebURLPrefersOrigin() {
        let r = repo("a") {
            $0.remotes = [.init(name: "upstream", url: "git@github.com:them/a.git"),
                          .init(name: "origin", url: "git@github.com:me/a.git")]
        }
        XCTAssertEqual(r.webURL?.absoluteString, "https://github.com/me/a")
    }

    func testAge() {
        let now = Date()
        XCTAssertEqual(RepoRow.age(of: now.addingTimeInterval(-3600), now: now), "today")
        XCTAssertEqual(RepoRow.age(of: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
        XCTAssertEqual(RepoRow.age(of: now.addingTimeInterval(-21 * 86_400), now: now), "3w ago")
        XCTAssertEqual(RepoRow.age(of: now.addingTimeInterval(-400 * 86_400), now: now), "13mo ago")
        XCTAssertEqual(RepoRow.age(of: now.addingTimeInterval(-800 * 86_400), now: now), "2y ago")
    }
}

@MainActor
final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "RepoRadarTests.\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testFolders() {
        let prefs = Preferences(defaults: defaults)
        prefs.addFolder("/a/projects/web")
        prefs.addFolder("/a/projects/web/")          // same folder
        prefs.addFolder("/a/projects/web/inner")     // inside a watched one
        XCTAssertEqual(prefs.folders, ["/a/projects/web"])
        prefs.addFolder("/a/projects")               // contains it: replaces it
        prefs.addFolder("/b")
        XCTAssertEqual(prefs.folders, ["/a/projects", "/b"])
        prefs.addFolder("/a/projects-old")           // a sibling with a shared prefix is separate
        XCTAssertEqual(prefs.folders, ["/a/projects", "/a/projects-old", "/b"])
        prefs.removeFolder("/b")
        XCTAssertEqual(Preferences(defaults: defaults).folders, ["/a/projects", "/a/projects-old"], "saved")
    }

    func testSnoozeAndIgnore() {
        let prefs = Preferences(defaults: defaults)
        let now = Date()
        prefs.snooze("/r", for: 3600, now: now)
        XCTAssertTrue(prefs.isSnoozed("/r", now: now))
        XCTAssertFalse(prefs.isSnoozed("/r", now: now.addingTimeInterval(3601)))
        prefs.clearEndedSnoozes(now: now.addingTimeInterval(3601))
        XCTAssertNil(prefs.snoozed["/r"])

        prefs.snooze("/r", for: 3600)
        prefs.ignore("/r")
        prefs.ignore("/r")
        XCTAssertEqual(prefs.ignored, ["/r"])
        XCTAssertNil(prefs.snoozed["/r"], "ignoring replaces a snooze")
        prefs.unignore("/r")
        XCTAssertEqual(Preferences(defaults: defaults).ignored, [])
    }

    func testStoreLists() {
        let prefs = Preferences(defaults: defaults)
        let store = RepoStore(prefs: prefs)
        store.showDemo(Demo.repos)
        let attention = store.attention.map(\.name)
        XCTAssertEqual(store.attentionCount, 4)
        XCTAssertEqual(attention.first, "portfolio-site")
        XCTAssertEqual(Set(store.worthALook.map(\.name)), ["dotfiles", "tiny-platformer"])
        XCTAssertEqual(store.clear.count, 6)

        prefs.snooze("\(Demo.folder)/weather-app", for: 3600)
        prefs.ignore("\(Demo.folder)/api-server")
        XCTAssertEqual(store.attentionCount, 2)
        XCTAssertEqual(store.snoozed.map(\.name), ["weather-app"])
        XCTAssertFalse(store.visible.contains { $0.name == "api-server" })
    }
}

final class ReminderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int, day: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testDue() {
        let minutes = 17 * 60 + 30
        XCTAssertFalse(Reminder.isDue(now: date(17, 29), minutes: minutes, lastDay: nil, calendar: calendar))
        XCTAssertTrue(Reminder.isDue(now: date(17, 30), minutes: minutes, lastDay: nil, calendar: calendar))
        XCTAssertTrue(Reminder.isDue(now: date(19, 0), minutes: minutes, lastDay: "2026-11-11", calendar: calendar),
                      "the Mac was asleep at 17:30")
        XCTAssertFalse(Reminder.isDue(now: date(17, 45), minutes: minutes, lastDay: "2026-11-12", calendar: calendar),
                       "already went off today")
        XCTAssertFalse(Reminder.isDue(now: date(21, 0), minutes: minutes, lastDay: nil, calendar: calendar),
                       "too late in the evening")
        XCTAssertFalse(Reminder.isDue(now: date(9, 0, day: 13), minutes: minutes, lastDay: "2026-11-11", calendar: calendar),
                       "never the next morning")
        XCTAssertEqual(Reminder.day(of: date(9, 0, day: 3), calendar: calendar), "2026-11-03")
    }

    func testNames() {
        XCTAssertEqual(Reminder.names(["a"]), "a")
        XCTAssertEqual(Reminder.names(["a", "b"]), "a and b")
        XCTAssertEqual(Reminder.names(["a", "b", "c"]), "a, b and c")
        XCTAssertEqual(Reminder.names(["a", "b", "c", "d", "e"]), "a, b and 3 more")
    }
}

final class DetailAndActionTests: XCTestCase {
    func testParserListsFiles() {
        let output = [
            "# branch.oid abc", "# branch.head main",
            "1 .M N... 100644 100644 100644 aaa bbb src/a file.swift",
            "1 A. N... 000000 100644 100644 000 bbb added.txt",
            "1 D. N... 100644 000000 000000 aaa 000 gone.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc both.txt",
            "? new dir/",
        ].joined(separator: "\0") + "\0"
        var repo = RepoStatus(path: "/r")
        StatusParser.apply(Data(output.utf8), to: &repo)
        XCTAssertEqual(repo.changedFiles, [
            .init(path: "src/a file.swift", kind: .modified),
            .init(path: "added.txt", kind: .added),
            .init(path: "gone.txt", kind: .deleted),
            .init(path: "new name.txt", kind: .renamed),
            .init(path: "both.txt", kind: .conflict),
            .init(path: "new dir/", kind: .untracked),
        ])
        XCTAssertEqual(repo.changed, 4)
        XCTAssertEqual(repo.conflicts, 1)
        XCTAssertEqual(repo.untracked, 1)
    }

    func testParserStopsListingAtTheLimit() {
        let entries = (0..<(StatusParser.fileLimit + 5)).map { "? f\($0).txt" }
        var repo = RepoStatus(path: "/r")
        StatusParser.apply(Data((entries.joined(separator: "\0") + "\0").utf8), to: &repo)
        XCTAssertEqual(repo.changedFiles.count, StatusParser.fileLimit)
        XCTAssertEqual(repo.untracked, StatusParser.fileLimit + 5)
    }

    func testUnpushedBranchesParse() {
        let commits = StatusParser.unpushedCommits("100\trefs/heads/feature\n200\trefs/heads/main\n300\trefs/heads/feature\n")
        XCTAssertEqual(commits.count, 3)
        let refs = [
            "main\torigin/main\t[ahead 1]\torigin\trefs/heads/main",
            "feature\t\t\t\t",
            "old\torigin/old\t[gone]\torigin\trefs/heads/old",
            "local\tmain\t\t.\trefs/heads/main",
        ].joined(separator: "\n")
        let branches = StatusParser.unpushedBranches(commits + [.init(date: Date(), branch: "old"), .init(date: Date(), branch: "local")],
                                                     refs: refs, current: "main")
        XCTAssertEqual(branches.map(\.name), ["main", "feature", "local", "old"])
        XCTAssertEqual(branches[1].commits, 2)
        XCTAssertNil(branches[1].upstream)
        XCTAssertEqual(branches[0].remoteRef, "refs/heads/main")
        XCTAssertTrue(branches[3].upstreamGone)
        XCTAssertEqual(branches[2].upstream, "main")
        XCTAssertNil(branches[2].remote, "a branch tracking a local branch has no remote to push back to")
    }

    func testWaiting() {
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        XCTAssertNil(Waiting.duration(since: ago(0.5), now: now))
        XCTAssertEqual(Waiting.duration(since: ago(1.2), now: now), "1 day")
        XCTAssertEqual(Waiting.duration(since: ago(5), now: now), "5 days")
        XCTAssertEqual(Waiting.duration(since: ago(21), now: now), "3 weeks")
        XCTAssertEqual(Waiting.duration(since: ago(95), now: now), "3 months")
        XCTAssertEqual(Waiting.duration(since: ago(400), now: now), "a year")
        XCTAssertEqual(Waiting.duration(since: ago(1100), now: now), "3 years")
    }

    func testReminderLeadsWithTheOldest() {
        let now = Date()
        var a = RepoStatus(path: "/r/newer")
        a.looseSince = now.addingTimeInterval(-86_400 * 2)
        var b = RepoStatus(path: "/r/older")
        b.looseSince = now.addingTimeInterval(-86_400 * 6)
        let c = RepoStatus(path: "/r/unknown")
        XCTAssertEqual(Reminder.ordered([c, a, b]).map(\.name), ["older", "newer", "unknown"])
        XCTAssertEqual(Reminder.body(for: [c, a, b], now: now),
                       "older, newer and unknown have work that isn't committed or pushed. older has been waiting 6 days.")
        XCTAssertEqual(Reminder.body(for: [a], now: now),
                       "newer has work that isn't committed or pushed. It's been waiting 2 days.")
        XCTAssertEqual(Reminder.body(for: [c], now: now), "unknown has work that isn't committed or pushed.")
    }

    func testWhichActionsApply() {
        var repo = RepoStatus(path: "/r")
        repo.branch = "main"
        repo.upstream = "origin/main"
        repo.remotes = [.init(name: "origin", url: "git@github.com:a/b.git")]
        repo.behind = 2
        XCTAssertTrue(repo.canPull)
        repo.ahead = 1
        XCTAssertFalse(repo.canPull, "diverged: not a fast-forward")
        repo.ahead = 0
        repo.operation = .rebasing
        XCTAssertFalse(repo.canPull)
        repo.operation = nil

        repo.unpushedBranches = [.init(name: "old", commits: 1, upstream: "origin/old", upstreamGone: true)]
        XCTAssertFalse(repo.canPush)
        repo.unpushedBranches.append(.init(name: "new", commits: 1))
        XCTAssertTrue(repo.canPush)
        XCTAssertEqual(repo.pushableBranches.map(\.name), ["new"])

        XCTAssertFalse(repo.canPublish)
        var local = RepoStatus(path: "/r/local")
        XCTAssertTrue(local.canPublish)
        local.hasCommits = false
        XCTAssertFalse(local.canPublish)
    }

    func testDefaultRemote() {
        var repo = RepoStatus(path: "/r")
        repo.remotes = [.init(name: "upstream", url: "u"), .init(name: "origin", url: "o")]
        XCTAssertEqual(RepoActions.defaultRemote(of: repo), "origin")
        repo.remotes = [.init(name: "github", url: "g")]
        XCTAssertEqual(RepoActions.defaultRemote(of: repo), "github")
        repo.remotes = [.init(name: "a", url: "a"), .init(name: "b", url: "b")]
        XCTAssertNil(RepoActions.defaultRemote(of: repo))
    }

    func testMessages() {
        XCTAssertTrue(RepoActions.explainPush(" ! [rejected] main -> main (fetch first)", branch: "main").contains("Pull them in first"))
        XCTAssertTrue(RepoActions.explainPush("git@github.com: Permission denied (publickey).", branch: "main").contains("sign in"))
        XCTAssertTrue(RepoActions.explainPull("fatal: Not possible to fast-forward, aborting.").contains("both moved on"))
        XCTAssertTrue(RepoActions.explainPull("error: Your local changes to the following files would be overwritten by merge").contains("Commit or stash"))
        XCTAssertEqual(RepoActions.firstError(in: "To x\nerror: failed to push some refs\nhint: y"), "failed to push some refs")
        XCTAssertTrue(GitHubCLI.explain("To get started with GitHub CLI, please run:  gh auth login", name: "x").contains("gh auth login"))
        XCTAssertTrue(GitHubCLI.explain("GraphQL: Name already exists on this account (createRepository)", name: "x").contains("already have a repo called x"))
    }

    func testRepoName() {
        XCTAssertEqual(GitHubCLI.repoName(for: "weather-app"), "weather-app")
        XCTAssertEqual(GitHubCLI.repoName(for: "My Project (old)"), "My-Project-old")
        XCTAssertEqual(GitHubCLI.repoName(for: "café_notes.v2"), "caf-_notes.v2")
        XCTAssertEqual(GitHubCLI.repoName(for: "!!!"), "")
    }
}
