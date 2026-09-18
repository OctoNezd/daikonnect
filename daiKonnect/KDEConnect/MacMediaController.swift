import Foundation
import AppKit
import CryptoKit
import MediaRemoteAdapter

/// The Mac's system-wide "now playing" state.
struct MacNowPlaying: Equatable {
    var appName: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    /// Milliseconds.
    var durationMs: Int = 0
    var positionMs: Int = 0
    /// `file://` URL of the cached cover art, when the track has any. The
    /// phone uses it as the key when asking us for the bytes.
    var albumArtFileURL: String?

    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }
}

/// Reads and controls whatever macOS currently treats as the "now playing" app.
///
/// Reading goes through the MediaRemoteAdapter package, which talks to the
/// private MediaRemote framework from within Apple's own entitled `perl` — the
/// only way to reach it since macOS 15.4, which refuses MediaRemote access to
/// processes that aren't Apple's.
///
/// The route matters for cover art specifically: MediaRemote's newer
/// `MRNowPlayingRequest` API (reachable directly from osascript) returns the
/// artwork's mime type, identifier and dimensions but **not** the image, while
/// the classic call the adapter uses does include it.
final class MacMediaController {
    static let shared = MacMediaController()

    /// MediaRemote command numbers, kept for the caller's sake.
    enum Command {
        case play, pause, togglePlayPause, stop, nextTrack, previousTrack
    }

    /// Called on the main thread whenever the player state changes.
    var onChange: (() -> Void)?

    /// The framework is bundled with the app, so the route is always present.
    let isAvailable = true

    private let controller = MediaController()
    /// Latest state, updated by the listener.
    private var latest: MacNowPlaying?
    private var isListening = false

    /// Last non-empty player name. The phone keys its players by name and
    /// ignores state for a name it doesn't know, so this must not flap.
    private var currentName = "Mac"
    /// Track the cached cover art belongs to, and where it was written.
    private var artworkKey = ""
    private var artworkPath: String?
    /// When the current track's art first went missing, if it has.
    private var artworkMissingSince: Date?

    private init() {
        controller.onTrackInfoReceived = { [weak self] info in
            DispatchQueue.main.async { self?.handle(info) }
        }
    }

    // MARK: Lifecycle

    func startMonitoring() {
        guard !isListening else { return }
        isListening = true
        controller.startListening()
    }

    func stopMonitoring() {
        guard isListening else { return }
        isListening = false
        controller.stopListening()
    }

    // MARK: Queries

    /// Reports the current player. `completion` runs on the main thread; the
    /// state is nil when nothing is playing.
    ///
    /// `nameChanged` tells the caller the player was replaced, so it can
    /// introduce the new name to the phone before sending state it would
    /// otherwise ignore.
    func playerSnapshot(completion: @escaping (_ name: String, _ nameChanged: Bool,
                                               _ state: MacNowPlaying?) -> Void) {
        var nameChanged = false
        if let latest, !latest.appName.isEmpty, latest.appName != currentName {
            currentName = latest.appName
            nameChanged = true
        }
        completion(currentName, nameChanged, latest)
    }

    /// Bytes for an `file://` URL previously handed out as cover art.
    static func artworkData(forFileURL url: String) -> Data? {
        guard url.hasPrefix("file://") else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: String(url.dropFirst("file://".count))))
    }

    // MARK: Control

    @discardableResult
    func send(_ command: Command) -> Bool {
        switch command {
        case .play: controller.play()
        case .pause: controller.pause()
        case .togglePlayPause: controller.togglePlayPause()
        case .stop: controller.stop()
        case .nextTrack: controller.nextTrack()
        case .previousTrack: controller.previousTrack()
        }
        return true
    }

    /// Seek the Mac's player to an absolute position.
    func seek(toMilliseconds ms: Int) {
        controller.setTime(seconds: Double(max(0, ms)) / 1000.0)
    }

    // MARK: Listener

    private func handle(_ info: TrackInfo?) {
        guard let payload = info?.payload else {
            latest = nil
            onChange?()
            return
        }

        var state = MacNowPlaying()
        state.appName = payload.applicationName ?? ""
        state.title = payload.title ?? ""
        state.artist = payload.artist ?? ""
        state.album = payload.album ?? ""
        state.isPlaying = payload.isPlaying ?? ((payload.playbackRate ?? 0) > 0)
        if let micros = payload.durationMicros, micros > 0 {
            state.durationMs = Int(micros / 1000)
        }
        // The adapter interpolates the position from its snapshot + timestamp.
        if let seconds = payload.currentElapsedTime, seconds > 0 {
            state.positionMs = Int(seconds * 1000)
        }
        state.albumArtFileURL = settleArtwork(payload)
        latest = state
        onChange?()
    }

    // MARK: Cover art

    private static var artworkDirectory: URL {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("daiKonnect/albumart", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Caches the track's art and returns its `file://` URL.
    ///
    /// `artworkKey` only advances once art has actually been stored: the system
    /// publishes the image a moment *after* a track starts, so keying off the
    /// track alone would latch onto an art-less first update and never pick it
    /// up.
    private func settleArtwork(_ payload: TrackInfo.Payload) -> String? {
        let key = payload.uniqueIdentifier
        let data = payload.artworkDataBase64
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        if let data {
            artworkMissingSince = nil
            if key != artworkKey || artworkPath == nil {
                artworkKey = key
                artworkPath = Self.storeArtwork(data, mime: payload.artworkMimeType)
            }
        } else if key != artworkKey {
            // New track with no art (yet): drop the previous cover rather than
            // showing the wrong one while we wait for it.
            artworkPath = nil
            artworkMissingSince = Date()
        } else if artworkPath != nil {
            // Same track whose art has gone away. Players unload artwork
            // briefly (seeking, for instance), so wait before concluding it is
            // really gone — otherwise the cover would flicker.
            if let since = artworkMissingSince {
                if Date().timeIntervalSince(since) > Self.artworkMissingGrace {
                    artworkPath = nil
                }
            } else {
                artworkMissingSince = Date()
            }
        }

        guard let artworkPath else { return nil }
        return "file://" + artworkPath
    }

    /// How long a track may report no artwork before the cover is dropped.
    private static let artworkMissingGrace: TimeInterval = 8

    /// Names the art by a hash of its bytes, so the URL is stable for a given
    /// image and the phone's cache keys line up.
    private static func storeArtwork(_ data: Data, mime: String?) -> String? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext: String
        if let mime, mime.contains("jpeg") || mime.contains("jpg") {
            ext = "jpg"
        } else {
            ext = "png"
        }
        let file = artworkDirectory.appendingPathComponent("\(digest).\(ext)")
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try data.write(to: file, options: .atomic)
            } catch {
                return nil
            }
        }
        return file.path
    }
}
