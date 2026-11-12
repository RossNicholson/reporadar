import Foundation

/// Sample repos for screenshots and `-demo YES`
enum Demo {
    static let folder = "/Users/sam/Developer"
    static let unavailable = ["/Volumes/Archive/Projects"]

    static var repos: [RepoStatus] {
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        let github = [RepoStatus.Remote(name: "origin", url: "git@github.com:sam/placeholder.git")]

        var weather = RepoStatus(path: "\(folder)/weather-app")
        weather.branch = "feature/radar-map"
        weather.upstream = "origin/feature/radar-map"
        weather.changed = 4
        weather.untracked = 2
        weather.unpushed = 3
        weather.ahead = 3
        weather.remotes = github
        weather.lastCommit = ago(0.2)
        weather.looseSince = ago(5.3)
        weather.changedFiles = [
            .init(path: "Sources/Map/RadarLayer.swift", kind: .modified),
            .init(path: "Sources/Map/MapView.swift", kind: .modified),
            .init(path: "Sources/Forecast/Hourly.swift", kind: .modified),
            .init(path: "README.md", kind: .modified),
            .init(path: "Sources/Map/Tiles/", kind: .untracked),
            .init(path: "notes.txt", kind: .untracked),
        ]
        weather.unpushedBranches = [
            .init(name: "feature/radar-map", commits: 2, upstream: "origin/feature/radar-map", remote: "origin"),
            .init(name: "fix/rain-icons", commits: 1),
        ]

        var site = RepoStatus(path: "\(folder)/portfolio-site")
        site.branch = "main"
        site.upstream = "origin/main"
        site.operation = .rebasing
        site.conflicts = 1
        site.remotes = github
        site.lastCommit = ago(1)
        site.looseSince = ago(1.2)
        site.changedFiles = [.init(path: "src/pages/about.astro", kind: .conflict)]

        var notes = RepoStatus(path: "\(folder)/recipe-notes")
        notes.branch = "main"
        notes.lastCommit = ago(9)

        var api = RepoStatus(path: "\(folder)/api-server")
        api.branch = "main"
        api.upstream = "origin/main"
        api.unpushed = 1
        api.ahead = 1
        api.remotes = github
        api.lastCommit = ago(2)
        api.looseSince = ago(2)
        api.unpushedBranches = [.init(name: "main", commits: 1, upstream: "origin/main", remote: "origin")]

        var cli = RepoStatus(path: "\(folder)/dotfiles")
        cli.branch = "main"
        cli.upstream = "origin/main"
        cli.behind = 5
        cli.remotes = github
        cli.lastCommit = ago(21)

        var game = RepoStatus(path: "\(folder)/tiny-platformer")
        game.branch = "main"
        game.upstream = "origin/main"
        game.stashes = 2
        game.remotes = github
        game.lastCommit = ago(40)

        let clear = ["blog", "photo-sorter", "budget-sheet", "shortcuts", "home-automation", "lint-config"]
            .enumerated().map { index, name -> RepoStatus in
                var repo = RepoStatus(path: "\(folder)/\(name)")
                repo.branch = "main"
                repo.upstream = "origin/main"
                repo.remotes = github
                repo.lastCommit = ago(Double(index * 6 + 3))
                return repo
            }
        return [weather, site, notes, api, cli, game] + clear
    }
}
