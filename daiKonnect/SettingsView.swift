import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (also reachable with ⌘,). Diagnostics moved here from
/// the sidebar so the main window is just about devices.
struct SettingsView: View {
  @EnvironmentObject var service: KDEConnectService
  @EnvironmentObject var settings: AppSettings

  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gearshape") }
      MacControlSettingsView()
        .tabItem { Label("Mac Control", systemImage: "laptopcomputer") }
      PhoneControlSettingsView()
        .tabItem { Label("Phone Control", systemImage: "iphone") }
      DiagnosticsView()
        .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
    }
    .frame(width: 540, height: 480)
  }
}

// MARK: - General

/// This Mac and the app itself: its name, how it starts, and how it presents
/// itself.
private struct GeneralSettingsView: View {
  @EnvironmentObject var settings: AppSettings
  @EnvironmentObject var service: KDEConnectService
  /// Previews shouldn't display the real configured name.
  @State private var deviceNameDraft =
    AppEnvironment.isPreview ? "Sample Mac" : IdentityStore.shared.deviceName
  private enum NameField: Hashable { case name }
  @FocusState private var nameField: NameField?
  var body: some View {
    Form {
      Section("This Device") {
        HStack {
          TextField("Device name", text: $deviceNameDraft)
            .focused($nameField, equals: .name)
            .onSubmit(saveDeviceName)
          Button("Save", action: saveDeviceName)
            .disabled(deviceNameDraft == IdentityStore.shared.deviceName)
        }
        Text("The name other devices see for this Mac.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("Startup") {
        Toggle(
          "Start \(AppMeta.AppName) at login",
          isOn: Binding(
            get: { settings.startAtLogin },
            set: { settings.setStartAtLogin($0) }
          ))
        if let error = settings.loginItemError {
          Text(error)
            .font(.callout)
            .foregroundStyle(.red)
        }
      }

      Section("Menu Bar") {
        Toggle(
          "Show the menu bar icon",
          isOn: Binding(
            get: { settings.showMenuBarIcon },
            set: { settings.setShowMenuBarIcon($0) }
          ))
        Text(
          settings.showMenuBarIcon
            ? "The phone's status and controls are a click away in the menu bar."
            : "The menu bar icon is hidden. daiKonnect keeps its Dock icon, so the window can still be opened from there."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      Section("Status Indicator") {
        Toggle(
          "Show detailed status messages",
          isOn: Binding(
            get: { settings.detailedStatus },
            set: { settings.setDetailedStatus($0) }
          ))
        Text(
          settings.detailedStatus
            ? "The sidebar shows what daiKonnect is doing (connecting, syncing, and so on)."
            : "The sidebar only shows whether daiKonnect is running. Errors are still shown."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    // Don't focus anything when the tab opens. The Settings window puts the
    // caret in the first text field by itself otherwise, which also brings
    // up whatever autofill the system or a password manager offers for a
    // focused field. `defaultFocus` says no field is the default, and the
    // reader clears the first responder in case the window focused one
    // before this appeared.
    .defaultFocus($nameField, nil)
    .background(
      WindowReader { _, window in
        guard let window else { return }
        window.initialFirstResponder = nil
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
      }
    )
    .onAppear {
      settings.refreshLoginItemState()
      if !AppEnvironment.isPreview {
        deviceNameDraft = IdentityStore.shared.deviceName
      }
    }
  }

  private func saveDeviceName() {
    let clean = IdentityStore.sanitizeDeviceName(deviceNameDraft)
    deviceNameDraft = clean
    IdentityStore.shared.deviceName = clean
    service.broadcastIdentity(force: true)
  }
}

// MARK: - Mac control

/// What the phone may do with this Mac, and what this Mac offers it.
private struct MacControlSettingsView: View {
  @EnvironmentObject var settings: AppSettings
  @EnvironmentObject var service: KDEConnectService

  var body: some View {
    Form {
      Section("Media") {
        Toggle(
          "Let the phone control this Mac's media",
          isOn: Binding(
            get: { settings.allowRemoteMediaControl },
            set: { on in
              settings.setAllowRemoteMediaControl(on)
              // Capabilities live in the identity packet, so the
              // phone needs to hear the new set.
              service.broadcastIdentity(force: true)
            }
          ))
        Text(
          settings.allowRemoteMediaControl
            ? "The phone can see and control whatever is playing on this Mac."
            : "This Mac's media players are hidden from the phone."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      Section("Clipboard") {
        Toggle(
          "Share the clipboard with the phone",
          isOn: Binding(
            get: { settings.clipboardSync },
            set: { on in
              settings.setClipboardSync(on)
              // Capabilities travel in the identity packet.
              service.broadcastIdentity(force: true)
            }
          ))
        Text(
          settings.clipboardSync
            ? "Copying text on either device puts it on the other's clipboard."
            : "The clipboard stays on each device."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      if settings.clipboardSync {
        Section("Excluded from Clipboard") {
          ForEach(settings.clipboardExcludedApps, id: \.self) { bundleID in
            HStack {
              Text(Self.appName(for: bundleID))
              Spacer()
              Button {
                settings.removeClipboardExcludedApp(bundleID)
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .help("Send this app's clipboard again")
            }
          }
          Button("Add App…", action: addExcludedApp)
          Text(
            "Copies made while one of these apps is in front are not sent. Concealed content — what password managers and password fields mark — is never sent, whatever is listed here."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  /// The excluded apps are stored as bundle identifiers because those are
  /// stable; the name is looked up for display.
  private static func appName(for bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return bundleID
    }
    return FileManager.default.displayName(atPath: url.path)
  }

  /// Pick an application to exclude. There is no API for "which app is
  /// copying", so the choice is made by picking the app itself.
  private func addExcludedApp() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Exclude"
    panel.message = "Choose an app whose clipboard should not be sent to the phone."
    guard panel.runModal() == .OK, let url = panel.url,
      let bundle = Bundle(url: url),
      let bundleID = bundle.bundleIdentifier
    else { return }
    settings.addClipboardExcludedApp(bundleID)
  }
}

// MARK: - Phone control

/// What this Mac does with what the phone sends. Notifications are the only
/// thing so far: which phone apps may also raise a macOS notification.
private struct PhoneControlSettingsView: View {
  @EnvironmentObject var settings: AppSettings
  @EnvironmentObject var service: KDEConnectService

  var body: some View {
    Form {
      Section("Notifications") {
        Text(
          "Phone notifications always appear in the Notifications tab and the menu bar panel. Apps listed here are left out of macOS notifications only."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        ForEach(settings.notificationExcludedApps, id: \.self) { app in
          HStack {
            Text(app)
            Spacer()
            Button {
              settings.removeNotificationExcludedApp(app)
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show macOS notifications for this app again")
          }
        }

        Menu("Add App…") {
          ForEach(knownNotificationApps, id: \.self) { app in
            Button(app) { settings.addNotificationExcludedApp(app) }
          }
        }
        .disabled(knownNotificationApps.isEmpty)

        if knownNotificationApps.isEmpty && settings.notificationExcludedApps.isEmpty {
          Text("Apps show up here once the phone has sent a notification from them.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      // Opening this tab is how someone checks the permission, so read it
      // rather than showing what it was at launch.
      if !AppEnvironment.isPreview { service.refreshNotificationAuth() }
    }
  }

  /// Phone app names currently seen in notifications, minus the ones already
  /// excluded — the choices offered when adding one.
  private var knownNotificationApps: [String] {
    let names = service.notifications.values.flatMap { $0.map(\.appName) }
    return Set(names).subtracting(settings.notificationExcludedApps).sorted()
  }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
  @EnvironmentObject var service: KDEConnectService

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Grid(alignment: .leading, verticalSpacing: 2) {
          GridRow {
            Text("UDP sent:").foregroundStyle(.secondary)
            Text("\(service.udpSentCount)").monospacedDigit()
          }
          GridRow {
            Text("UDP received:").foregroundStyle(.secondary)
            Text("\(service.udpReceivedCount)").monospacedDigit()
          }
          GridRow {
            Text("TCP accepted:").foregroundStyle(.secondary)
            Text("\(service.tcpAcceptCount)").monospacedDigit()
          }
          GridRow {
            Text("TCP dialed:").foregroundStyle(.secondary)
            Text("\(service.outboundCount)").monospacedDigit()
          }
          GridRow {
            Text("TLS ok / failed:").foregroundStyle(.secondary)
            Text("\(service.tlsOkCount) / \(service.tlsFailCount)").monospacedDigit()
          }
          GridRow {
            Text("Icons got / failed / none:").foregroundStyle(.secondary)
            Text(
              "\(service.iconsFetched) / \(service.iconFetchFailed) / \(service.iconPayloadMissing)"
            ).monospacedDigit()
          }
          GridRow {
            Text("Notifications:").foregroundStyle(.secondary)
            Text(service.notificationAuthStatus)
          }
        }
        .font(.callout)

        HStack {
          if service.notificationPermission == .denied {
            Button("Open Notification Settings") { service.openNotificationSettings() }
          } else {
            Button("Enable notifications") { service.requestNotificationPermission() }
          }
          Spacer()
          Button("Test notification") { service.sendTestNotification() }
        }
        .font(.callout)

        HStack {
          Button(service.isRunning ? "Stop" : "Start") {
            service.isRunning ? service.stop() : service.start()
          }
          Button("Broadcast") { service.broadcastIdentity(force: true) }
            .disabled(!service.isRunning)
          Button("Re-fetch notification icons") { service.reFetchNotificationIcons() }
          Spacer()
        }
        .font(.callout)

        HStack {
          Button("Show log file in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([KDEConnectService.logFileURL])
          }
          Spacer()
          Button("Copy log") {
            let text = service.eventLog.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
          }
        }
        .font(.callout)

        Text("Log")
          .font(.headline)
        TextEditor(text: .constant(service.eventLog.reversed().joined(separator: "\n")))
          .font(.system(.caption, design: .monospaced))
          .frame(minHeight: 160)
          .border(Color.secondary.opacity(0.3))
      }
      .padding(16)
    }
  }
}

#Preview {
  SettingsView()
    .environmentObject(KDEConnectService.shared)
    .environmentObject(AppSettings.shared)
}
