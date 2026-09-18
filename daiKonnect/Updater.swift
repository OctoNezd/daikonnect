import SwiftUI
import Combine
import Sparkle

/// The app's Sparkle updater, and the "Check for Updates…" control shared by
/// the App menu and the About window.
///
/// Sparkle runs its own scheduled background checks and presents its own UI,
/// so nothing here polls on launch or announces updates by hand.
final class Updater: ObservableObject {
    static let shared = Updater()

    let controller: SPUStandardUpdaterController

    /// Mirrors the updater's own flag so the menu item can disable itself
    /// while a check is already running.
    @Published private(set) var canCheckForUpdates = false

    private var cancellable: AnyCancellable?

    private init() {
        // Previews must not start the updater: it would schedule network
        // checks from the preview process.
        controller = SPUStandardUpdaterController(startingUpdater: !AppEnvironment.isPreview,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// The "Check for Updates…" item, disabled while a check cannot start.
struct CheckForUpdatesView: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
