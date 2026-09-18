import SwiftUI

@main struct MyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject private var service = KDEConnectService.shared
  @StateObject private var settings = AppSettings.shared

  var body: some Scene {
    // A single window, not a group: asking for it again brings the same
    // one forward instead of opening another.

    Window(AppMeta.AppName, id: "main") {
      ContentView()
        .environmentObject(service)
        .environmentObject(settings)
    }

    MenuBarExtra(isInserted: trayInserted) {
      MenuBarPanel()
        .environmentObject(service)
        .environmentObject(settings)
    } label: {
      Image(systemName: service.isRunning ? "iphone" : "iphone.slash")
    }
    .menuBarExtraStyle(.window)

    Window("About \(AppMeta.AppName)", id: "about") {
      AboutView()
    }
    .windowResizability(.contentSize)

    Settings {
      SettingsView()
        .environmentObject(service)
        .environmentObject(settings)
    }
    .commands {
      // Put our own About window on the App menu's About item, which
      // otherwise opens the system panel with nothing in it.
      CommandGroup(replacing: .appInfo) {
        AboutCommand()
      }
    }
  }

  /// Whether the menu bar item is inserted, from the preference.
  ///
  /// Derived rather than bound to the preference directly: SwiftUI writes the
  /// `isInserted` binding back as the item comes and goes, and sending those
  /// writes through a published property invalidates the scene, which writes
  /// again — the loop that pegs a core and logs "Publishing changes from
  /// within view updates is not allowed". Ignoring the setter leaves the
  /// preference as the only thing that changes it, while the getter re-reads
  /// it whenever `settings` publishes and this body re-evaluates. Never
  /// inserted in previews, where it would put a stray item in the menu bar.
  private var trayInserted: Binding<Bool> {
    Binding(
      get: { !AppEnvironment.isPreview && settings.showMenuBarIcon },
      set: { _ in }
    )
  }
}

/// The App menu's "About daiKonnect", opening the window above.
private struct AboutCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("About \(AppMeta.AppName)") { openWindow(id: "about") }
  }
}
