import SwiftUI

/// The colour of a repo's row, by how pressing it is
extension RepoStatus.Level {
    var fill: Color {
        switch self {
        case .stuck: return AppColors.coral
        case .uncommitted: return AppColors.peach
        case .unpushed: return AppColors.butter
        case .behind: return AppColors.periwinkle
        case .stashed: return AppColors.lilac
        case .clear: return AppColors.mint
        }
    }
}

/// One repo with loose ends: a pastel block with its name, branch and tags.
/// Clicking it opens it; hovering shows quick buttons; right-click has the rest.
/// The chevron shows which branches and files; Push, Pull or Put on GitHub
/// sit underneath when they apply.
struct RepoRow: View {
    @EnvironmentObject private var store: RepoStore
    @EnvironmentObject private var prefs: Preferences
    let repo: RepoStatus
    var snoozed = false
    /// Shows the hover buttons without a mouse, for screenshots
    var previewHover = false
    /// Starts with the details open, for screenshots
    var previewExpanded = false
    @State private var hovered = false
    @State private var expanded = false
    @State private var publishing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.name)
                        .font(.display(18, relativeTo: .headline))
                        .textCase(.uppercase)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.mono(9.5))
                        .opacity(0.72)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    FlowLayout(spacing: 4) {
                        ForEach(repo.issues, id: \.self) { issue in
                            TagPill(text: issue.tag, fill: AppColors.ink, foreground: repo.level.fill)
                                .help(issue.explanation)
                        }
                        if let fetchError = repo.fetchError {
                            TagPill(text: "Fetch failed", fill: AppColors.ink.opacity(0.14), foreground: AppColors.ink)
                                .help("The last fetch failed: \(fetchError)")
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    if hovered || previewHover {
                        quickButtons
                    }
                    if hasDetails {
                        RoundIconButton(symbol: "chevron.down", size: 22, fill: AppColors.ink.opacity(0.1),
                                        foreground: AppColors.ink, help: isExpanded ? "Hide details" : "Show details") {
                            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                        }
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
            }
            if isExpanded {
                RepoDetails(repo: repo)
                    .padding(.top, 8)
            }
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(snoozed ? 0.6 : 1)
        .pastelCard(repo.level.fill, radius: Radius.row)
        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .onHover { hovered = $0 }
        .onTapGesture { openDefault() }
        .contextMenu { RepoMenu(repo: repo, snoozed: snoozed) }
        .help(repo.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(repo.name). \(waitingText.map { "Waiting \($0). " } ?? "")\(repo.issues.map(\.explanation).joined(separator: " "))")
        .accessibilityAction(named: "Open in Finder") { Opener.finder(repo.path) }
        .accessibilityAction(named: "Open in Terminal") { Opener.open(repo.path, in: prefs.terminalApp) }
    }

    private var isExpanded: Bool { expanded || previewExpanded }
    private var hasDetails: Bool { !repo.changedFiles.isEmpty || !repo.unpushedBranches.isEmpty }

    /// How long the oldest loose end has waited, once it's a day or more
    private var waitingText: String? {
        guard repo.needsAttention, let since = repo.looseSince else { return nil }
        return Waiting.duration(since: since)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let branch = repo.branch {
            parts.append(branch)
        } else {
            parts.append("detached HEAD")
        }
        if !repo.hasCommits {
            parts.append("no commits yet")
        }
        if let waiting = waitingText {
            parts.append("waiting \(waiting)")
        } else if let last = repo.lastCommit {
            parts.append(Self.age(of: last))
        }
        return parts.joined(separator: " · ")
    }

    /// "today", "3d ago", "5w ago", "2y ago"
    nonisolated static func age(of date: Date, now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "today"
        case ..<14: return "\(days)d ago"
        case ..<60: return "\(days / 7)w ago"
        case ..<730: return "\(days / 30)mo ago"
        default: return "\(days / 365)y ago"
        }
    }

    private var quickButtons: some View {
        HStack(spacing: 4) {
            RoundIconButton(symbol: "folder", size: 22, fill: AppColors.ink, foreground: repo.level.fill,
                            help: "Open in Finder") { Opener.finder(repo.path) }
            RoundIconButton(symbol: "terminal", size: 22, fill: AppColors.ink, foreground: repo.level.fill,
                            help: "Open in \(AppChoice.named(prefs.terminalApp)?.name ?? "Terminal")") {
                Opener.open(repo.path, in: prefs.terminalApp)
            }
            if let editor = AppChoice.named(prefs.editorApp), editor.isInstalled {
                RoundIconButton(symbol: "chevron.left.forwardslash.chevron.right", size: 22, fill: AppColors.ink,
                                foreground: repo.level.fill, help: "Open in \(editor.name)") {
                    Opener.open(repo.path, in: editor.bundleID)
                }
            }
        }
    }

    // MARK: - Push, Pull, Put on GitHub

    private var offersPublish: Bool { repo.canPublish && store.hasGitHubCLI }

    @ViewBuilder private var actions: some View {
        let working = store.working[repo.path]
        let outcome = store.outcomes[repo.path]
        if working != nil || outcome != nil || repo.canPush || repo.canPull || offersPublish {
            VStack(alignment: .leading, spacing: 6) {
                if let working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(working).font(.mono(9.5, weight: .semibold))
                    }
                    .frame(height: 22)
                } else if repo.canPush || repo.canPull || offersPublish {
                    HStack(spacing: 6) {
                        if repo.canPull {
                            ActionPill(title: "Pull", symbol: "arrow.down", foreground: repo.level.fill,
                                       help: "Bring in \(repo.behind) commit\(repo.behind == 1 ? "" : "s") from \(repo.upstream ?? "the remote") (fast-forward only)") {
                                Task { await store.pull(repo) }
                            }
                        }
                        if repo.canPush {
                            ActionPill(title: "Push", symbol: "arrow.up", foreground: repo.level.fill, help: pushHelp) {
                                Task { await store.push(repo) }
                            }
                        }
                        if offersPublish {
                            ActionPill(title: "Put on GitHub", symbol: "arrow.up.to.line", foreground: repo.level.fill,
                                       help: "Create a GitHub repo for this and push it") {
                                publishing = true
                            }
                            .popover(isPresented: $publishing, arrowEdge: .bottom) {
                                PublishPopover(folder: repo.name) { name, isPrivate in
                                    publishing = false
                                    Task { await store.publish(repo, name: name, isPrivate: isPrivate) }
                                } cancel: {
                                    publishing = false
                                }
                            }
                        }
                    }
                }
                if let outcome {
                    OutcomeLine(outcome: outcome) { store.dismissOutcome(repo.path) }
                }
            }
            .padding(.top, 8)
        }
    }

    private var pushHelp: String {
        let names = repo.pushableBranches.map(\.name)
        return "Push \(Reminder.names(names)) (never forced)"
    }

    private func openDefault() {
        switch prefs.clickAction {
        case .finder: Opener.finder(repo.path)
        case .terminal: Opener.open(repo.path, in: prefs.terminalApp)
        case .editor: Opener.open(repo.path, in: prefs.editorApp)
        }
    }
}

