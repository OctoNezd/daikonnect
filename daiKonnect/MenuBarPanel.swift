import AppKit
import SwiftUI

/// The menu bar ("tray") panel: the way in when daiKonnect runs without a Dock
/// icon. Shows the phone's connection and battery, plus media controls for
/// whatever is playing on it.
struct MenuBarPanel: View {
  @EnvironmentObject var service: KDEConnectService
  @EnvironmentObject var settings: AppSettings
  @Environment(\.openWindow) private var openWindow

  @State private var selectedPlayer: String?

  /// The device this panel reports on: the selected one, else the first
  /// connected device, else the first known device.
  private var device: RemoteDevice? {
    if let id = service.selectedDeviceId,
      let match = service.devices.first(where: { $0.deviceId == id })
    {
      return match
    }
    return service.devices.first(where: { $0.connected }) ?? service.devices.first
  }

  private var players: [MediaPlayer] {
    guard let device else { return [] }
    return service.mediaPlayers[device.deviceId] ?? []
  }

  private var player: MediaPlayer? {
    if let selectedPlayer, let match = players.first(where: { $0.name == selectedPlayer }) {
      return match
    }
    return players.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      TrayOption(title: "Open \(AppMeta.AppName)") {
        openApp(tab: nil)
      }

      Divider()

      phoneStatus
        .padding(.horizontal, 7)

      if let player {
        Divider()
        mediaControls(player)
          .padding(.horizontal, 7)
      }

      if service.localNetworkBlocked {
        LocalNetworkNotice(service: service, compact: true)
          .padding(.horizontal, 7)
      }

      Divider()

      notificationsSection
        .padding(.horizontal, 7)

      TrayOption(title: "Open SMS messages") {
        openApp(tab: .sms)
      }

      Divider()

      TrayOption(title: "Quit") {
        NSApp.terminate(nil)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 5)
    .frame(width: 330)
  }

  // MARK: Phone status

