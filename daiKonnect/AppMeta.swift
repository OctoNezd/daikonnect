import Foundation

/// The app's name, as shown in the interface. Debug builds carry a suffix so
/// they are distinguishable from a release install beside them.
struct AppMeta {
    #if DEBUG
    static let AppName = "daiKonnect Dev"
    #else
    static let AppName = "daiKonnect"
    #endif

    /// The project's home on GitHub.
    static let repositoryURL = URL(string: "https://github.com/octonezd/daikonnect")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// The build, as stamped by the "Set build number" build phase.
    ///
    /// Read from that phase's own file rather than CFBundleVersion: on an
    /// incremental build Xcode regenerates the Info.plist after the script
    /// runs, putting the project's number back, so the plist can report a
    /// build older than the last release.
    static var build: Int {
        if let url = Bundle.main.url(forResource: "BuildNumber", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8),
           let stamped = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return stamped
        }
        return Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }
}
