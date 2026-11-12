import SwiftUI

/// Inside an opened row: the branches with commits only on this Mac, and the
/// files that aren't committed
struct RepoDetails: View {
    let repo: RepoStatus
    /// Files listed before "and N more"
    static let fileLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !repo.unpushedBranches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    heading("Not on a remote")
                    ForEach(repo.unpushedBranches, id: \.name) { branch in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(branch.name)
                                .font(.mono(10, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(note(for: branch))
                                .font(.mono(9.5))
                                .opacity(0.72)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if !repo.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    heading("Not committed")
                    ForEach(repo.changedFiles.prefix(Self.fileLimit), id: \.self) { file in
                        FileLine(file: file)
                    }
                    let total = repo.changed + repo.untracked + repo.conflicts
                    if total > Self.fileLimit {
                        Text("and \(total - Self.fileLimit) more")
                            .font(.mono(9.5))
                            .opacity(0.72)
                            .padding(.leading, 20)
                    }
                }
            }
        }
        .foregroundStyle(AppColors.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }

    private struct FileLine: View {
        let file: RepoStatus.ChangedFile

        var body: some View {
            HStack(spacing: 6) {
                Text(file.kind.letter)
                    .font(.mono(8.5, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .background(AppColors.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                    .help(file.kind.label)
                Text(file.path)
                    .font(.mono(10))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(file.path), \(file.kind.label)")
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.mono(8.5, weight: .semibold))
            .textCase(.uppercase)
            .opacity(0.6)
    }

    private func note(for branch: RepoStatus.UnpushedBranch) -> String {
        let commits = "\(branch.commits) commit\(branch.commits == 1 ? "" : "s")"
        if branch.upstreamGone { return "\(commits) · remote branch deleted" }
        if branch.upstream == nil { return "\(commits) · never pushed" }
        return commits
    }
}

/// A small dark pill on a row for Push, Pull or Put on GitHub
struct ActionPill: View {
    let title: String
    let symbol: String
    let foreground: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                Text(title)
                    .font(.mono(9.5, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(AppColors.ink, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

/// How a Push, Pull or Put on GitHub went
struct OutcomeLine: View {
    let outcome: RepoActions.Outcome
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
            Text(outcome.message)
                .font(.mono(9.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if !outcome.succeeded {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .foregroundStyle(AppColors.ink)
        .padding(8)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

/// Asks for a name and private or public before creating the GitHub repo
struct PublishPopover: View {
    let create: (String, Bool) -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var visibility = Visibility.private

    enum Visibility: Hashable { case `private`, `public` }

    init(folder: String, create: @escaping (String, Bool) -> Void, cancel: @escaping () -> Void) {
        self.create = create
        self.cancel = cancel
        _name = State(initialValue: GitHubCLI.repoName(for: folder))
    }

    private var cleanName: String { GitHubCLI.repoName(for: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Put on GitHub")
                .font(.display(18, relativeTo: .headline))
                .textCase(.uppercase)
            Text("Creates a repo on GitHub with GitHub CLI, adds it as origin and pushes the current branch.")
                .font(.mono(10))
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.mono(11))
                .onSubmit { if !cleanName.isEmpty { create(cleanName, visibility == .private) } }
            PillPicker(selection: $visibility, options: [.private, .public], track: AppColors.ground) {
                $0 == .private ? "Private" : "Public"
            }
            HStack {
                GhostButton(title: "Cancel", action: cancel)
                Spacer()
                PillButton(title: "Create", symbol: "arrow.up") {
                    create(cleanName, visibility == .private)
                }
                .disabled(cleanName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
