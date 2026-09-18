import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Shows notification banners even while daiKonnect is the frontmost app.
/// (Without this delegate, macOS delivers notifications silently to
/// Notification Center whenever the app is active, so it looks like
/// nothing arrived.)
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationDelegate()

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .badge])
  }

  /// Handles the buttons: "Copy <code>" and "Dismiss on phone".
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let content = response.notification.request.content
    let action = response.actionIdentifier

    // Copying on a plain click as well as on the button, which is how this
    // behaved before the button existed.
    if action == NotificationCategory.copyCodeAction
      || action == UNNotificationDefaultActionIdentifier
    {
      if let code = NotificationCategory.code(fromCategory: content.categoryIdentifier) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        KDEConnectService.shared.logNotificationAction("Notification clicked: copied code \(code)")
      } else {
        // A body click carries no code and does nothing, so say so —
        // otherwise a click looks identical to a click that never
        // arrived, which is exactly what I could not tell apart.
        KDEConnectService.shared.logNotificationAction(
          "Notification clicked (body, not a button) — nothing to do")
      }
    } else if action == NotificationCategory.dismissAction {
      // Logged at each step: without it there is no way to tell a button
      // that never reached us from a cancel the phone ignored.
      guard let deviceId = content.userInfo[NotificationCategory.deviceKey] as? String,
        let notifId = content.userInfo[NotificationCategory.notifIdKey] as? String
      else {
        KDEConnectService.shared.logNotificationAction(
          "Dismiss on phone pressed, but the notification carried no device/notification id — nothing to cancel"
        )
        completionHandler()
        return
      }
      KDEConnectService.shared.logNotificationAction("Dismiss on phone pressed for \(notifId)")
      // Asked for by the user, so it also goes away here.
      DispatchQueue.main.async {
        KDEConnectService.shared.dismissPhoneNotification(deviceId: deviceId, notifId: notifId)
      }
    } else {
      KDEConnectService.shared.logNotificationAction(
        "Notification action \(action) — nothing to do")
    }
    completionHandler()
  }
}

/// Warns that macOS is dropping the notifications we post, and offers the only
/// route to fixing it (the system will not ask twice). Without it the app just
/// looks like the phone has nothing to show.
struct NotificationPermissionNotice: View {
  @ObservedObject var service: KDEConnectService
  /// Narrower arrangement for the menu bar panel, where a row shared with
  /// the button truncates the text.
  var compact = false

  var body: some View {
    if service.notificationPermission == .denied {
      if compact {
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text("macOS notifications are turned off.")
              .font(.callout)
          }
          Text("Phone notifications won't appear until they are allowed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Notification Settings…") { service.openNotificationSettings() }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 6))
      } else {
        // No fixedSize on this text. It sits in the detail column's
        // TabView, and asking for the ideal height makes the row
        // report the un-wrapped, single-line width as its ideal width.
        // That demand travels up through the split view and leaves the
        // whole window laid out past its bounds — blank sidebar, no tab
        // picker, content off the edge. Given the flexible width, the
        // text wraps by itself.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("macOS notifications are turned off, so phone notifications won't be shown.")
          Spacer(minLength: 8)
          Button("Notification Settings…") { service.openNotificationSettings() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 6))
      }
    }
  }
}

/// Warns that macOS is refusing this app's connections to the local network.
///
/// The permission is granted silently or not at all: an app that never asked
/// gets no prompt, and the symptom is misleading — the phone is connected and
/// sending, yet every connection the app opens is refused, which reads as a
/// broken network rather than a permission.
struct LocalNetworkNotice: View {
  @ObservedObject var service: KDEConnectService
  /// Narrower arrangement for the menu bar panel.
  var compact = false

