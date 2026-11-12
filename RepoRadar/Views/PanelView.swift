import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var store: RepoStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var selfUpdater: SelfUpdater
    @State private var showingSettings = false
    @State private var showingAbout = false
    @State private var showingClear = false
    @State private var showingSnoozed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if store.gitMissing {
                    GitMissingCard()
                } else if prefs.folders.isEmpty {
                    WelcomeCard()
                } else {
                    content
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .menuBarPanel()
    }

    // MARK: - Header

    private var header: some View {
        PanelHeader(title: "Repo Radar", subtitle: headline) {
            ScanningMascot(busy: store.isScanning || store.isFetching,
                           mood: store.attentionCount > 0 ? .alert : .happy)
        } actions: {
            HeaderRefreshButton(isRefreshing: store.isScanning) {
                Task { await store.rescan() }
            }
            .disabled(store.gitMissing || prefs.folders.isEmpty)
            HeaderIconButton(symbol: "gearshape", help: "Settings") {
                showingSettings.toggle()
            }
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SettingsView()
                    .environmentObject(store)
                    .environmentObject(prefs)
                    .environmentObject(selfUpdater)
            }
            HeaderIconButton(symbol: "info", help: "About & help") {
                showingAbout.toggle()
            }
            .popover(isPresented: $showingAbout, arrowEdge: .bottom) {
                AboutPopover(app: .repoRadar) { Mascot(size: 56) }
            }
        }
    }

    private var headline: String {
        if store.gitMissing { return "Needs git to look at your repos" }
        if prefs.folders.isEmpty { return "Your repos' loose ends" }
        if store.repos.isEmpty && store.isScanning { return "Looking for repos…" }
        switch store.attentionCount {
        case 0: return store.visible.isEmpty ? "No repos found yet" : "All clear"
        case 1: return "1 repo needs you"
        case let n: return "\(n) repos need you"
        }
    }

    // MARK: - The list

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.unavailableFolders, id: \.self) { folder in
                    UnavailableCard(folder: folder)
                }

                if store.attention.isEmpty && !store.visible.isEmpty {
                    AllClearCard(count: store.clear.count)
                }
                ForEach(store.attention) { repo in
                    RepoRow(repo: repo)
                }

                if !store.worthALook.isEmpty {
                    SectionLabel(text: "Worth a look")
                        .padding(.top, 6)
                    ForEach(store.worthALook) { repo in
                        RepoRow(repo: repo)
                    }
                }

                if !store.snoozed.isEmpty {
                    disclosure("Snoozed", count: store.snoozed.count, isOpen: $showingSnoozed)
                    if showingSnoozed {
                        ForEach(store.snoozed) { repo in
                            RepoRow(repo: repo, snoozed: true)
                        }
                    }
                }

                // Clear repos fold away under the ones that need something
                if !store.clear.isEmpty {
                    let folded = !store.attention.isEmpty || !store.worthALook.isEmpty || !store.snoozed.isEmpty
                    if folded {
                        disclosure("All clear", count: store.clear.count, isOpen: $showingClear)
                    }
                    if showingClear || !folded {
                        VStack(spacing: 4) {
                            ForEach(store.clear) { repo in
                                ClearRow(repo: repo)
                            }
                        }
                    }
                }

                if store.visible.isEmpty && !store.isScanning && store.unavailableFolders.count < prefs.folders.count {
                    NoReposCard()
                }
            }
            .padding(.horizontal, PanelMetrics.inset)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    private func disclosure(_ title: String, count: Int, isOpen: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                Text("\(title) · \(count)")
                    .font(.mono(9.5, weight: .semibold))
                    .textCase(.uppercase)
                Spacer()
            }
            .foregroundStyle(AppColors.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        PanelFooter {
            HStack(spacing: 10) {
                if !store.gitMissing && !prefs.folders.isEmpty {
                    if let progress = store.fetchProgress {
                        Text("Fetching \(progress.done)/\(progress.total)…")
                    } else {
                        FooterButton(title: "Fetch all", symbol: "arrow.down") {
                            Task { await store.fetchAll() }
                        }
                        .help("Fetch every repo with a remote, so the behind counts are up to date")
                    }
                    statusText
                }
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        if !store.isFetching {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                if let fetched = prefs.lastFetched {
                    Text("Fetched \(Ago.text(since: fetched, now: timeline.date))")
                } else if let checked = store.lastChecked {
                    Text("Checked \(Ago.text(since: checked, now: timeline.date))")
                }
            }
        }
    }
}

