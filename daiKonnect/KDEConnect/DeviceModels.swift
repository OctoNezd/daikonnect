import Foundation

// MARK: - Remote device

struct RemoteDevice: Identifiable, Equatable {
    var id: String { deviceId }
    var deviceId: String
    var name: String
    var deviceType: String
    var host: String
    var tcpPort: UInt16
    var connected: Bool = false
    var paired: Bool = false
    var pairRequestedByPeer: Bool = false
    var pairRequestedByUs: Bool = false
    var lastSeen: Date = Date()
    var protocolVersion: Int = 7
}

// MARK: - Navigation

/// Tabs in the device detail view. The menu bar panel can ask the main window
/// to switch to one of these.
enum DeviceTab: Hashable {
    case overview
    case notifications
    case sms
}

// MARK: - Battery

struct BatteryState: Equatable {
    var level: Int = -1          // -1 = unknown / no battery
    var charging: Bool = false
    var low: Bool = false
    var updated: Date?

    var displayText: String {
        guard level >= 0 else { return "No battery info" }
        return "\(level)%"
    }

    /// Symbol for the charge actually reported, nearest quarter, rather than
    /// one always-full battery. SF Symbols only ships a charging bolt at 100%,
    /// which is why charging is left to the label beside it.
    var symbolName: String {
        guard level >= 0 else { return "battery.0" }
        let symbols = ["battery.0", "battery.25", "battery.50", "battery.75", "battery.100"]
        return symbols[min(symbols.count - 1, max(0, (level + 12) / 25))]
    }
}

// MARK: - Notifications

struct PhoneNotification: Identifiable, Equatable {
    var id: String { "\(deviceId):\(notifId)" }
    let deviceId: String
    let notifId: String
    var appName: String
    var title: String
    var text: String
    var ticker: String
    var time: Date
    var isClearable: Bool
    var requestReplyId: String?
    var actions: [String]
    /// Payload hash from the phone — used to look up the cached icon at display time.
    var iconHash: String?
    /// Local cache path of the phone app's icon (payload transfer), if fetched.
    var iconFilePath: String? = nil

    var preview: String {
        if !title.isEmpty && !text.isEmpty { return "\(title) — \(text)" }
        if !ticker.isEmpty { return ticker }
        if !title.isEmpty { return title }
        return text
    }
}

// MARK: - SMS

struct SmsMessageItem: Identifiable, Equatable {
    let id: UInt64
    let threadId: UInt64
    var addresses: [String]
    var body: String
    var date: Date
    /// Android type: 1 = inbox (incoming), 2 = sent (outgoing)
    var incoming: Bool
    var read: Bool
}

struct SmsConversation: Identifiable, Equatable {
    var id: UInt64 { threadId }
    let threadId: UInt64
    var participants: [String]
    var messages: [SmsMessageItem]

    var lastDate: Date { messages.map(\.date).max() ?? .distantPast }
    var title: String { participants.joined(separator: ", ") }
    var snippet: String { messages.sorted { $0.date < $1.date }.last?.body ?? "" }

    mutating func merge(_ newMessages: [SmsMessageItem]) {
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for m in newMessages { byId[m.id] = m }
        messages = byId.values.sorted { $0.date < $1.date }
        let addrs = messages.flatMap(\.addresses)
        if !addrs.isEmpty {
            // Keep a stable participant list from the latest message set.
            var seen: [String] = []
            for a in addrs where !seen.contains(a) { seen.append(a) }
            participants = seen
        }
    }
}

// MARK: - Media (MPRIS)

/// A media player the phone is running, as reported by the MPRIS plugin.
struct MediaPlayer: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    var canPlay: Bool = false
    var canPause: Bool = false
    var canGoNext: Bool = false
    var canGoPrevious: Bool = false
    var canSeek: Bool = false
    /// Track length and position, in milliseconds.
    var lengthMs: Int = 0
    var positionMs: Int = 0
    /// 0–100.
    var volume: Int = 0
    /// Art URL as reported by the phone (used to request the payload).
    var albumArtUrl: String?
    /// Locally cached album art, once downloaded.
    var albumArtPath: String?
    var updated: Date?

    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }
}

// MARK: - Persisted pairing info

struct PairedInfo: Codable {
    var name: String
    var fingerprint: String
}
