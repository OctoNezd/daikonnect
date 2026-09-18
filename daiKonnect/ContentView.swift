import AppKit
import SwiftUI

struct ContentView: View {
  @StateObject private var service = KDEConnectService.shared
  @EnvironmentObject var settings: AppSettings

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      if let device = service.selectedDevice {
        DeviceDetailView(device: device)
          .environmentObject(service)
      } else {
        emptyDetail
      }
    }
    .navigationTitle(AppMeta.AppName)
    .background(WindowConfigurator())
    // Remember this window, so the menu bar item can bring it back.
    .background(
      WindowReader { _, window in
        AppSettings.shared.noteMainWindow(window)
      }
    )
    .frame(minWidth: 900, minHeight: 600)
    .onAppear {
      // Previews must not start the service: it binds UDP/TCP 1716 and
      // takes the single-instance lock, which collides with the running
      // app (and leaves a preview process holding the port).
      if !AppEnvironment.isPreview { service.start() }
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Devices")
          .font(.headline)
        Spacer()
        Button {
          service.broadcastIdentity(force: true)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Re-broadcast presence now")
        .disabled(!service.isRunning)
      }

      devicesList

      Spacer(minLength: 12)

      Divider()

      statusCard
    }
    .padding(12)
    .frame(minWidth: 280)
  }

  private var devicesList: some View {
    Group {
      if service.devices.isEmpty {
        Text(
          "No devices found yet.\nMake sure your phone is on the same Wi-Fi with KDE Connect open."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
      } else {
        VStack(spacing: 4) {
          ForEach(service.devices) { device in
            DeviceRow(device: device)
              .padding(.horizontal, 8)
              .padding(.vertical, 6)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                service.selectedDeviceId == device.id
                  ? Color.accentColor.opacity(0.25)
                  : Color.secondary.opacity(0.12)
              )
              .cornerRadius(8)
              .onTapGesture { service.selectedDeviceId = device.id }
          }
        }
      }
    }
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Circle()
          .fill(service.isRunning ? Color.green : Color.gray)
          .frame(width: 10, height: 10)
        Text(service.isRunning ? "Running" : "Stopped")
          .font(.headline)
      }
      // A failure is always shown, even with the terse indicator.
      if let err = service.setupError {
        Text(err)
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(4)
      } else if settings.detailedStatus {
        Text(service.statusMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
    }
    .padding(8)
    .background(.quaternary.opacity(0.5))
    .cornerRadius(8)
  }

  private var emptyDetail: some View {
    VStack(spacing: 12) {
      Image(systemName: "iphone.and.arrow.forward")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      Text("Select a device")
        .font(.title2)
      Text("Pair your Android phone in the KDE Connect app using the same Wi-Fi network.")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(40)
  }

  // MARK: - actions

}

// MARK: - Window configuration

/// Makes the window draggable from any non-interactive background area.
/// With a `NavigationSplitView` the content extends under the title bar, so
/// there is often no title-bar strip left to grab — which reads as "the
/// window can't be moved".
private struct WindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      window.isMovableByWindowBackground = true
      window.titlebarAppearsTransparent = false
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Sidebar row
private struct DeviceRow: View {
  let device: RemoteDevice

  var body: some View {
    HStack {
      Image(systemName: device.deviceType == "tablet" ? "ipad" : "iphone")
        .font(.title2)
        .foregroundStyle(device.connected ? Color.accentColor : Color.secondary)
      VStack(alignment: .leading) {
        Text(device.name).font(.body)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if device.paired {
        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
      }
      if device.pairRequestedByPeer {
        Image(systemName: "exclamationmark.badge.fill").foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 2)
  }

  private var subtitle: String {
    var bits: [String] = []
    bits.append(device.paired ? "paired" : "not paired")
    bits.append(device.connected ? "connected" : "offline")
    return bits.joined(separator: " · ")
  }
}

#Preview {
  // A device is seeded so the window preview shows the whole layout rather
  // than the empty state: layout faults here have hidden in the detail
  // column before, and an empty window hides them.
  let svc = KDEConnectService.shared
  svc.devices = [
    RemoteDevice(
      deviceId: "preview", name: "Sample Phone", deviceType: "phone",
      host: "192.168.1.50", tcpPort: 1716, connected: true, paired: true)
  ]
  svc.selectedDeviceId = "preview"
  return ContentView()
    .environmentObject(AppSettings.shared)
    .frame(width: 900, height: 650)
}
