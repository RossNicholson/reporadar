import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanelController!
    private var cancellables = Set<AnyCancellable>()
    private var reminderTimer: Timer?
    let prefs = Preferences()
    lazy var store = RepoStore(prefs: prefs)
    let selfUpdater = SelfUpdater(app: .repoRadar)

    static let panelDefaultSize = NSSize(width: 330, height: 520)
    static let panelMinimumSize = NSSize(width: PanelMetrics.width, height: 360)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        panel = MenuBarPanelController(statusItem: statusItem)
        panel.onOpen = { [weak self] in self?.store.refreshIfStale() }
        panel.setContent(defaultSize: Self.panelDefaultSize, minimumSize: Self.panelMinimumSize) {
            PanelView()
                .environmentObject(store)
                .environmentObject(prefs)
                .environmentObject(selfUpdater)
        }

        // The menu bar count follows the repos, snoozes and ignores
        store.objectWillChange.merge(with: prefs.objectWillChange)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        updateStatusItem()

        // Don't touch git or the folders when launched as a unit-test host
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        #if DEBUG
        // `-demo YES` shows sample repos without git, for checking the UI
        if UserDefaults.standard.bool(forKey: "demo") {
            store.showDemo(Demo.repos, unavailable: Demo.unavailable)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.panel.open() }
            return
        }
        #endif

        UNUserNotificationCenter.current().delegate = self
        store.start()
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReminder() }
        }
        Task { await selfUpdater.checkSilent() }

        // First run: open the panel so the welcome card is seen
        if prefs.folders.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.panel.open() }
        }
    }

    // MARK: - Menu bar

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let count = store.attentionCount
        button.image = MenuBarIcon.image(blip: count > 0)
        button.title = count > 0 ? " \(count)" : ""
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.toolTip = switch count {
        case 0: "Repo Radar: all clear"
        case 1: "Repo Radar: 1 repo needs you"
        default: "Repo Radar: \(count) repos need you"
        }
    }

    // MARK: - Reminder

    private func checkReminder() {
        guard prefs.reminderEnabled,
              Reminder.isDue(now: Date(), minutes: prefs.reminderMinutes, lastDay: prefs.lastReminderDay) else { return }
        prefs.lastReminderDay = Reminder.day(of: Date())
        let repos = store.attention
        if !repos.isEmpty { Reminder.post(repos: repos) }
    }

    // Clicking the notification opens the panel
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.panel.open() }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
