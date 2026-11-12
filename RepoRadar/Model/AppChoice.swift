import AppKit

/// The terminals and editors a repo can open in, when they're installed
struct AppChoice: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    static let terminals: [AppChoice] = [
        AppChoice(bundleID: "com.apple.Terminal", name: "Terminal"),
        AppChoice(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        AppChoice(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        AppChoice(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        AppChoice(bundleID: "net.kovidgoyal.kitty", name: "kitty"),
        AppChoice(bundleID: "com.github.wez.wezterm", name: "WezTerm"),
        AppChoice(bundleID: "org.alacritty", name: "Alacritty"),
    ]

    static let editors: [AppChoice] = [
        AppChoice(bundleID: "com.microsoft.VSCode", name: "VS Code"),
        AppChoice(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        AppChoice(bundleID: "com.exafunction.windsurf", name: "Windsurf"),
        AppChoice(bundleID: "dev.zed.Zed", name: "Zed"),
        AppChoice(bundleID: "com.sublimetext.4", name: "Sublime Text"),
        AppChoice(bundleID: "com.panic.Nova", name: "Nova"),
        AppChoice(bundleID: "com.barebones.bbedit", name: "BBEdit"),
        AppChoice(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
    ]

    static let defaultTerminal = "com.apple.Terminal"

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }

    static var installedTerminals: [AppChoice] { terminals.filter(\.isInstalled) }
    static var installedEditors: [AppChoice] { editors.filter(\.isInstalled) }

    static func named(_ bundleID: String?) -> AppChoice? {
        guard let bundleID else { return nil }
        return (terminals + editors).first { $0.bundleID == bundleID }
    }
}

/// Opening a repo somewhere
@MainActor
enum Opener {
    static func finder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func open(_ path: String, in bundleID: String?) {
        guard let app = AppChoice.named(bundleID)?.appURL
                ?? bundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) else {
            finder(path)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: app,
                                configuration: configuration)
    }

    static func web(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