/// A repo's right-click menu
struct RepoMenu: View {
    @EnvironmentObject private var prefs: Preferences
    let repo: RepoStatus
    var snoozed = false

    var body: some View {
        Button("Open in Finder") { Opener.finder(repo.path) }
        Button("Open in \(AppChoice.named(prefs.terminalApp)?.name ?? "Terminal")") {
            Opener.open(repo.path, in: prefs.terminalApp)
        }
        ForEach(AppChoice.installedEditors) { editor in
            Button("Open in \(editor.name)") { Opener.open(repo.path, in: editor.bundleID) }
        }
        if let web = repo.webURL {
            Button("Open on \(web.host == "github.com" ? "GitHub" : web.host ?? "the web")") { Opener.web(web) }
        }
        Button("Copy Path") { Opener.copyPath(repo.path) }
        Divider()
        if snoozed {
            Button("Stop Snoozing") { prefs.wake(repo.path) }
        } else if !repo.isClear {
            Button("Snooze for a Day") { prefs.snooze(repo.path, for: 86_400) }
            Button("Snooze for a Week") { prefs.snooze(repo.path, for: 7 * 86_400) }
        }
        Button("Ignore This Repo") { prefs.ignore(repo.path) }
    }
}

/// A clear repo: one compact line
struct ClearRow: View {
    @EnvironmentObject private var prefs: Preferences
    let repo: RepoStatus
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(AppColors.toggle).frame(width: 6, height: 6)
            Text(repo.name)
                .font(.mono(10.5, weight: .semibold))
                .foregroundStyle(AppColors.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(repo.branch ?? "detached")
                .font(.mono(9.5))
                .foregroundStyle(AppColors.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .card(hovered: hovered, radius: Radius.small)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            switch prefs.clickAction {
            case .finder: Opener.finder(repo.path)
            case .terminal: Opener.open(repo.path, in: prefs.terminalApp)
            case .editor: Opener.open(repo.path, in: prefs.editorApp)
            }
        }
        .contextMenu { RepoMenu(repo: repo) }
        .help(repo.path)
    }
}

/// Lays out tags left to right, wrapping onto new lines
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