  var body: some View {
    if service.localNetworkBlocked {
      if compact {
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "network.slash")
              .foregroundStyle(.orange)
            Text("macOS is blocking local network access.")
              .font(.callout)
          }
          Text(
            "Your phone is connected, but \(AppMeta.AppName) can't open connections to it. Allow \(AppMeta.AppName) under Privacy & Security → Local Network."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Button("Local Network Settings…") { service.openLocalNetworkSettings() }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 6))
      } else {
        // No Spacer and no fixedSize: inside the detail column those
        // ask for unbounded width and take the window with them.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Image(systemName: "network.slash")
            .foregroundStyle(.orange)
          Text(
            "macOS is blocking local network access, so daiKonnect can't reach your phone. Allow daiKonnect under Privacy & Security → Local Network."
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          Button("Local Network Settings…") { service.openLocalNetworkSettings() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 6))
      }
    }
  }
}

/// Registers the notification categories daiKonnect posts under.
///
/// A category's buttons are fixed when it is registered, so anything that
/// varies per notification has to be part of the category identifier: whether
/// the notification carries a one-time code, and whether it can be dismissed
/// on the phone. Repeat cases reuse their category.
enum NotificationCategory {
  static let copyCodeAction = "daiKonnect.copyCode"
  static let dismissAction = "daiKonnect.dismissOnPhone"
  /// Where the phone notification's identifiers travel, so the buttons know
  /// what to act on. They cannot be part of the action itself.
  static let deviceKey = "daiKonnect.deviceId"
  static let notifIdKey = "daiKonnect.notifId"

  private static let prefix = "daiKonnect.notify"
  private static let codeMarker = ".code-"

  private static var categories: [String: UNNotificationCategory] = [:]
  private static var order: [String] = []

  /// Category identifier for a notification, registering it the first time.
  static func register(code: String?, dismissible: Bool) -> String {
    // A code gets the copy button and nothing else. macOS moves the extra
    // buttons of a notification into its options menu, so offering a
    // second action hides the one that matters behind a click — which is
    // the whole reason the button exists.
    let offerDismiss = dismissible && code == nil

    var identifier = prefix
    if offerDismiss { identifier += ".dismiss" }
    if let code { identifier += codeMarker + code }
    guard categories[identifier] == nil else { return identifier }

    var actions: [UNNotificationAction] = []
    if let code {
      actions.append(
        UNNotificationAction(
          identifier: copyCodeAction,
          title: "Copy \(code)",
          options: []))
    }
    if offerDismiss {
      actions.append(
        UNNotificationAction(
          identifier: dismissAction,
          title: "Dismiss on phone",
          options: []))
    }
    categories[identifier] = UNNotificationCategory(
      identifier: identifier,
      actions: actions,
      intentIdentifiers: [],
      options: [])
    order.append(identifier)
    // setNotificationCategories replaces the whole set, so drop the oldest
    // rather than growing it without bound.
    while order.count > 50 {
      categories.removeValue(forKey: order.removeFirst())
    }
    UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
    return identifier
  }

  /// How many buttons the category actually carries, for the log: a
  /// notification with none has nothing to click.
  static func actionCount(for identifier: String) -> Int {
    categories[identifier]?.actions.count ?? 0
  }

  /// The code a category was registered for, if it has one.
  static func code(fromCategory identifier: String) -> String? {
    guard identifier.hasPrefix(prefix),
      let marker = identifier.range(of: codeMarker)
    else { return nil }
    return String(identifier[marker.upperBound...])
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    // Ask about notifications at launch rather than waiting for the first
    // phone event: macOS only ever shows the prompt once, and it is easy to
    // miss in an app that lives in the menu bar and may never be frontmost.
    if !AppEnvironment.isPreview {
      KDEConnectService.shared.ensureNotificationPermission()
    }

    // Coming back from System Settings is the moment the permission may
    // have changed under us, and the moment someone checks the notice.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil, queue: .main
    ) { _ in
      KDEConnectService.shared.refreshNotificationAuth()
    }
  }

  /// Clicking the Dock icon with no window open brings one back, rather than
  /// doing nothing.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { AppSettings.shared.showMainWindow() }
    return true
  }

  /// Not quitting when the last window closes is the whole point: the menu
  /// bar item stays.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
