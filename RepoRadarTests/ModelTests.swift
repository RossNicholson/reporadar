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
