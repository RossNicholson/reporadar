// The shared look (colours, fonts, buttons, cards, the menu bar panel and the
// updater) lives in the HouseStyle package, shared with Ross's other Mac apps.
// Re-exported so every file here can use it without its own import.
@_exported import HouseStyle

extension AppInfo {
    static let repoRadar = AppInfo(name: "RepoRadar", repo: "reporadar", cask: "reporadar",
                                   coffeeLine: "If RepoRadar catches your loose ends")
}
