import Foundation
import Combine

/// Watches the project's GitHub releases for a newer build.
///
/// The comparison is the build number, not the version string: that number
/// comes from the build itself — the commit count, or the number in the
/// release tag when the release workflow builds it — so it only ever
/// increases, and a plain integer comparison is enough. Release tags are
/// expected to end in that number, e.g. `v1.0.75`.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Where the app looks, and where its About window points.
    static let repositoryURL = URL(string: "https://github.com/octonezd/daikonnect")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/octonezd/daikonnect/releases/latest")!

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, build: Int, page: URL, download: URL?)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// This app's own numbers, as the build stamped them.
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"

    /// The build, as stamped by the "Set build number" phase.
    ///
    /// Read from that phase's own file rather than CFBundleVersion: on an
    /// incremental build Xcode regenerates the Info.plist after the script
    /// runs, putting the project's number back, so the plist can report a build
    /// older than the last release. The file holds what was actually stamped.
    var build: Int {
        if let url = Bundle.main.url(forResource: "BuildNumber", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8),
           let stamped = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return stamped
        }
        return Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    private var started = false

    /// Check once when the app starts, quietly. Failures stay quiet too:
    /// being offline is not worth a message, and the About window has a
    /// button that will say so when asked.
    func checkQuietlyOnLaunch() {
        guard !started, !AppEnvironment.isPreview else { return }
        started = true
        Task { await check(surfacingFailures: false) }
    }

    func check() {
        Task { await check(surfacingFailures: true) }
    }

    private func check(surfacingFailures: Bool) async {
        if surfacingFailures { state = .checking }

        var request = URLRequest(url: Self.latestReleaseAPI)
        // GitHub rejects requests that do not identify themselves.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("daiKonnect/\(version) (\(build))", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed("No answer from GitHub")
                return
            }
            switch http.statusCode {
            case 200:
                break
            case 404:
                // No releases published yet, or the repository is not there.
                state = surfacingFailures ? .failed("No releases published yet") : .idle
                return
            default:
                // Not worth a message on a quiet check, same as being offline:
                // a proxy or a rate limit should not greet someone in About.
                state = surfacingFailures ? .failed("GitHub replied \(http.statusCode)") : .idle
                return
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let latest = Self.buildNumber(fromTag: release.tagName), latest > build else {
                state = .upToDate
                return
            }
            state = .updateAvailable(version: release.tagName,
                                     build: latest,
                                     page: release.htmlURL,
                                     download: release.dmgURL)
        } catch {
            state = surfacingFailures ? .failed(error.localizedDescription) : .idle
        }
    }

    /// The trailing number of a tag like `v1.0.75`, which is the build it was
    /// made from.
    ///
    /// Anything not shaped like that is ignored rather than guessed at: a tag
    /// such as `release-2024-12-31` would otherwise read as build 31, which is
    /// lower than any real build and would look up to date.
    static func buildNumber(fromTag tag: String) -> Int? {
        guard tag.hasPrefix("v") else { return nil }
        let digits = tag.reversed().prefix { $0.isNumber }.reversed()
        return digits.isEmpty ? nil : Int(String(digits))
    }

    /// Show a result without touching the network — for previews.
    func setStateForPreview(_ new: State) {
        state = new
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        var dmgURL: URL? { assets.first { $0.name.hasSuffix(".dmg") }?.downloadURL }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let downloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
    }
}
