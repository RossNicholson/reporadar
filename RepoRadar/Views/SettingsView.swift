import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: RepoStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var selfUpdater: SelfUpdater

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var loginItemError: String?
    @State private var notificationError: String?

    private let terminals = AppChoice.installedTerminals
    private let editors = AppChoice.installedEditors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Settings", subtitle: "Repo Radar preferences")
                .padding(.bottom, 4)

            foldersCard
            openCard

            SettingCard(title: "Fetch in the background",
                        detail: "Keeps the behind counts up to date. Fetching never changes your files.", below: {
                PillPicker(selection: $prefs.fetchInterval, options: Preferences.fetchIntervals, track: AppColors.ground) {
                    switch $0 {
                    case 0: return "Off"
                    case 15 * 60: return "15 min"
                    default: return "1 hour"
                    }
                }
            })

            SettingToggle(title: "End-of-day reminder", detail: "A notification if repos still need you",
                          isOn: Binding(get: { prefs.reminderEnabled }, set: { setReminder($0) })) {
                if let notificationError {
                    SettingNote(notificationError)
                }
                if prefs.reminderEnabled {
                    DatePicker("At", selection: reminderTime, displayedComponents: .hourAndMinute)
                        .font(.mono(10.5))
                        .datePickerStyle(.field)
                        .fixedSize()
                }
            }

            if !prefs.ignored.isEmpty {
                ignoredCard
            }

            SettingToggle(title: "Launch at login", detail: "Start Repo Radar when you log in",
                          isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                if let loginItemError {
                    SettingNote(loginItemError)
                }
            }

            UpdateBlock(updater: selfUpdater, app: .repoRadar)
        }
        .popoverChrome(width: 300)
    }

    // MARK: - Folders

    private var foldersCard: some View {
        SettingCard(title: "Watched folders", detail: "Repo Radar looks for repos inside these", below: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(prefs.folders, id: \.self) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: store.unavailableFolders.contains(folder) ? "externaldrive.badge.xmark" : "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppColors.secondaryText)
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .font(.mono(10))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(repoCount(in: folder))
                            .font(.mono(9))
                            .foregroundStyle(AppColors.secondaryText)
                        Button {
                            prefs.removeFolder(folder)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Stop watching this folder")
                    }
                }
                GhostButton(title: "Add folder", symbol: "plus") {
                    FolderPicker.choose { prefs.addFolder($0) }
                }
                .padding(.top, 2)
            }
        })
    }

    private func repoCount(in folder: String) -> String {
        if store.unavailableFolders.contains(folder) { return "not connected" }
        let count = store.repos.filter { $0.path == folder || $0.path.hasPrefix(folder + "/") }.count
        return "\(count) repo\(count == 1 ? "" : "s")"
    }

    // MARK: - Opening

    private var openCard: some View {
        SettingCard(title: "Clicking a repo opens it in", detail: "Hover a repo for the others, or right-click it", below: {
            VStack(alignment: .leading, spacing: 8) {
                PillPicker(selection: $prefs.clickAction, options: clickOptions, track: AppColors.ground) {
                    switch $0 {
                    case .finder: return "Finder"
                    case .terminal: return "Terminal"
                    case .editor: return "Editor"
                    }
                }
                appPicker("Terminal", selection: Binding(get: { installed(prefs.terminalApp, in: terminals) },
                                                         set: { prefs.terminalApp = $0 }),
                          choices: terminals)
                if !editors.isEmpty {
                    appPicker("Editor", selection: Binding(get: { installed(prefs.editorApp, in: editors) },
                                                           set: { prefs.editorApp = $0 }),
                              choices: editors)
                }
            }
        })
    }

    /// The chosen app, or the first installed one if it's been removed
    private func installed(_ bundleID: String?, in choices: [AppChoice]) -> String {
        choices.contains { $0.bundleID == bundleID } ? bundleID ?? "" : choices.first?.bundleID ?? ""
    }

    private var clickOptions: [Preferences.ClickAction] {
        editors.isEmpty ? [.finder, .terminal] : Preferences.ClickAction.allCases
    }

    private func appPicker(_ title: String, selection: Binding<String>, choices: [AppChoice]) -> some View {
        HStack {
            Text(title)
                .font(.mono(10))
                .foregroundStyle(AppColors.secondaryText)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(choices) { Text($0.name).tag($0.bundleID) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.mono(10))
            .fixedSize()
        }
    }

    // MARK: - Ignored

    private var ignoredCard: some View {
        SettingCard(title: "Ignored repos", detail: "Never shown or counted", below: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(prefs.ignored, id: \.self) { path in
                    HStack(spacing: 6) {
                        Text((path as NSString).lastPathComponent)
                            .font(.mono(10))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(1)
                            .help(path)
                        Spacer(minLength: 4)
                        Button("Show again") { prefs.unignore(path) }
                            .font(.mono(9.5, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(AppColors.text)
                    }
                }
            }
        })
    }

    // MARK: - Reminder

    private var reminderTime: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: prefs.reminderMinutes / 60, minute: prefs.reminderMinutes % 60,
                                  second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            prefs.reminderMinutes = (parts.hour ?? 17) * 60 + (parts.minute ?? 30)
        }
    }

    private func setReminder(_ enabled: Bool) {
        notificationError = nil
        guard enabled else { prefs.reminderEnabled = false; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                prefs.reminderEnabled = granted
                if !granted { notificationError = "Allow Repo Radar in System Settings → Notifications." }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if enabled && status == .requiresApproval {
            loginItemError = "Allow Repo Radar in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