/// "just now", "5m ago", "2h ago", "3d ago"
enum Ago {
    static func text(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

// MARK: - Cards

private struct AllClearCard: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Mascot(size: 52, disc: AppColors.surface.opacity(0.6))
            VStack(alignment: .leading, spacing: 3) {
                Text("All clear")
                    .font(.display(24, relativeTo: .title))
                    .textCase(.uppercase)
                Text(count == 1 ? "Your repo is committed and pushed." : "All \(count) repos are committed and pushed.")
                    .font(.mono(10))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .pastelCard(AppColors.mint)
    }
}

private struct UnavailableCard: View {
    @EnvironmentObject private var prefs: Preferences
    let folder: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: folder.hasPrefix("/Volumes/") ? "externaldrive.badge.xmark" : "folder.badge.questionmark")
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mono(10.5, weight: .semibold))
                Text((folder as NSString).abbreviatingWithTildeInPath)
                    .font(.mono(9.5))
                    .opacity(0.7)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .pastelCard(AppColors.lilac, radius: Radius.row)
        .contextMenu {
            Button("Stop Watching This Folder") { prefs.removeFolder(folder) }
        }
    }

    private var title: String {
        if folder.hasPrefix("/Volumes/") {
            let drive = folder.split(separator: "/").dropFirst().first.map(String.init) ?? "The drive"
            return "\(drive) isn't connected"
        }
        return "This folder isn't there any more"
    }
}

private struct NoReposCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No repos found")
                .font(.display(20, relativeTo: .title2))
                .textCase(.uppercase)
            Text("There are no git repos in the folders you're watching. Add another folder in Settings.")
                .font(.mono(10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(AppColors.butter)
    }
}

/// Before any folders are chosen
struct WelcomeCard: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find your loose ends")
                .font(.display(26, relativeTo: .title))
                .textCase(.uppercase)
            Text("Choose the folder your projects live in. Repo Radar finds every git repo inside and shows the ones with work you haven't committed or pushed.")
                .font(.mono(10.5))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(FolderPicker.suggestions, id: \.self) { folder in
                Button {
                    prefs.addFolder(folder)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Watch \((folder as NSString).abbreviatingWithTildeInPath)")
                            .font(.mono(10.5, weight: .semibold))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            PillButton(title: "Choose a folder", symbol: "folder") {
                FolderPicker.choose { prefs.addFolder($0) }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .pastelCard(AppColors.butter)
        .padding(.horizontal, PanelMetrics.inset)
    }
}

/// Git isn't installed: Apple's comes with the Command Line Tools
struct GitMissingCard: View {
    @EnvironmentObject private var store: RepoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git isn't installed")
                .font(.display(26, relativeTo: .title))
                .textCase(.uppercase)
            Text("Repo Radar uses the git on your Mac. Apple's comes with its free Command Line Tools: install them, then check again.")
                .font(.mono(10.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                PillButton(title: "Install", symbol: "arrow.down") {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
                    process.arguments = ["--install"]
                    try? process.run()
                }
                GhostButton(title: "Check again") { store.retryGit() }
            }
        }
        .padding(16)
        .pastelCard(AppColors.coral)
        .padding(.horizontal, PanelMetrics.inset)
    }
}

/// The folder chooser, and folders worth suggesting before anything is chosen
@MainActor
enum FolderPicker {
    static func choose(_ picked: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose the folders your projects live in"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            panel.urls.forEach { picked($0.path) }
        }
    }

    /// Common homes for projects that exist on this Mac
    static var suggestions: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Developer", "Projects", "Code", "code", "src", "dev", "Dev", "GitHub", "Documents/GitHub", "repos", "Sites"]
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .reduce(into: [String]()) { list, path in
                // Case-insensitive disks list "code" and "Code" as the same folder
                if !list.contains(where: { $0.lowercased() == path.lowercased() }) { list.append(path) }
            }
    }
}