  @ViewBuilder
  private var phoneStatus: some View {
    if let device {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(device.name)
            .font(.headline)
            .lineLimit(1)
          Spacer()
          Text(device.connected ? "Connected" : "Offline")
            .font(.callout)
            .foregroundStyle(device.connected ? Color.green : Color.secondary)
        }

        HStack(spacing: 6) {
          Image(systemName: batterySymbol)
            .frame(width: 18)
          Text(batteryText)
          Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    } else {
      Text("No devices yet. Make sure the phone is on the same Wi-Fi.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    if let error = service.setupError {
      Text(error)
        .font(.callout)
        .foregroundStyle(.red)
        .lineLimit(3)
    }
  }

  private var battery: BatteryState? {
    guard let device else { return nil }
    return service.batteries[device.deviceId]
  }

  private var batteryText: String {
    guard let battery, battery.level >= 0 else { return "No battery info" }
    var text = "\(battery.level)%"
    if battery.charging { text += " · charging" }
    if battery.low && !battery.charging { text += " · low" }
    return text
  }

  private var batterySymbol: String {
    guard let battery, battery.level >= 0 else { return "battery.0" }
    if battery.charging { return "battery.100.bolt" }
    switch battery.level {
    case ..<10: return "battery.0"
    case ..<35: return "battery.25"
    case ..<60: return "battery.50"
    case ..<85: return "battery.75"
    default: return "battery.100"
    }
  }

  // MARK: Media

  @ViewBuilder
  private func mediaControls(_ player: MediaPlayer) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        artwork(player)
        VStack(alignment: .leading, spacing: 2) {
          Text(player.title.isEmpty ? "Unknown track" : player.title)
            .font(.callout)
            .bold()
            .lineLimit(1)
          Text(player.artist.isEmpty ? player.name : player.artist)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if players.count > 1 {
          Menu {
            ForEach(players) { candidate in
              Button(candidate.name) { selectedPlayer = candidate.name }
            }
          } label: {
            Image(systemName: "rectangle.stack")
          }
          .menuStyle(.borderlessButton)
          .frame(width: 24)
          .help("Choose player")
        }
      }

      HStack(spacing: 26) {
        Spacer()
        Button {
          service.sendMediaAction(
            deviceId: device?.deviceId ?? "", player: player.name,
            action: "Previous")
        } label: {
          Image(systemName: "backward.fill")
        }
        .buttonStyle(.plain)
        .disabled(!player.canGoPrevious)

        Button {
          service.sendMediaAction(
            deviceId: device?.deviceId ?? "", player: player.name,
            action: "PlayPause")
        } label: {
          Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.system(size: 30))
        }
        .buttonStyle(.plain)
        .disabled(!player.canPlay && !player.canPause)

        Button {
          service.sendMediaAction(
            deviceId: device?.deviceId ?? "", player: player.name,
            action: "Next")
        } label: {
          Image(systemName: "forward.fill")
        }
        .buttonStyle(.plain)
        .disabled(!player.canGoNext)
        Spacer()
      }
    }
  }

  // MARK: Notifications

  /// The five most recent notifications from the phone.
  private var recentNotifications: [PhoneNotification] {
    guard let device else { return [] }
    return Array((service.notifications[device.deviceId] ?? []).prefix(5))
  }

  private var notificationsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text("Notifications").font(.headline)
        Spacer()
        if !recentNotifications.isEmpty {
          Button("See all") { openApp(tab: .notifications) }
            .font(.callout)
          Button("Clear all") { clearAllNotifications() }
            .font(.callout)
            .disabled(!canControlNotifications)
            .help("Dismiss every notification on the phone")
        }
      }

      NotificationPermissionNotice(service: service, compact: true)

      if recentNotifications.isEmpty {
        Text("No notifications yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(recentNotifications) { item in
          HStack(alignment: .top, spacing: 8) {
            // Tapping the text opens the full list in the window.
            Button {
              openApp(tab: .notifications)
            } label: {
              HStack(alignment: .top, spacing: 8) {
                // Through the service, which looks in memory
                // before the model path and the disk. Reading
                // the file directly showed a placeholder for
                // every notification: the on-disk icon cache is
                // emptied at each launch, so the file is
                // normally gone while the bytes are still held.
                if let image = service.iconImage(for: item) {
                  Image(nsImage: image)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .cornerRadius(4)
                } else {
                  // Some apps have no icon to offer; the row
                  // still needs something in that column, in
                  // the same shape as a real icon.
                  RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 18, height: 18)
                    .overlay {
                      Image(systemName: "questionmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                  Text(item.appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Text(item.preview)
                    .font(.callout)
                    .lineLimit(2)
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
              dismiss(item)
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canControlNotifications)
            .help("Dismiss this notification on the phone")
          }
        }
      }
    }
  }

  private var canControlNotifications: Bool {
    guard let device else { return false }
    return device.connected && device.paired
  }

  private func dismiss(_ item: PhoneNotification) {
    service.dismissPhoneNotification(deviceId: item.deviceId, notifId: item.notifId)
  }

  private func clearAllNotifications() {
    guard let device else { return }
    service.clearNotifications(deviceId: device.deviceId)
  }

  /// Close the menu bar panel.
  ///
  /// The panel closes when Escape is pressed, so that is what is sent — a
  /// synthetic key event to our own app, which the panel's responder chain
  /// handles exactly as it would a real keypress.
  ///
  /// Removing and re-inserting the menu bar item instead does not work: it
  /// makes the icon blink, and SwiftUI brings the panel straight back
  /// because it still considers it open.
  private func dismissPanel() {
    guard let window = NSApp.keyWindow else { return }
    let now = ProcessInfo.processInfo.systemUptime
    for isDown in [true, false] {
      guard
        let event = NSEvent.keyEvent(
          with: isDown ? .keyDown : .keyUp,
          location: .zero,
          modifierFlags: [],
          timestamp: now,
          windowNumber: window.windowNumber,
          context: nil,
          characters: "\u{1b}",
          charactersIgnoringModifiers: "\u{1b}",
          isARepeat: false,
          keyCode: 53)
      else { continue }
      NSApp.sendEvent(event)
    }
  }

  /// Bring the window forward, optionally switching to a tab.
  ///
  /// Opening from the menu bar also gives the app a Dock icon, so a window
  /// that has been closed can still be found in the Dock and the app
  /// switcher. The icon goes when the app quits; the menu bar item keeps it
  /// running until then, and is untouched by this because the policy is
  /// changed here and never re-applied.
  private func openApp(tab: DeviceTab?) {
    dismissPanel()
    if let device { service.selectedDeviceId = device.deviceId }
    if let tab { service.requestedDetailTab = tab }
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
    // If the window was closed rather than hidden behind something,
    // openWindow may not bring one back; restoring it directly does.
    DispatchQueue.main.async { AppSettings.shared.showMainWindow() }
  }

  @ViewBuilder
  private func artwork(_ player: MediaPlayer) -> some View {
    if let path = player.albumArtPath, let image = NSImage(contentsOfFile: path) {
      let size = Self.fittedSize(of: image, max: 44)
      Image(nsImage: image)
        .resizable()
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
        Image(systemName: "music.note")
          .foregroundStyle(.secondary)
      }
      .frame(width: 44, height: 44)
    }
  }

  /// Largest size that fits `image` in a `max`×`max` box, keeping its aspect
  /// ratio (album art and video thumbnails are often not square).
  private static func fittedSize(of image: NSImage, max: CGFloat) -> CGSize {
    let rep = image.representations.first
    let width = CGFloat(rep?.pixelsWide ?? Int(image.size.width))
    let height = CGFloat(rep?.pixelsHigh ?? Int(image.size.height))
    guard width > 0, height > 0 else { return CGSize(width: max, height: max) }
    let scale = min(max / width, max / height)
    return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
  }

}

