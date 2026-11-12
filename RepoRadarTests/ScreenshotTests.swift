import XCTest
import SwiftUI
@testable import RepoRadar

/// Renders the panel and its popovers with demo repos, for the website and
/// for checking the design, and draws the app icon. Skipped unless SCREENSHOTS
/// (or ICON_DIR) names an output folder: `make screenshots`, `make icon`.
@MainActor
final class ScreenshotTests: XCTestCase {
    private let suite = "RepoRadarScreenshots"

    private func outputFolder(_ variable: String) throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment[variable], !dir.isEmpty else {
            throw XCTSkip("Set \(variable) to render")
        }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Demo prefs in their own defaults, so the real app's settings are untouched
    private func demo(folders: [String] = [Demo.folder], unavailable: [String] = Demo.unavailable,
                      repos: [RepoStatus] = Demo.repos) -> (RepoStore, Preferences) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.folders = folders + unavailable
        prefs.lastFetched = Date().addingTimeInterval(-25 * 60)
        prefs.editorApp = "com.microsoft.VSCode"
        let store = RepoStore(prefs: prefs)
        store.showDemo(repos, unavailable: unavailable)
        return (store, prefs)
    }

    private func panel(_ store: RepoStore, _ prefs: Preferences) -> some View {
        PanelView()
            .environmentObject(store)
            .environmentObject(prefs)
            .environmentObject(SelfUpdater(app: .repoRadar))
    }

    func testRenderPanel() throws {
        let out = try outputFolder("SCREENSHOTS")
        let size = NSSize(width: 330, height: 600)
        for dark in [false, true] {
            let (store, prefs) = demo()
            try Snapshot.panel(dark: dark, size: size, to: out.appendingPathComponent("panel\(dark ? "-dark" : "-light").png")) {
                panel(store, prefs)
            }
        }
        let clear = Demo.repos.filter(\.isClear)
        let (clearStore, clearPrefs) = demo(unavailable: [], repos: clear)
        try Snapshot.panel(size: NSSize(width: 330, height: 420), to: out.appendingPathComponent("panel-clear.png")) {
            panel(clearStore, clearPrefs)
        }
        let (welcomeStore, welcomePrefs) = demo(folders: [], unavailable: [], repos: [])
        try Snapshot.panel(size: NSSize(width: 330, height: 420), to: out.appendingPathComponent("panel-welcome.png")) {
            panel(welcomeStore, welcomePrefs)
        }
    }

    func testRenderPopovers() throws {
        let out = try outputFolder("SCREENSHOTS")
        for dark in [false, true] {
            let (store, prefs) = demo()
            prefs.ignored = ["\(Demo.folder)/old-experiment"]
            prefs.reminderEnabled = true
            try Snapshot.panel(dark: dark, to: out.appendingPathComponent("panel-settings\(dark ? "-dark" : "").png")) {
                SettingsView()
                    .environmentObject(store)
                    .environmentObject(prefs)
                    .environmentObject(SelfUpdater(app: .repoRadar))
            }
        }
        try Snapshot.panel(to: out.appendingPathComponent("panel-about.png")) {
            AboutPopover(app: .repoRadar, hidingInstalledApps: false) { Mascot(size: 56) }
        }
    }

    func testRenderMascot() throws {
        let out = try outputFolder("SCREENSHOTS")
        try Snapshot.png(Mascot(size: 560, disc: nil).frame(width: 560, height: 560), size: NSSize(width: 560, height: 560),
                         to: out.appendingPathComponent("mascot.png"), transparent: true, exactPixels: true)
        let moods = HStack(spacing: 16) {
            Mascot(mood: .happy, size: 120)
            Mascot(mood: .alert, size: 120)
            Mascot(mood: .happy, size: 120, tilt: -16)
            Mascot(mood: .happy, size: 120, tilt: 16)
            Mascot(size: 40)
        }.padding(20).background(AppColors.ground)
        try Snapshot.png(moods, size: NSSize(width: 680, height: 160), to: out.appendingPathComponent("mascot-moods.png"))
        let icons = HStack(spacing: 12) {
            Image(nsImage: MenuBarIcon.image(blip: false))
            Image(nsImage: MenuBarIcon.image(blip: true))
            Image(nsImage: MenuBarIcon.image(blip: true)).scaleEffect(4).frame(width: 90, height: 90)
        }.padding(10).background(Color.white)
        try Snapshot.png(icons, size: NSSize(width: 180, height: 110), to: out.appendingPathComponent("menubar-icon.png"))
    }

    /// The app icon: the mascot on a butter squircle, at every size
    func testAppIcon() throws {
        let dir = try outputFolder("ICON_DIR")
        let sizes: [(String, CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in sizes {
            try Snapshot.png(AppIcon().frame(width: pixels, height: pixels), size: NSSize(width: pixels, height: pixels),
                             to: dir.appendingPathComponent("\(name).png"), transparent: true, exactPixels: true)
        }
    }
}

/// macOS icon grid: an 824/1024 rounded square with a soft shadow
private struct AppIcon: View {
    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            let tile = side * 824 / 1024
            ZStack {
                RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xF8EAB9), AppColors.butter],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: tile, height: tile)
                    .shadow(color: .black.opacity(0.22), radius: side * 0.012, y: side * 0.01)
                Mascot(size: tile * 0.96, disc: nil)
                    .offset(y: tile * 0.01)
            }
            .frame(width: side, height: side)
        }
    }
}
