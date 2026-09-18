import Foundation

/// KDE Connect packet types used by daiKonnect.
/// Full reference: https://valent.andyholmes.ca/documentation/protocol.html
enum KDEPacketType {
    static let identity = "kdeconnect.identity"
    static let pair = "kdeconnect.pair"
    static let battery = "kdeconnect.battery"
    static let batteryRequest = "kdeconnect.battery.request"
    static let notification = "kdeconnect.notification"
    static let notificationRequest = "kdeconnect.notification.request"
    static let notificationReply = "kdeconnect.notification.reply"
    static let notificationAction = "kdeconnect.notification.action"
    static let smsMessages = "kdeconnect.sms.messages"
    static let smsRequest = "kdeconnect.sms.request"
    static let smsRequestConversation = "kdeconnect.sms.request_conversation"
    static let smsRequestConversations = "kdeconnect.sms.request_conversations"
    static let mpris = "kdeconnect.mpris"
    static let mprisRequest = "kdeconnect.mpris.request"
    static let clipboard = "kdeconnect.clipboard"
    static let clipboardConnect = "kdeconnect.clipboard.connect"
    static let findMyPhoneRequest = "kdeconnect.findmyphone.request"
    static let ping = "kdeconnect.ping"
    static let telephony = "kdeconnect.telephony"
}

/// Generic KDE Connect packet.
///
/// Packets on the wire are a single JSON object terminated by `\n`:
/// `{ "id": 1234, "type": "kdeconnect.battery", "body": { ... } }`
/// `id` is a unix-epoch-ms timestamp. Some clients send it as a string,
/// so decoding is intentionally lenient.
struct KDEPacket {
    var id: Int64
    var type: String
    var body: [String: Any]
    /// Payload transfer (e.g. notification icons): top-level fields.
    var payloadSize: Int?
    var payloadPort: UInt16?

    init(type: String, body: [String: Any] = [:]) {
        self.id = Int64(Date().timeIntervalSince1970 * 1000)
        self.type = type
        self.body = body
    }

    /// A packet that offers a payload (e.g. album art) for the peer to fetch.
    init(type: String, body: [String: Any], payloadSize: Int, payloadPort: UInt16) {
        self.id = Int64(Date().timeIntervalSince1970 * 1000)
        self.type = type
        self.body = body
        self.payloadSize = payloadSize
        self.payloadPort = payloadPort
    }

    /// Encode to newline-terminated JSON data ready for the socket.
    func encode() -> Data? {
        var dict: [String: Any] = ["id": id, "type": type, "body": body]
        if let payloadSize, let payloadPort {
            dict["payloadSize"] = payloadSize
            dict["payloadTransferInfo"] = ["port": Int(payloadPort)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return nil }
        var framed = data
        framed.append(0x0A) // "\n"
        return framed
    }

    /// Decode one packet from newline-terminated JSON data.
    static func decode(from data: Data) -> KDEPacket? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        var id: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        if let n = obj["id"] as? NSNumber { id = n.int64Value }
        else if let s = obj["id"] as? String, let v = Int64(s) { id = v }
        let body = obj["body"] as? [String: Any] ?? [:]
        var packet = KDEPacket(id: id, type: type, body: body)
        if let n = obj["payloadSize"] as? NSNumber, n.intValue > 0 {
            packet.payloadSize = n.intValue
            if let info = obj["payloadTransferInfo"] as? [String: Any],
               let port = (info as [String: Any]).kdeInt("port"), port > 0, port < 65536 {
                packet.payloadPort = UInt16(port)
            }
        }
        return packet
    }

    private init(id: Int64, type: String, body: [String: Any]) {
        self.id = id
        self.type = type
        self.body = body
    }
}

// MARK: - Identity

/// Capabilities advertised by this Mac.
struct AppCapabilities {
    /// Whether the Mac offers its own media players to the phone (so the phone
    /// can control them). Read straight from UserDefaults so it is safe to
    /// evaluate off the main actor; shared with the settings UI.
    static var allowRemoteMediaControl: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.allowRemoteMediaControl) as? Bool ?? true
    }

    /// Whether clipboard text is exchanged with the phone.
    static var clipboardSync: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.clipboardSync) as? Bool ?? true
    }

    /// Packets we can receive from the phone.
    static var incoming: [String] {
        var packets = [
            KDEPacketType.battery,
            KDEPacketType.notification,
            KDEPacketType.smsMessages,
            KDEPacketType.ping,
            KDEPacketType.telephony,
            KDEPacketType.mpris,
        ]
        // The phone can drive this Mac's media.
        if allowRemoteMediaControl { packets.append(KDEPacketType.mprisRequest) }
        if clipboardSync {
            packets.append(KDEPacketType.clipboard)
            packets.append(KDEPacketType.clipboardConnect)
        }
        return packets
    }

    /// Packets we can send to the phone.
    static var outgoing: [String] {
        var packets = [
            KDEPacketType.batteryRequest,
            KDEPacketType.notificationRequest,
            KDEPacketType.notificationReply,
            KDEPacketType.notificationAction,
            KDEPacketType.smsRequest,
            KDEPacketType.smsRequestConversation,
            KDEPacketType.smsRequestConversations,
            KDEPacketType.findMyPhoneRequest,
            KDEPacketType.ping,
            KDEPacketType.mprisRequest,
        ]
        // This Mac exposes its media players to the phone.
        if allowRemoteMediaControl { packets.append(KDEPacketType.mpris) }
        if clipboardSync {
            packets.append(KDEPacketType.clipboard)
            packets.append(KDEPacketType.clipboardConnect)
        }
        return packets
    }

    static let protocolVersion = 8
    static let deviceType = "laptop"
}

/// Builds an identity packet body. `tcpPort` is filled in by the transport.
func makeIdentityBody(deviceId: String, deviceName: String, tcpPort: Int) -> [String: Any] {
    [
        "deviceId": deviceId,
        "deviceName": deviceName,
        "deviceType": AppCapabilities.deviceType,
        "protocolVersion": AppCapabilities.protocolVersion,
        "incomingCapabilities": AppCapabilities.incoming,
        "outgoingCapabilities": AppCapabilities.outgoing,
        "tcpPort": tcpPort,
    ]
}

// MARK: - Small parsing helpers (tolerant of missing/wrongly-typed fields)

extension Dictionary where Key == String {
    func kdeString(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }
    func kdeInt(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
    func kdeInt64(_ key: String) -> Int64? {
        if let n = self[key] as? NSNumber { return n.int64Value }
        if let s = self[key] as? String { return Int64(s) }
        return nil
    }
    func kdeBool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        return nil
    }
}