/// A row in the tray panel that reads as a menu option rather than a button.
///
/// SwiftUI draws none of a menu item's chrome — the selection fill, its colour
/// and its metrics all come from AppKit in a real menu — so they are spelled
/// out here to match: the accent colour, the menu's own text colour on top of
/// it, a highlight that reaches the panel edges, and tight vertical padding.
private struct TrayOption: View {
  let title: String
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .contentShape(Rectangle())
      .foregroundStyle(hovering ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(hovering ? Color(nsColor: .controlAccentColor) : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

#Preview {
  let svc = KDEConnectService.shared
  svc.devices = [
    RemoteDevice(
      deviceId: "preview", name: "Sample Phone", deviceType: "phone",
      host: "192.168.1.50", tcpPort: 1716, connected: true, paired: true)
  ]
  svc.selectedDeviceId = "preview"
  svc.batteries["preview"] = BatteryState(level: 54, charging: false, low: false, updated: Date())
  svc.mediaPlayers["preview"] = [
    MediaPlayer(
      name: "Music Player", title: "Song Title", artist: "Artist Name",
      album: "Album Name", isPlaying: true, canPlay: true, canPause: true,
      canGoNext: true, canGoPrevious: true, canSeek: true,
      lengthMs: 228000, positionMs: 113000, volume: 70)
  ]
  svc.notifications["preview"] = [
    PhoneNotification(
      deviceId: "preview", notifId: "1", appName: "Example App",
      title: "Notification title", text: "Notification body text.",
      ticker: "", time: Date(), isClearable: true,
      requestReplyId: nil, actions: []),
    PhoneNotification(
      deviceId: "preview", notifId: "2", appName: "Second App",
      title: "Another title", text: "More body text.",
      ticker: "", time: Date(), isClearable: true,
      requestReplyId: nil, actions: []),
    PhoneNotification(
      deviceId: "preview", notifId: "3", appName: "Third App",
      title: "Third title", text: "Even more body text.",
      ticker: "", time: Date(), isClearable: false,
      requestReplyId: nil, actions: []),
  ]
  return MenuBarPanel()
    .environmentObject(svc)
    .environmentObject(AppSettings.shared)
}
