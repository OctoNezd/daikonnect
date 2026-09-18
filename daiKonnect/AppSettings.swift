import SwiftUI
import AppKit
import Combine
import ServiceManagement

/// UserDefaults keys shared between the settings UI and the service.
enum AppSettingsKeys {
    static let detailedStatus = "daiKonnect.detailedStatus"
    static let allowRemoteMediaControl = "daiKonnect.allowRemoteMediaControl"
    static let clipboardSync = "daiKonnect.clipboardSync"
    static let clipboardExcludedApps = "daiKonnect.clipboardExcludedApps"
    static let notificationExcludedApps = "daiKonnect.notificationExcludedApps"
    static let showMenuBarIcon = "daiKonnect.showMenuBarIcon"
}

/// Clipboard preferences, readable from anywhere.
///
/// `AppSettings` is main-actor isolated, and the service does its work on
/// background queues, so it reads the same defaults directly — the pattern
/// `AppCapabilities` already uses for the media setting.
enum ClipboardSettings {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.clipboardSync) as? Bool ?? true
    }

    static var excludedApps: [String] {
        UserDefaults.standard.stringArray(forKey: AppSettingsKeys.clipboardExcludedApps) ?? []
    }
}

/// Notification preferences, readable from the service's background queues.
enum NotificationSettings {
    /// Phone apps whose notifications stay in the dashboard but are not shown
    /// as macOS notifications. Matched on the app name the phone reports, since
    /// that is all a notification packet carries — there is no bundle id for an
    /// app on the other device.
    static var excludedApps: [String] {
        UserDefaults.standard.stringArray(forKey: AppSettingsKeys.notificationExcludedApps) ?? []
    }
}

/// Environment facts about how this process was launched.
enum AppEnvironment {
    /// True when the code is running inside an Xcode preview. Previews must
    /// not start the service, take a Dock icon, or add a menu bar item.
    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

/// User-facing app preferences that live outside the KDE Connect service:
/// whether daiKonnect launches at login, and whether it keeps a Dock icon or
/// lives only in the menu bar.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published private(set) var startAtLogin: Bool = false
    /// When off (the default) the sidebar indicator only says whether the
    /// service is running; the old verbose status line is opt-in.
    @Published private(set) var detailedStatus: Bool
    /// Set when macOS refuses the login-item change (e.g. an unsigned build),
    /// so the UI can explain why the toggle snapped back.
    @Published var loginItemError: String?

    /// When on, the Mac advertises its media players so the phone can drive
    /// them. Defaults to on.
    @Published private(set) var allowRemoteMediaControl: Bool

    /// When on, clipboard text is exchanged with the phone. Concealed content
    /// is never sent regardless of this.
    @Published private(set) var clipboardSync: Bool
    /// Bundle identifiers whose clipboard the user does not want sent. Applies
    /// to whatever app was frontmost when the copy happened, which is how the
    /// source is inferred — macOS does not record who set the pasteboard.
    @Published private(set) var clipboardExcludedApps: [String]

    /// Phone app names whose notifications should stay in the dashboard without
    /// also being shown as macOS notifications.
    @Published private(set) var notificationExcludedApps: [String]

    /// Whether the app shows its menu bar item.
    @Published private(set) var showMenuBarIcon: Bool

    private init() {
        detailedStatus = UserDefaults.standard.bool(forKey: AppSettingsKeys.detailedStatus)
        allowRemoteMediaControl = UserDefaults.standard
            .object(forKey: AppSettingsKeys.allowRemoteMediaControl) as? Bool ?? true
        clipboardSync = UserDefaults.standard.object(forKey: AppSettingsKeys.clipboardSync) as? Bool ?? true
        clipboardExcludedApps = UserDefaults.standard.stringArray(forKey: AppSettingsKeys.clipboardExcludedApps) ?? []
        notificationExcludedApps = UserDefaults.standard
            .stringArray(forKey: AppSettingsKeys.notificationExcludedApps) ?? []
        showMenuBarIcon = UserDefaults.standard
            .object(forKey: AppSettingsKeys.showMenuBarIcon) as? Bool ?? true
        refreshLoginItemState()

        // Forget a window once it closes, so the menu bar item knows there is
        // nothing to bring back until one is opened again.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window === self?.mainWindow else { return }
            self?.mainWindow = nil
        }
    }

    func setClipboardSync(_ on: Bool) {
        clipboardSync = on
        UserDefaults.standard.set(on, forKey: AppSettingsKeys.clipboardSync)
    }

    func addClipboardExcludedApp(_ bundleIdentifier: String) {
        guard !clipboardExcludedApps.contains(bundleIdentifier) else { return }
        clipboardExcludedApps.append(bundleIdentifier)
        UserDefaults.standard.set(clipboardExcludedApps, forKey: AppSettingsKeys.clipboardExcludedApps)
    }

    func removeClipboardExcludedApp(_ bundleIdentifier: String) {
        clipboardExcludedApps.removeAll { $0 == bundleIdentifier }
        UserDefaults.standard.set(clipboardExcludedApps, forKey: AppSettingsKeys.clipboardExcludedApps)
    }

    func addNotificationExcludedApp(_ appName: String) {
        guard !notificationExcludedApps.contains(appName) else { return }
        notificationExcludedApps.append(appName)
        UserDefaults.standard.set(notificationExcludedApps, forKey: AppSettingsKeys.notificationExcludedApps)
    }

    func removeNotificationExcludedApp(_ appName: String) {
        notificationExcludedApps.removeAll { $0 == appName }
        UserDefaults.standard.set(notificationExcludedApps, forKey: AppSettingsKeys.notificationExcludedApps)
    }

    func setShowMenuBarIcon(_ on: Bool) {
        showMenuBarIcon = on
        UserDefaults.standard.set(on, forKey: AppSettingsKeys.showMenuBarIcon)
    }

    func setAllowRemoteMediaControl(_ on: Bool) {
        allowRemoteMediaControl = on
        UserDefaults.standard.set(on, forKey: AppSettingsKeys.allowRemoteMediaControl)
    }

    func setDetailedStatus(_ on: Bool) {
        detailedStatus = on
        UserDefaults.standard.set(on, forKey: AppSettingsKeys.detailedStatus)
    }

    // MARK: Login item

    func refreshLoginItemState() {
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        // Trust the system's answer rather than the requested value.
        refreshLoginItemState()
    }

    // MARK: Dock / menu-bar-only

    /// The app's main window, kept only so the menu bar item and the Dock icon
    /// can bring it back when it has been closed.
    ///
    /// Deliberately not a published property, and deliberately not used to
    /// decide anything about the Dock icon: the app keeps one for as long as it
    /// runs, so nothing has to be re-applied when windows come and go. Every
    /// attempt to make the icon follow the windows ended in a SwiftUI loop or a
    /// menu bar item that could not be restored.
    weak var mainWindow: NSWindow?

    func noteMainWindow(_ window: NSWindow?) {
        mainWindow = window
    }

    /// Bring the window back, whether it was closed or is merely behind
    /// something. Returns false if there is nothing to show.
    @discardableResult
    func showMainWindow() -> Bool {
        guard let window = mainWindow else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
