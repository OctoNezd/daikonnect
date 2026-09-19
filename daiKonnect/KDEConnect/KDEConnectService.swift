import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO
import Security
import UserNotifications

/// Central KDE Connect LAN service: discovery, pairing, TLS links and plugins.
///
/// Threading: all `@Published` UI state is owned on the main thread. All
/// blocking socket work runs on background queues and hops back via
/// `DispatchQueue.main.async`. Public methods must be called from the main
/// thread (as SwiftUI does).
final class KDEConnectService: ObservableObject {
  static let shared = KDEConnectService()

  // MARK: UI state
  @Published var devices: [RemoteDevice] = []
  @Published var selectedDeviceId: String?
  @Published var isRunning = false
  @Published var statusMessage = "Stopped"
  @Published var setupError: String?
  @Published var batteries: [String: BatteryState] = [:]
  @Published var notifications: [String: [PhoneNotification]] = [:]
  @Published var conversations: [String: [SmsConversation]] = [:]
  /// Media players reported by each device, via the MPRIS plugin.
  @Published var mediaPlayers: [String: [MediaPlayer]] = [:]
  /// Asks the main window to switch to a tab (set by the menu bar panel,
  /// cleared by the detail view once it has honoured it).
  @Published var requestedDetailTab: DeviceTab?
  /// Change detection for the Mac's now-playing state.
  private var lastMacSignature: String?
  /// Last state reported to the phone, for optimistic transport updates.
  private var lastMacState: MacNowPlaying?
  private var lastMacPlayerName = "Mac"
  private var lastMacPositionSentMs = 0
  private var lastMacPositionSentAt: Date?
  private var macPollWorkItem: DispatchWorkItem?
  @Published var ringingDevices: Set<String> = []
  @Published var lastCallEvent: [String: String] = [:]

  // MARK: Diagnostics (visible in UI + ~/Library/Logs/daiKonnect.log)
  @Published var udpSentCount = 0
  @Published var udpReceivedCount = 0
  @Published var tcpAcceptCount = 0
  @Published var outboundCount = 0
  @Published var tlsOkCount = 0
  @Published var tlsFailCount = 0
  /// Consecutive handshake failures per peer address, used to explain what is
  /// usually a certificate mismatch rather than just reporting a failure.
  private var handshakeFailures: [String: Int] = [:]
  @Published var iconsFetched = 0
  @Published var iconFetchFailed = 0
  @Published var iconPayloadMissing = 0
  @Published var eventLog: [String] = []
  @Published var notificationAuthStatus = "checking…"
  /// The same state in a form the UI can branch on.
  @Published var notificationPermission: NotificationPermission = .unknown

  enum NotificationPermission: String { case unknown, notDetermined, allowed, denied }
  static let logFileURL: URL = FileManager.default
    .urls(for: .libraryDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Logs/daiKonnect.log")
  private static let logTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  /// Thread-safe: may be called from any queue.
  func log(_ message: String) {
    let line = "[\(Self.logTime.string(from: Date()))] \(message)"
    if Thread.isMainThread {
      appendLog(line)
    } else {
      DispatchQueue.main.async { [weak self] in self?.appendLog(line) }
    }
    let data = (line + "\n").data(using: .utf8) ?? Data()
    DispatchQueue.global(qos: .utility).async {
      if FileManager.default.fileExists(atPath: Self.logFileURL.path),
        let fh = try? FileHandle(forWritingTo: Self.logFileURL)
      {
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
        try? fh.close()
      } else {
        try? data.write(to: Self.logFileURL)
      }
    }
  }

  private func appendLog(_ line: String) {
    eventLog.append(line)
    if eventLog.count > 200 { eventLog.removeFirst(eventLog.count - 200) }
  }

  var selectedDevice: RemoteDevice? {
    devices.first { $0.id == selectedDeviceId }
  }

  // MARK: transport state (only touched on main except where noted)
  private var tcpListenFD: Int32 = -1
  private var tcpPort: UInt16 = KDE_UDP_PORT
  private var udpListenFD: Int32 = -1
  private var udpSendFD: Int32 = -1
  private var links: [String: KDELink] = [:]
  private var connecting: Set<String> = []
  private var broadcastTimer: Timer?
  private var pairTimeouts: [String: Timer] = [:]
  private var paired: [String: PairedInfo] = [:]
  /// Last-seen certificate fingerprints per device, collected from every
  /// link that exposes one (inbound links, where the phone is the TLS
  /// server and presents its certificate). Used to pin trust even when the
  /// currently active link is an outbound one (no peer cert visible).
  private var knownFingerprints: [String: String] = [:]
  /// Peer certificates seen on inbound links, keyed by device. Kept because
  /// the pairing verification key hashes the phone's public key, and an
  /// outbound link never carries it. Persisted so the key survives restarts.
  private var peerCertificates: [String: Data] = [:]
  /// Timestamp the current pairing in progress is bound to: ours when we
  /// asked, the phone's when it did. Protocol 8+ feeds it into the
  /// verification key, so both devices need the same value.
  private var pairingTimestamps: [String: Int] = [:]
  /// Devices the user accepted pairing for while no fingerprint was
  /// available yet; completed automatically once a fingerprint arrives.
  private var pendingAccept: Set<String> = []
  /// Pairings the phone itself accepted, waiting only for its certificate
  /// before being recorded. Distinct from `pendingAccept` because nothing
  /// may be sent back for these.
  private var pendingFinish: Set<String> = []
  // MARK: Clipboard
  /// Polls the pasteboard: macOS offers no notification when it changes.
  private var clipboardTimer: Timer?
  private var lastClipboardChangeCount = -1
  /// The last text we sent or applied, so a clipboard we set ourselves is
  /// not sent straight back.
  private var lastClipboardContent: String?
  /// When the clipboard last changed locally, in milliseconds — the value
  /// the phone compares against when deciding whether our copy is newer.
  private var lastLocalClipboardChangeMs: Int64 = 0
  /// Which app was frontmost when the clipboard last changed. macOS does not
  /// record who set it, so the frontmost app is the best available answer,
  /// and it is right for the case that matters: a password manager copying
  /// while it is the active window.
  private var lastClipboardSourceBundleID: String?

  /// Pairing requests queued while the device has no link yet; flushed in
  /// `registerLink` once the outbound connection is up.
  private var pendingPairRequest: Set<String> = []
  /// Notification cancellations queued while the device had no link. The
  /// link is very often down for a moment — a phone that has just woken
  /// reconnects a second later — and dropping the request silently made the
  /// Dismiss on phone button look broken whenever it was clicked in that
  /// window.
  private var pendingCancels: [String: [String]] = [:]
  /// Newest incoming SMS date already surfaced as a macOS notification,
  /// per device (prevents re-alerting on bulk re-syncs). Persisted so a
  /// restart doesn't re-announce the last text.
  private var lastSmsNotifyDate: [String: Date] = [:]
  /// Last low-battery alert state per device, persisted for the same reason.
  private var batteryLowNotified: [String: Bool] = [:]
  /// Icon hashes currently being downloaded, so the phone's repeated
  /// notifications for the same app don't trigger a fetch storm.
  private var inFlightIconFetches: Set<String> = []
  /// Where to fetch each icon hash from (host/port/size), remembered so the
  /// UI can retry a failed download later.
  private var iconFetchInfo: [String: (host: String, port: UInt16, size: Int)] = [:]
  /// Single-lane queue for icon downloads (the phone aborts concurrent ones).
  private let iconFetchQueue = DispatchQueue(label: "daiKonnect.iconfetch", qos: .utility)
  /// Icon bytes kept in memory, keyed by payload hash. The UI reads icons
  /// from here first so it never depends on cache files existing on disk
  /// (which have proven unreliable to read back).
  private var iconDataByHash: [String: Data] = [:]
  private let iconDataLock = NSLock()

  /// In-memory icon bytes for a hash (thread-safe).
  func iconData(for hash: String) -> Data? {
    iconDataLock.lock()
    defer { iconDataLock.unlock() }
    return iconDataByHash[hash]
  }

  private func storeIconData(_ data: Data, hash: String) {
    iconDataLock.lock()
    iconDataByHash[hash] = data
    iconDataLock.unlock()
  }

  /// Image for a notification, preferring memory, then the model path, then
  /// the on-disk cache. Pure read — safe to call from a view body.
  func iconImage(for item: PhoneNotification) -> NSImage? {
    if let hash = item.iconHash, let data = iconData(for: hash), let img = NSImage(data: data) {
      return img
    }
    if let path = item.iconFilePath,
      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let img = NSImage(data: data)
    {
      return img
    }
    if let hash = item.iconHash,
      let path = cachedIconPath(hash: hash),
      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let img = NSImage(data: data)
    {
      return img
    }
    return nil
  }
  private let store = IdentityStore.shared

  private var lockFD: Int32 = -1

  /// Refuse to run networking when another copy of the app is alive.
  /// Two instances fight over the phone (duplicate broadcasts, link
  /// stealing) and produce exactly the connect/drop flapping this guards.
  private func acquireSingleInstance() -> Bool {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("daiKonnect", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("instance.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }  // fail open if we can't lock
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      Darwin.close(fd)
      return false
    }
    if lockFD >= 0 { Darwin.close(lockFD) }
    lockFD = fd
    return true
  }

  private init() {
    loadPaired()
    loadPeerCertificates()
    // Restore previously known devices so the list isn't empty on a cold
    // boot; they show as offline until discovery/connect succeeds.
    // Skipped in previews, which shouldn't surface real device state.
    if !AppEnvironment.isPreview {
      for kd in Self.loadKnownDevices() {
        devices.append(
          RemoteDevice(
            deviceId: kd.deviceId, name: kd.name,
            deviceType: kd.deviceType, host: kd.host,
            tcpPort: kd.tcpPort,
            paired: paired[kd.deviceId] != nil,
            protocolVersion: kd.protocolVersion))
      }
      selectedDeviceId = devices.first?.deviceId
    }
  }

  // MARK: - Known-device persistence

  private struct KnownDevice: Codable {
    var deviceId: String
    var name: String
    var deviceType: String
    var host: String
    var tcpPort: UInt16
    var protocolVersion: Int
  }

  private static func loadKnownDevices() -> [KnownDevice] {
    guard let data = UserDefaults.standard.data(forKey: "daiKonnect.knownDevices"),
      let list = try? JSONDecoder().decode([KnownDevice].self, from: data)
    else { return [] }
    return list
  }

  private func saveKnownDevices() {
    let known = devices.map {
      KnownDevice(
        deviceId: $0.deviceId, name: $0.name, deviceType: $0.deviceType,
        host: $0.host, tcpPort: $0.tcpPort, protocolVersion: $0.protocolVersion)
    }
    if let data = try? JSONEncoder().encode(known) {
      UserDefaults.standard.set(data, forKey: "daiKonnect.knownDevices")
    }
  }

  // MARK: - Lifecycle

  func start() {
    guard !isRunning else { return }
    guard acquireSingleInstance() else {
      setupError =
        "Another copy of \(AppMeta.AppName) is already running. Quit it in Activity Monitor and try again."
      statusMessage = "Already running elsewhere"
      log("Refused to start: another instance holds the lock")
      return
    }
    if let err = store.ensureCertificate() {
      setupError = err
      statusMessage = "Certificate setup failed"
      return
    }
    guard store.loadIdentity() != nil, store.loadCertificateChain() != nil else {
      setupError =
        "Could not load TLS identity (identity.p12). Delete ~/Library/Application Support/\(AppMeta.AppName) and restart."
      statusMessage = "Certificate setup failed"
      return
    }
    // TCP listener on 1716..1764.
    var boundPort: UInt16?
    for port in KDE_TCP_PORT_MIN...KDE_TCP_PORT_MAX {
      let fd = LanTransport.makeTCPListenSocket(port: port)
      if fd >= 0 {
        tcpListenFD = fd
        boundPort = port
        break
      }
    }
    guard let port = boundPort else {
      setupError = "Could not bind TCP port 1716–1764. Is another KDE Connect instance running?"
      statusMessage = "Bind failed"
      return
    }
    tcpPort = port

    udpListenFD = LanTransport.makeUDPListenSocket(port: KDE_UDP_PORT)
    udpSendFD = LanTransport.makeUDPBroadcastSocket()
    guard udpListenFD >= 0, udpSendFD >= 0 else {
      setupError = "Could not bind UDP port 1716."
      statusMessage = "Bind failed"
      if tcpListenFD >= 0 {
        Darwin.close(tcpListenFD)
        tcpListenFD = -1
      }
      return
    }

    isRunning = true
    setupError = nil
    statusMessage = "Listening on TCP \(port). Broadcasting presence…"
    log("\(AppMeta.AppName) started (device \(store.deviceName), TCP \(port))")
    // Clear stale icon cache on fresh start so corrupt files from
    // previous builds are re-fetched with the new validation logic.
    clearIconCache()
    if port != KDE_UDP_PORT {
      log(
        "WARNING: TCP \(KDE_UDP_PORT) is busy, using \(port) — another app (possibly an old daiKonnect) may be interfering"
      )
      statusMessage = "Listening on TCP \(port) (1716 busy — check for another copy)"
    }
    ensureNotificationPermission()
    startAcceptLoop()
    startUDPListener()
    MacMediaController.shared.onChange = { [weak self] in
      self?.refreshMacNowPlaying()
    }
    MacMediaController.shared.startMonitoring()
    scheduleNextMacPoll(after: 1)
    if MacMediaController.shared.isAvailable {
      log("Mac media control available (phone can control this Mac's players)")
    }
    broadcastIdentity(force: true)
    broadcastTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      DispatchQueue.main.async { self?.broadcastIdentity() }
    }
    reconnectKnownDevices()
    startClipboardWatch()
  }

  /// On a cold boot, dial the devices we were paired with before instead of
  /// waiting for their broadcast (which may be blocked or slow).
  private func reconnectKnownDevices() {
    let candidates = devices.filter {
      paired[$0.deviceId] != nil && !$0.host.isEmpty && links[$0.deviceId] == nil
    }
    guard !candidates.isEmpty else { return }
    log("Reconnecting to \(candidates.count) known device(s)…")
    for dev in candidates {
      connecting.insert(dev.deviceId)
      DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
        self?.connectOutbound(deviceId: dev.deviceId, host: dev.host, port: dev.tcpPort)
      }
    }
  }

  func stop() {
    log("\(AppMeta.AppName) stopped")
    clipboardTimer?.invalidate()
    clipboardTimer = nil
    broadcastTimer?.invalidate()
    broadcastTimer = nil
    for t in pairTimeouts.values { t.invalidate() }
    pairTimeouts = [:]
    pendingPairRequest = []
    pendingAccept = []
    pendingFinish = []
    if lockFD >= 0 {
      Darwin.close(lockFD)
      lockFD = -1
    }
    for link in links.values { DispatchQueue.global().async { link.close() } }
    links = [:]
    connecting = []
    if tcpListenFD >= 0 {
      Darwin.close(tcpListenFD)
      tcpListenFD = -1
    }
    if udpListenFD >= 0 {
      Darwin.close(udpListenFD)
      udpListenFD = -1
    }
    if udpSendFD >= 0 {
      Darwin.close(udpSendFD)
      udpSendFD = -1
    }
    isRunning = false
    macPollWorkItem?.cancel()
    macPollWorkItem = nil
    MacMediaController.shared.onChange = nil
    MacMediaController.shared.stopMonitoring()
    statusMessage = "Stopped"
    devices = devices.map {
      var d = $0
      d.connected = false
      return d
    }
  }

  // MARK: - Identity broadcast / discovery

  func broadcastIdentity() {
    broadcastIdentity(force: false)
  }

  /// Broadcast our presence. Reference desktops (GSConnect, kdeconnectd)
  /// only broadcast on start / network change / on demand — NOT on a fast
  /// timer: the phone dials in on every broadcast it hears, so a 5s timer
  /// causes a permanent redial-and-replace storm with flapping links.
  /// We use 5s only while we have no links at all (discovery), 60s once
  /// any link is up, and always when forced (start, button).
  private var lastBroadcastAt: Date = .distantPast

  func broadcastIdentity(force: Bool) {
    guard isRunning else { return }
    let now = Date()
    let interval: TimeInterval = links.isEmpty ? 5 : 60
    if !force, now.timeIntervalSince(lastBroadcastAt) < interval { return }
    lastBroadcastAt = now
    let body = makeIdentityBody(
      deviceId: store.deviceId, deviceName: store.deviceName, tcpPort: Int(tcpPort))
    guard let data = KDEPacket(type: KDEPacketType.identity, body: body).encode() else { return }
    let sendFD = udpSendFD
    let targets = LanTransport.broadcastAddresses()
    udpSentCount += targets.count
    DispatchQueue.global(qos: .utility).async {
      for target in targets {
        LanTransport.udpSend(fd: sendFD, data: data, host: target, port: KDE_UDP_PORT)
      }
    }
  }

  private func startUDPListener() {
    let fd = udpListenFD
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var buf = [UInt8](repeating: 0, count: 65535)
      while true {
        var src = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &src) { ptr in
          ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            buf.withUnsafeMutableBytes { raw in
              recvfrom(fd, raw.baseAddress, raw.count, 0, sa, &srcLen)
            }
          }
        }
        if n < 0 {
          if errno == EBADF { break }  // socket closed on stop()
          continue
        }
        guard n > 0 else { continue }
        let data = Data(buf[0..<n])
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var a = src.sin_addr
        inet_ntop(AF_INET, &a, &ip, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: ip)
        DispatchQueue.main.async { [weak self] in self?.udpReceivedCount += 1 }
        guard let packet = KDEPacket.decode(from: data),
          packet.type == KDEPacketType.identity
        else { continue }
        let body = packet.body
        guard let peerId = body.kdeString("deviceId"), !peerId.isEmpty else { continue }
        let name = body.kdeString("deviceName") ?? "Unknown"
        let dtype = body.kdeString("deviceType") ?? "phone"
        let port = UInt16(body.kdeInt("tcpPort") ?? Int(KDE_UDP_PORT))
        let proto = body.kdeInt("protocolVersion") ?? 7
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.handleDiscovered(
            deviceId: peerId, name: name, type: dtype,
            host: host, port: port, proto: proto)
        }
      }
    }
  }

  private func handleDiscovered(
    deviceId: String, name: String, type: String,
    host: String, port: UInt16, proto: Int
  ) {
    if deviceId == store.deviceId { return }  // our own broadcast
    let isNew = !devices.contains { $0.deviceId == deviceId }
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].lastSeen = Date()
      devices[idx].host = host
      devices[idx].tcpPort = port
      devices[idx].name = name
      devices[idx].protocolVersion = proto
    } else {
      let pairedInfo = paired[deviceId]
      devices.append(
        RemoteDevice(
          deviceId: deviceId, name: pairedInfo?.name ?? name,
          deviceType: type, host: host, tcpPort: port,
          paired: pairedInfo != nil, protocolVersion: proto))
      statusMessage = "Found \(name)"
    }
    if isNew {
      log("Discovered '\(name)' (\(type)) at \(host):\(port), protocol v\(proto)")
    }
    saveKnownDevices()
    // If paired and not connected, (re)connect. Small delay avoids
    // connection storms when both sides dial simultaneously.
    if paired[deviceId] != nil, links[deviceId] == nil, !connecting.contains(deviceId) {
      connecting.insert(deviceId)
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
        [weak self, deviceId, host, port] in
        self?.connectOutbound(deviceId: deviceId, host: host, port: port)
      }
    }
  }

  // MARK: - Manual connect

  func connectManually(host: String, port: UInt16 = KDE_UDP_PORT) {
    guard isRunning else { return }
    statusMessage = "Connecting to \(host):\(port)…"
    // Send our identity datagram straight at them so they learn our port,
    // then open the TCP link.
    let body = makeIdentityBody(
      deviceId: store.deviceId, deviceName: store.deviceName, tcpPort: Int(tcpPort))
    if let data = KDEPacket(type: KDEPacketType.identity, body: body).encode() {
      let sendFD = udpSendFD
      DispatchQueue.global().async {
        LanTransport.udpSend(fd: sendFD, data: data, host: host, port: KDE_UDP_PORT)
      }
    }
    DispatchQueue.global().async { [weak self] in
      let fd = LanTransport.tcpConnect(host: host, port: port)
      guard fd >= 0 else {
        let why = LanTransport.lastConnectFailure ?? "unknown"
        DispatchQueue.main.async { [weak self] in
          self?.statusMessage = "Could not reach \(host):\(port): \(why)"
        }
        return
      }
      self?.finishOutbound(fd: fd, expectedHost: host)
    }
  }

  // MARK: - TCP accept loop (inbound: we are the TLS client)

  private func startAcceptLoop() {
    let fd = tcpListenFD
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      while true {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let cfd = withUnsafeMutablePointer(to: &addr) { ptr in
          ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
        }
        if cfd < 0 {
          if errno == EBADF { break }
          continue
        }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var a = addr.sin_addr
        inet_ntop(AF_INET, &a, &ip, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: ip)
        DispatchQueue.main.async { [weak self] in
          self?.tcpAcceptCount += 1
          self?.log("TCP connection accepted from \(host)")
        }
        self?.handleInbound(fd: cfd)
      }
    }
  }

  private func handleInbound(fd: Int32) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        Darwin.close(fd)
        return
      }
      let host = LanTransport.peerIP(fd: fd)
      let link = KDELink(fd: fd, remoteHost: host, outbound: false)
      // 1. plaintext identity from the initiator.
      guard let line = link.readPlaintextLine(),
        let idPacket = KDEPacket.decode(from: line),
        idPacket.type == KDEPacketType.identity,
        let peerId = idPacket.body.kdeString("deviceId")
      else {
        DispatchQueue.global().async { link.close() }
        self.log("Inbound from \(host): no plaintext identity, dropped")
        return
      }
      let peerPort = UInt16(idPacket.body.kdeInt("tcpPort") ?? Int(KDE_UDP_PORT))
      let peerProto = idPacket.body.kdeInt("protocolVersion") ?? 7
      // 2. upgrade to TLS as client.
      guard self.tlsUpgrade(link: link) else {
        DispatchQueue.global().async { link.close() }
        self.log("Inbound from \(host): TLS handshake failed")
        DispatchQueue.main.async { [weak self] in
          self?.tlsFailCount += 1
          self?.noteHandshakeFailure(peer: host)
        }
        return
      }
      DispatchQueue.main.async { [weak self] in
        self?.tlsOkCount += 1
        self?.clearHandshakeFailures(peer: host)
      }
      // 3. encrypted identity re-exchange (protocol v8+ only, like the
      //    official apps): we send ours, then read theirs. Older peers
      //    reuse the plaintext identity instead.
      let hello = KDEPacket(
        type: KDEPacketType.identity,
        body: makeIdentityBody(
          deviceId: self.store.deviceId,
          deviceName: self.store.deviceName,
          tcpPort: Int(self.tcpPort)))
      var peerName = idPacket.body.kdeString("deviceName") ?? "Unknown"
      var peerType = idPacket.body.kdeString("deviceType") ?? "phone"
      if peerProto >= 8 {
        guard link.sendPacket(hello) else {
          DispatchQueue.global().async { link.close() }
          self.log("Inbound from \(host): failed sending encrypted identity")
          return
        }
        guard let encLine = link.readEncryptedLine() else {
          DispatchQueue.global().async { link.close() }
          self.log("Inbound from \(host): failed reading encrypted identity (closed by peer?)")
          return
        }
        guard let encId = KDEPacket.decode(from: encLine),
          encId.type == KDEPacketType.identity
        else {
          DispatchQueue.global().async { link.close() }
          let preview =
            String(data: encLine.prefix(160), encoding: .utf8) ?? "<binary \(encLine.count)B>"
          self.log("Inbound from \(host): bad encrypted identity (\(encLine.count)B): \(preview)")
          return
        }
        // Validate like the official apps: same version, same device.
        let secureProto = encId.body.kdeInt("protocolVersion") ?? -1
        let secureId = encId.body.kdeString("deviceId") ?? ""
        guard secureProto == peerProto, secureId == peerId, !peerId.isEmpty else {
          DispatchQueue.global().async { link.close() }
          self.log("Inbound from \(host): identity changed mid-handshake, dropped")
          return
        }
        peerName = encId.body.kdeString("deviceName") ?? peerName
        peerType = encId.body.kdeString("deviceType") ?? peerType
      }
      let fingerprint = link.peerFingerprint()
      let certificate = link.peerCertificateDER()
      self.log(
        "Inbound from \(host): link ready for '\(peerName)' (cert \(fingerprint != nil ? "seen" : "not visible"))"
      )
      DispatchQueue.main.async { [weak self] in
        self?.registerLink(
          deviceId: peerId, name: peerName, type: peerType,
          host: host, port: peerPort, link: link,
          fingerprint: fingerprint, certificate: certificate,
          protocolVersion: peerProto)
      }
      self.pumpPackets(deviceId: peerId, link: link)
    }
  }

  // MARK: - Outbound connect (we are the TLS server)

  /// A dial that cannot reach the host usually means the phone's address has
  /// changed. DHCP hands out a new one whenever its MAC changes, and the
  /// address we saved then points at a host that is not there — while the
  /// phone itself is fine and can still reach us. Broadcasting makes it dial
  /// us, and that incoming link carries the address it has now, which is
  /// saved for next time.
  private func requestFreshAddress(after what: String) {
    let errno = LanTransport.lastConnectErrno
    guard errno == EHOSTUNREACH || errno == EHOSTDOWN || errno == ETIMEDOUT else { return }
    log("\(what): address looks stale — asking the phone to announce itself")
    DispatchQueue.main.async { [weak self] in self?.broadcastIdentity(force: true) }
  }

  private func connectOutbound(deviceId: String, host: String, port: UInt16) {
    DispatchQueue.main.async { [weak self] in self?.outboundCount += 1 }
    let fd = LanTransport.tcpConnect(host: host, port: port)
    guard fd >= 0 else {
      let why = LanTransport.lastConnectFailure ?? "unknown"
      self.requestFreshAddress(after: "Connect to \(host):\(port)")
      // A dial that fails while this device is already linked means the
      // phone is on the network and we are the ones being refused.
      self.noteDialFailure("Dial to \(host):\(port)", deviceId: deviceId)
      DispatchQueue.main.async { [weak self] in
        self?.connecting.remove(deviceId)
        self?.log("TCP connect to \(host):\(port) failed (device \(deviceId.prefix(8))…): \(why)")
      }
      return
    }
    log("TCP connected to \(host):\(port), starting handshake…")
    finishOutbound(fd: fd, expectedHost: host, expectedDeviceId: deviceId)
  }

  private func finishOutbound(fd: Int32, expectedHost: String, expectedDeviceId: String? = nil) {
    func doneConnecting(_ peerId: String?) {
      DispatchQueue.main.async { [weak self] in
        if let peerId { self?.connecting.remove(peerId) }
        if let expected = expectedDeviceId { self?.connecting.remove(expected) }
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        Darwin.close(fd)
        return
      }
      let link = KDELink(fd: fd, remoteHost: expectedHost, outbound: true)
      // 1. plaintext identity first.
      let hello = KDEPacket(
        type: KDEPacketType.identity,
        body: makeIdentityBody(
          deviceId: self.store.deviceId,
          deviceName: self.store.deviceName,
          tcpPort: Int(self.tcpPort)))
      guard let helloData = hello.encode(), link.sendPlaintext(helloData) else {
        DispatchQueue.global().async { link.close() }
        self.log("Outbound to \(expectedHost): plaintext send failed")
        doneConnecting(nil)
        return
      }
      // 2. upgrade to TLS as server.
      guard self.tlsUpgrade(link: link) else {
        DispatchQueue.global().async { link.close() }
        self.log("Outbound to \(expectedHost): TLS handshake failed")
        DispatchQueue.main.async { [weak self] in
          self?.tlsFailCount += 1
          self?.noteHandshakeFailure(peer: expectedHost)
        }
        doneConnecting(nil)
        return
      }
      DispatchQueue.main.async { [weak self] in
        self?.tlsOkCount += 1
        self?.clearHandshakeFailures(peer: expectedHost)
      }
      self.log("Outbound to \(expectedHost): TLS established")
      // 3. encrypted re-exchange: SEND ours first, then read theirs.
      //    Send-first on both roles guarantees no deadlock regardless of
      //    which side the peer reads first.
      guard link.sendPacket(hello) else {
        DispatchQueue.global().async { link.close() }
        self.log("Outbound to \(expectedHost): failed sending encrypted identity")
        doneConnecting(nil)
        return
      }
      guard let encLine = link.readEncryptedLine() else {
        DispatchQueue.global().async { link.close() }
        self.log("Outbound to \(expectedHost): failed reading encrypted identity (closed by peer?)")
        doneConnecting(nil)
        return
      }
      guard let encId = KDEPacket.decode(from: encLine),
        encId.type == KDEPacketType.identity,
        let peerId = encId.body.kdeString("deviceId")
      else {
        DispatchQueue.global().async { link.close() }
        let preview =
          String(data: encLine.prefix(160), encoding: .utf8) ?? "<binary \(encLine.count)B>"
        self.log(
          "Outbound to \(expectedHost): bad encrypted identity (\(encLine.count)B): \(preview)")
        doneConnecting(nil)
        return
      }
      if let expected = expectedDeviceId, expected != peerId {
        DispatchQueue.global().async { link.close() }
        self.log("Outbound to \(expectedHost): device ID changed mid-handshake, dropped")
        doneConnecting(expected)
        return
      }
      let name = encId.body.kdeString("deviceName") ?? "Unknown"
      let dtype = encId.body.kdeString("deviceType") ?? "phone"
      let peerPort = UInt16(encId.body.kdeInt("tcpPort") ?? Int(KDE_UDP_PORT))
      let fingerprint = link.peerFingerprint()
      let certificate = link.peerCertificateDER()
      let peerProto = encId.body.kdeInt("protocolVersion") ?? 7
      DispatchQueue.main.async { [weak self] in
        doneConnecting(peerId)
        self?.registerLink(
          deviceId: peerId, name: name, type: dtype,
          host: expectedHost, port: peerPort, link: link,
          fingerprint: fingerprint, certificate: certificate,
          protocolVersion: peerProto)
      }
      self.pumpPackets(deviceId: peerId, link: link)
    }
  }

  private func tlsUpgrade(link: KDELink) -> Bool {
    guard let identity = store.loadIdentity(),
      let chain = store.loadCertificateChain(),
      let cert = chain.first
    else { return false }
    return link.startTLS(identity: identity, certificate: cert)
  }

  // MARK: - Link registry

  private func registerLink(
    deviceId: String, name: String, type: String,
    host: String, port: UInt16, link: KDELink,
    fingerprint: String?, certificate: Data?,
    protocolVersion: Int
  ) {
    // Adopt the newest link and drop the older one.
    //
    // The phone keeps exactly one link per device and points it at the
    // newest socket that arrives — Android's LanLinkProvider calls
    // link.reset() when a connection comes in for a device it already has.
    // Holding on to an older link here therefore leaves the phone talking
    // on a socket this side has just closed, which reads as the phone
    // dropping the connection and reconnecting over and over.
    //
    // Trust does not depend on which link is kept: the fingerprint and the
    // certificate are remembered per device, from whichever link carried
    // them.
    if let old = links[deviceId], old !== link {
      let captured = old
      DispatchQueue.global().async { captured.close() }
    }
    links[deviceId] = link
    if let fp = fingerprint { knownFingerprints[deviceId] = fp }
    if let certificate {
      peerCertificates[deviceId] = certificate
      savePeerCertificates()
    }
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].connected = true
      devices[idx].lastSeen = Date()
      devices[idx].host = host
      devices[idx].tcpPort = port
      devices[idx].name = paired[deviceId]?.name ?? name
      devices[idx].protocolVersion = protocolVersion
    } else {
      devices.append(
        RemoteDevice(
          deviceId: deviceId, name: paired[deviceId]?.name ?? name,
          deviceType: type, host: host, tcpPort: port,
          connected: true, paired: paired[deviceId] != nil))
    }
    if selectedDeviceId == nil { selectedDeviceId = deviceId }

    // Trust check against the pinned fingerprint. The active link may be
    // an outbound one without a visible peer cert; fall back to the
    // fingerprint observed on any earlier link from the same device.
    let effectiveFP = fingerprint ?? knownFingerprints[deviceId]
    if let known = paired[deviceId], let fp = effectiveFP {
      if known.fingerprint == fp {
        setPaired(deviceId, paired: true)
        statusMessage = "Connected to \(devices.first { $0.deviceId == deviceId }?.name ?? name)"
        // Pull fresh state.
        requestBattery(deviceId: deviceId)
        requestNotifications(deviceId: deviceId)
        requestConversations(deviceId: deviceId)
        requestPlayerList(deviceId: deviceId)
        refreshMacNowPlaying(force: true)
      } else {
        // Same deviceId, different certificate: treat as hostile/new.
        setPaired(deviceId, paired: false)
        statusMessage = "Certificate changed for \(name) — please pair again"
      }
    } else if paired[deviceId] != nil {
      // Paired, but no fingerprint seen yet (outbound-only link).
      // Trust provisionally; the check runs again once an inbound
      // link delivers the certificate.
      setPaired(deviceId, paired: true)
      requestBattery(deviceId: deviceId)
      requestNotifications(deviceId: deviceId)
      requestConversations(deviceId: deviceId)
      requestPlayerList(deviceId: deviceId)
      refreshMacNowPlaying(force: true)
    } else {
      statusMessage = "Connected to unpaired device \(name) — pairing required"
    }

    // Finish a user-approved pairing that was waiting for the certificate.
    if pendingAccept.contains(deviceId), effectiveFP != nil {
      pendingAccept.remove(deviceId)
      pendingFinish.remove(deviceId)
      completePairing(deviceId: deviceId, fingerprint: effectiveFP!, sendAccept: true)
    } else if pendingFinish.contains(deviceId), effectiveFP != nil {
      pendingFinish.remove(deviceId)
      completePairing(deviceId: deviceId, fingerprint: effectiveFP!, sendAccept: false)
    }

    // Deliver a pairing request that was queued while offline.
    if pendingPairRequest.remove(deviceId) != nil, links[deviceId] != nil {
      log("Delivering queued pairing request to \(displayName(deviceId))")
      sendPairRequest(deviceId: deviceId)
    } else {
      log(
        "Link registered for \(displayName(deviceId)) (paired: \(paired[deviceId] != nil), cert \(effectiveFP != nil ? "verified" : "pending"))"
      )
    }
    // Remember this device (name/host may have changed since discovery).
    saveKnownDevices()
    // An outbound link that got this far proves our own connections work:
    // dial, TLS handshake and identity exchange all completed.
    if link.directionOutbound { noteDialSuccess() }
    flushPendingCancels(deviceId: deviceId)
    if paired[deviceId] != nil { sendClipboardOnConnect(deviceId: deviceId) }
  }

  private func dropLink(_ deviceId: String) {
    if let link = links.removeValue(forKey: deviceId) {
      DispatchQueue.global().async { link.close() }
      log("Disconnected from \(displayName(deviceId))")
    }
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].connected = false
    }
    if ringingDevices.contains(deviceId) {
      ringingDevices.remove(deviceId)
    }
  }

  private func link(for deviceId: String) -> KDELink? { links[deviceId] }

  private func send(to deviceId: String, packet: KDEPacket) {
    guard let link = links[deviceId] else {
      log("Send \(packet.type) to \(displayName(deviceId)): no link")
      return
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      if !link.sendPacket(packet) {
        DispatchQueue.main.async { [weak self] in
          self?.log(
            "Send \(packet.type) to \(self?.displayName(deviceId) ?? "?") failed → dropping link")
          self?.dropLink(deviceId)
        }
      }
    }
  }

  // MARK: - Packet pump

  private func pumpPackets(deviceId: String, link: KDELink) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      while true {
        guard let line = link.readEncryptedLine() else { break }
        guard let packet = KDEPacket.decode(from: line) else { continue }
        DispatchQueue.main.async { [weak self] in
          self?.handlePacket(deviceId: deviceId, packet: packet)
        }
      }
      DispatchQueue.main.async { [weak self] in
        // Only drop if this is still the active link.
        if self?.links[deviceId] === link {
          let why = link.lastReadFailure ?? "closed"
          self?.log("Link to \(self?.displayName(deviceId) ?? "?"): \(why) → dropping")
          self?.dropLink(deviceId)
        }
      }
    }
  }

  private func handlePacket(deviceId: String, packet: KDEPacket) {
    touch(deviceId)
    switch packet.type {
    case KDEPacketType.pair:
      handlePair(deviceId: deviceId, body: packet.body)
    case KDEPacketType.battery:
      handleBattery(deviceId: deviceId, body: packet.body)
    case KDEPacketType.notification:
      handleNotification(deviceId: deviceId, packet: packet)
    case KDEPacketType.smsMessages:
      handleSmsMessages(deviceId: deviceId, body: packet.body)
    case KDEPacketType.ping:
      let msg = packet.body.kdeString("message") ?? "Ping"
      statusMessage = "Ping from \(displayName(deviceId)): \(msg)"
      log("Ping from \(displayName(deviceId)): \(msg)")
      postUserNotification(title: "Ping — \(displayName(deviceId))", body: msg, codeSource: msg)
    case KDEPacketType.telephony:
      handleTelephony(deviceId: deviceId, body: packet.body)
    case KDEPacketType.mpris:
      handleMpris(deviceId: deviceId, packet: packet)
    case KDEPacketType.mprisRequest:
      handleMacMprisRequest(deviceId: deviceId, body: packet.body)
    case KDEPacketType.clipboard, KDEPacketType.clipboardConnect:
      handleClipboardPacket(deviceId: deviceId, packet: packet)
    default:
      break  // other plugins not implemented
    }
  }

  private func touch(_ deviceId: String) {
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].lastSeen = Date()
    }
  }

  private func displayName(_ deviceId: String) -> String {
    devices.first { $0.deviceId == deviceId }?.name ?? "Phone"
  }

  // MARK: - Pairing

  private func loadPeerCertificates() {
    guard
      let stored = UserDefaults.standard.dictionary(forKey: "daiKonnect.peerCertificates")
        as? [String: String]
    else { return }
    peerCertificates = stored.compactMapValues { Data(base64Encoded: $0) }
  }

  private func savePeerCertificates() {
    let encoded = peerCertificates.mapValues { $0.base64EncodedString() }
    UserDefaults.standard.set(encoded, forKey: "daiKonnect.peerCertificates")
  }

  private func loadPaired() {
    if let data = UserDefaults.standard.data(forKey: "daiKonnect.paired"),
      let decoded = try? JSONDecoder().decode([String: PairedInfo].self, from: data)
    {
      paired = decoded
    }
  }

  private func savePaired() {
    if let data = try? JSONEncoder().encode(paired) {
      UserDefaults.standard.set(data, forKey: "daiKonnect.paired")
    }
  }

  private func setPaired(_ deviceId: String, paired pairedFlag: Bool) {
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].paired = pairedFlag
      if !pairedFlag {
        devices[idx].pairRequestedByPeer = false
        devices[idx].pairRequestedByUs = false
      }
    }
  }

  func requestPairing(deviceId: String) {
    // If there is no link yet, dial out first: the pair packet is
    // delivered by registerLink once the connection is up. This also
    // makes pairing work when only outbound connections succeed
    // (e.g. Mac firewall blocking inbound).
    guard links[deviceId] != nil else {
      pendingPairRequest.insert(deviceId)
      if connecting.contains(deviceId) {
        statusMessage = "Connecting to \(displayName(deviceId))…"
        return
      }
      guard let dev = devices.first(where: { $0.deviceId == deviceId }), !dev.host.isEmpty else {
        statusMessage = "No route to device yet — wait for discovery"
        return
      }
      connecting.insert(deviceId)
      statusMessage = "Connecting to \(dev.name) to send pairing request…"
      log("Dialing \(dev.name) at \(dev.host):\(dev.tcpPort) for pairing")
      let host = dev.host
      let port = dev.tcpPort
      DispatchQueue.global().async { [weak self] in
        self?.connectOutbound(deviceId: deviceId, host: host, port: port)
      }
      return
    }
    sendPairRequest(deviceId: deviceId)
  }

  private func sendPairRequest(deviceId: String) {
    // Protocol v8 requires a timestamp (seconds) on pairing requests;
    // the phone derives the verification code from it and rejects
    // requests without one. Accepts and rejects carry no timestamp.
    let timestamp = Int(Date().timeIntervalSince1970)
    let body: [String: Any] = ["pair": true, "timestamp": timestamp]
    pairingTimestamps[deviceId] = timestamp
    send(to: deviceId, packet: KDEPacket(type: KDEPacketType.pair, body: body))
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].pairRequestedByUs = true
    }
    pairTimeouts[deviceId]?.invalidate()
    pairTimeouts[deviceId] = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) {
      [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if let i = self.devices.firstIndex(where: { $0.deviceId == deviceId }),
          !self.devices[i].paired
        {
          self.devices[i].pairRequestedByUs = false
          self.statusMessage = "Pairing with \(self.devices[i].name) timed out"
        }
      }
    }
    statusMessage = "Pairing request sent — accept it on your phone"
  }

  /// Set when this Mac will not let the app open connections to the local
  /// network. macOS gates that behind a permission and refuses it silently
  /// for an app that never asked, which looks like a dead network: the
  /// phone is plainly reachable — it is connected to us and sending — yet
  /// every connection we open is refused.
  @Published var localNetworkBlocked = false
  /// Consecutive dial failures, so one blip does not raise the notice.
  private var unreachableDialCount = 0

  /// Called when a dial to the phone failed. Distinguishes "the phone is
  /// gone" from "we are not allowed to reach it": if the phone has a live
  /// link with us, it is on the network, so being unable to connect means
  /// our own connections are being refused.
  private func noteDialFailure(_ what: String, deviceId: String?) {
    guard
      LanTransport.lastConnectErrno == EHOSTUNREACH || LanTransport.lastConnectErrno == EHOSTDOWN
    else {
      unreachableDialCount = 0
      return
    }
    countRefusedConnection(what, deviceId: deviceId)
  }

  /// A payload connection that opens but cannot finish its TLS handshake is
  /// the same story told differently: with access revoked the socket
  /// connects and then nothing can be sent over it, so the handshake is
  /// where it dies. The phone being linked is what makes it evidence.
  private func notePayloadHandshakeFailure(_ what: String, deviceId: String?) {
    countRefusedConnection(what, deviceId: deviceId)
  }

  private func countRefusedConnection(_ what: String, deviceId: String?) {
    guard let deviceId, links[deviceId] != nil else { return }
    unreachableDialCount += 1
    // Two, not more: the guard above is strong — the device is linked to
    // us, so it is on the network and only our own connections are being
    // refused. Waiting for a third just adds a minute of silence.
    guard unreachableDialCount >= 2, !localNetworkBlocked else { return }
    localNetworkBlocked = true
    log(
      "Every outgoing connection is being refused while the phone is connected to us — macOS withholds local network access from an app that has not been granted it. Allow \(AppMeta.AppName) under System Settings → Privacy & Security → Local Network."
    )
    postUserNotification(
      title: "Local network access needed",
      body:
        "\(AppMeta.AppName) can't open connections to your phone. Allow it under System Settings → Privacy & Security → Local Network."
    )
  }

  private func noteDialSuccess() {
    unreachableDialCount = 0
    if localNetworkBlocked { localNetworkBlocked = false }
  }

  /// Opens System Settings at the Local Network list.
  func openLocalNetworkSettings() {
    let candidates = [
      "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
      "x-apple.systempreferences:com.apple.preference.security",
    ]
    for candidate in candidates {
      if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
    }
  }

  /// The short key both devices display during pairing so the user can
  /// check it is the same phone they are looking at. Nil until the phone's
  /// certificate has been seen, which an outbound link alone never delivers.
  func verificationKey(deviceId: String) -> String? {
    guard let own = store.ownCertificate(),
      let peerDER = peerCertificates[deviceId],
      let peer = SecCertificateCreateWithData(nil, peerDER as CFData)
    else { return nil }
    let version =
      devices.first { $0.deviceId == deviceId }?.protocolVersion
      ?? AppCapabilities.protocolVersion
    return VerificationKey.compute(
      local: own, peer: peer,
      timestamp: pairingTimestamps[deviceId],
      protocolVersion: version)
  }

  /// The phone accepted a request we sent. Record the pairing, but send
  /// nothing: it already considers itself paired with us.
  private func finishPairingAcceptedByPeer(deviceId: String) {
    log(
      "\(displayName(deviceId)) accepted our pairing request — no accept is sent back, the phone is already paired"
    )
    if let fp = links[deviceId]?.peerFingerprint() ?? knownFingerprints[deviceId] {
      completePairing(deviceId: deviceId, fingerprint: fp, sendAccept: false)
      return
    }
    // Accepted over an outbound link, which carries no certificate. The
    // record is written once the phone's own inbound link arrives.
    pendingFinish.insert(deviceId)
    statusMessage = "Waiting for \(displayName(deviceId)) to reconnect…"
  }

  func acceptPairing(deviceId: String) {
    if let fp = links[deviceId]?.peerFingerprint() ?? knownFingerprints[deviceId] {
      completePairing(deviceId: deviceId, fingerprint: fp, sendAccept: true)
      return
    }
    guard links[deviceId] != nil else {
      statusMessage = "Device is offline — cannot complete pairing"
      return
    }
    // Online but the active link exposes no certificate yet (outbound
    // link). Wait for the phone's inbound connection, which carries it.
    pendingAccept.insert(deviceId)
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].pairRequestedByPeer = false
    }
    statusMessage =
      "Waiting for a secure connection to \(displayName(deviceId))… keep KDE Connect open on the phone"
    broadcastIdentity(force: true)
  }

  /// `sendAccept` is whether the phone is still waiting to hear that we
  /// accept its request. When the phone is the one that accepted ours, a
  /// second pair=true is read by Android as a fresh request from a device it
  /// already trusts, which makes it unpair and start over — the "it instantly
  /// unpaired" symptom. So ask, and stay quiet in that direction.
  private func completePairing(deviceId: String, fingerprint: String, sendAccept: Bool) {
    let name = displayName(deviceId)
    paired[deviceId] = PairedInfo(name: name, fingerprint: fingerprint)
    knownFingerprints[deviceId] = fingerprint
    savePaired()
    setPaired(deviceId, paired: true)
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].pairRequestedByPeer = false
      devices[idx].pairRequestedByUs = false
    }
    pairTimeouts[deviceId]?.invalidate()
    if sendAccept {
      send(to: deviceId, packet: KDEPacket(type: KDEPacketType.pair, body: ["pair": true]))
    }
    statusMessage = "Paired with \(name)"
    requestBattery(deviceId: deviceId)
    requestNotifications(deviceId: deviceId)
    requestConversations(deviceId: deviceId)
    requestPlayerList(deviceId: deviceId)
  }

  func declinePairing(deviceId: String) {
    send(to: deviceId, packet: KDEPacket(type: KDEPacketType.pair, body: ["pair": false]))
    pendingAccept.remove(deviceId)
    pendingFinish.remove(deviceId)
    if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
      devices[idx].pairRequestedByPeer = false
      devices[idx].pairRequestedByUs = false
    }
  }

  /// Three handshakes in a row from the same peer almost always means it
  /// still trusts a certificate this Mac no longer has — typically because
  /// the app's stored identity was cleared and a new one was generated.
  private func noteHandshakeFailure(peer: String) {
    let count = (handshakeFailures[peer] ?? 0) + 1
    handshakeFailures[peer] = count
    guard count == 3 else { return }
    log(
      "\(peer) keeps failing the TLS handshake: its stored certificate no longer matches this Mac's. Unpair the Mac on the phone (KDE Connect → this device → Unpair), then pair again."
    )
    statusMessage = "Certificate mismatch with \(peer) — unpair on the phone, then pair again"
  }

  private func clearHandshakeFailures(peer: String) {
    handshakeFailures.removeValue(forKey: peer)
  }

  func unpair(deviceId: String) {
    send(to: deviceId, packet: KDEPacket(type: KDEPacketType.pair, body: ["pair": false]))
    paired.removeValue(forKey: deviceId)
    knownFingerprints.removeValue(forKey: deviceId)
    peerCertificates.removeValue(forKey: deviceId)
    pairingTimestamps.removeValue(forKey: deviceId)
    pendingAccept.remove(deviceId)
    pendingFinish.remove(deviceId)
    savePaired()
    savePeerCertificates()
    setPaired(deviceId, paired: false)
    statusMessage = "Unpaired \(displayName(deviceId))"
  }

  private func handlePair(deviceId: String, body: [String: Any]) {
    guard let pair = body.kdeBool("pair") else { return }
    log("Pair packet from \(displayName(deviceId)): \(pair ? "request/accept" : "reject/unpair")")
    if pair {
      if paired[deviceId] != nil {
        // Already trusted: the phone (re)confirmed. Make sure UI agrees.
        setPaired(deviceId, paired: true)
        if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
          devices[idx].pairRequestedByUs = false
        }
        pairTimeouts[deviceId]?.invalidate()
        return
      }
      // Our own request was accepted on the phone: our user already
      // approved, so complete pairing without asking again.
      if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }),
        devices[idx].pairRequestedByUs
      {
        devices[idx].pairRequestedByUs = false
        pairTimeouts[deviceId]?.invalidate()
        finishPairingAcceptedByPeer(deviceId: deviceId)
        return
      }
      // New pairing request from the phone — needs explicit user approval.
      //
      // From protocol 8 the request carries the timestamp the key is
      // bound to. Missing it, or a clock far from ours, means the two
      // devices would display different keys and the comparison the
      // whole flow exists for would be meaningless.
      let peerVersion =
        devices.first { $0.deviceId == deviceId }?.protocolVersion
        ?? AppCapabilities.protocolVersion
      if peerVersion >= 8 {
        guard let timestamp = body.kdeInt("timestamp") else {
          log(
            "Pairing request from \(displayName(deviceId)) carries no timestamp — refusing, protocol 8 requires one"
          )
          statusMessage =
            "Refused a pairing request from \(displayName(deviceId)) with no timestamp"
          send(to: deviceId, packet: KDEPacket(type: KDEPacketType.pair, body: ["pair": false]))
          return
        }
        let ours = Int(Date().timeIntervalSince1970)
        guard abs(timestamp - ours) <= 1800 else {
          log(
            "Clock mismatch with \(displayName(deviceId)): request is stamped \(timestamp), this Mac says \(ours). The verification keys would never match — check both clocks and pair again."
          )
          statusMessage =
            "Clock mismatch with \(displayName(deviceId)) — check the clocks on both devices"
          send(to: deviceId, packet: KDEPacket(type: KDEPacketType.pair, body: ["pair": false]))
          return
        }
        pairingTimestamps[deviceId] = timestamp
      }

      if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
        devices[idx].pairRequestedByPeer = true
        devices[idx].lastSeen = Date()
      } else {
        devices.append(
          RemoteDevice(
            deviceId: deviceId, name: "Unknown phone",
            deviceType: "phone", host: "", tcpPort: KDE_UDP_PORT,
            connected: links[deviceId] != nil,
            pairRequestedByPeer: true))
      }
      statusMessage = "Pairing request from \(displayName(deviceId))"
      let key = verificationKey(deviceId: deviceId)
      let body =
        "\(displayName(deviceId)) wants to pair with this Mac."
        + (key.map { " Confirm the key \($0) matches the one on the phone." } ?? "")
      postUserNotification(title: "Pairing request", body: body)
    } else {
      // Rejected or unpaired.
      pendingAccept.remove(deviceId)
      pendingFinish.remove(deviceId)
      if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
        let wasRequest = devices[idx].pairRequestedByUs
        devices[idx].pairRequestedByPeer = false
        devices[idx].pairRequestedByUs = false
        if paired[deviceId] != nil {
          paired.removeValue(forKey: deviceId)
          savePaired()
          setPaired(deviceId, paired: false)
          statusMessage = "\(displayName(deviceId)) unpaired"
          dropLink(deviceId)
        } else if wasRequest {
          statusMessage = "\(displayName(deviceId)) rejected pairing"
        }
      }
      pairTimeouts[deviceId]?.invalidate()
    }
  }

  // MARK: - Battery plugin

  func requestBattery(deviceId: String) {
    log("→ battery request to \(displayName(deviceId))")
    send(
      to: deviceId, packet: KDEPacket(type: KDEPacketType.batteryRequest, body: ["request": true]))
  }

  private func handleBattery(deviceId: String, body: [String: Any]) {
    let level = body.kdeInt("currentCharge") ?? -1
    let charging = body.kdeBool("isCharging") ?? false
    let threshold = body.kdeInt("thresholdEvent") ?? 0
    let previous = batteries[deviceId]
    batteries[deviceId] = BatteryState(
      level: level, charging: charging,
      low: threshold == 1, updated: Date())
    if previous?.level != level || previous?.charging != charging {
      log("Battery \(displayName(deviceId)): \(level)%\(charging ? " (charging)" : "")")
    }
    // Alert once per low episode (persisted, so restarts don't re-alert).
    let wasLow =
      batteryLowNotified[deviceId]
      ?? UserDefaults.standard.bool(forKey: "daiKonnect.batteryLow.\(deviceId)")
    let isLow = threshold == 1
    batteryLowNotified[deviceId] = isLow
    UserDefaults.standard.set(isLow, forKey: "daiKonnect.batteryLow.\(deviceId)")
    if isLow, !wasLow, level >= 0 {
      postUserNotification(
        title: "Low battery — \(displayName(deviceId))",
        body: "Battery is at \(level)%\(charging ? " (charging)" : ""). Plug it in!")
    }
  }

  // MARK: - Notification plugin

  /// For the notification delegate, which has no logger of its own.
  func logNotificationAction(_ message: String) {
    log(message)
  }

  /// Ask the phone for everything the UI shows, in one go — the single
  /// refresh control's whole job.
  func refreshAll(deviceId: String) {
    requestBattery(deviceId: deviceId)
    requestNotifications(deviceId: deviceId)
    requestConversations(deviceId: deviceId)
    requestPlayerList(deviceId: deviceId)
  }

  func requestNotifications(deviceId: String) {
    log("→ notification list request to \(displayName(deviceId))")
    send(
      to: deviceId,
      packet: KDEPacket(type: KDEPacketType.notificationRequest, body: ["request": true]))
  }

  func dismissPhoneNotification(deviceId: String, notifId: String) {
    notifications[deviceId]?.removeAll { $0.notifId == notifId }
    guard links[deviceId] != nil else {
      // Held until a link exists rather than dropped: the request is
      // still meant, and the phone will be back in a moment.
      var queued = pendingCancels[deviceId] ?? []
      if !queued.contains(notifId) {
        queued.append(notifId)
        if queued.count > 50 { queued.removeFirst() }
        pendingCancels[deviceId] = queued
      }
      log("Dismiss on phone: no link to \(displayName(deviceId)) yet — the cancel is queued")
      return
    }
    log("Dismiss on phone: asking \(displayName(deviceId)) to cancel \(notifId)")
    send(
      to: deviceId,
      packet: KDEPacket(type: KDEPacketType.notificationRequest, body: ["cancel": notifId]))
  }

  /// Send cancellations that were waiting for a link.
  private func flushPendingCancels(deviceId: String) {
    guard let queued = pendingCancels.removeValue(forKey: deviceId), !queued.isEmpty else { return }
    log("Sending \(queued.count) queued notification cancel(s) to \(displayName(deviceId))")
    for notifId in queued {
      send(
        to: deviceId,
        packet: KDEPacket(type: KDEPacketType.notificationRequest, body: ["cancel": notifId]))
    }
  }

  /// Dismiss every notification for a device — on the phone as well as
  /// locally. The phone's NotificationsPlugin handles
  /// `kdeconnect.notification.request` with a `cancel` field by dismissing
  /// that notification and dropping it from its tracked list, so a later
  /// refresh won't re-send it.
  func clearNotifications(deviceId: String) {
    let items = notifications[deviceId] ?? []
    guard !items.isEmpty else { return }
    for item in items {
      send(
        to: deviceId,
        packet: KDEPacket(
          type: KDEPacketType.notificationRequest,
          body: ["cancel": item.notifId]))
    }
    notifications[deviceId] = []
    log("Dismissed \(items.count) notification(s) on the phone and locally")
    statusMessage = "Dismissed \(items.count) notification(s)"
  }

  func replyToNotification(deviceId: String, requestReplyId: String, message: String) {
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.notificationReply,
        body: ["requestReplyId": requestReplyId, "message": message]))
  }

  private func handleNotification(deviceId: String, packet: KDEPacket) {
    let body = packet.body
    guard let notifId = body.kdeString("id") else { return }
    if body.kdeBool("isCancel") == true {
      notifications[deviceId]?.removeAll { $0.notifId == notifId }
      return
    }
    let silent = body.kdeBool("silent") ?? false
    let app = body.kdeString("appName") ?? "Phone"
    let title = body.kdeString("title") ?? ""
    let text = body.kdeString("text") ?? ""
    let ticker = body.kdeString("ticker") ?? ""
    let clearable = body.kdeBool("isClearable") ?? false
    let replyId = body.kdeString("requestReplyId")
    let actions = (body["actions"] as? [String]) ?? []
    var time = Date()
    if let msString = body.kdeString("time"), let ms = Double(msString) {
      time = Date(timeIntervalSince1970: ms / 1000)
    } else if let ms = body["time"] as? NSNumber {
      time = Date(timeIntervalSince1970: ms.doubleValue / 1000)
    }
    let item: PhoneNotification = {
      var fresh = PhoneNotification(
        deviceId: deviceId, notifId: notifId, appName: app,
        title: title, text: text, ticker: ticker, time: time,
        isClearable: clearable, requestReplyId: replyId, actions: actions)
      fresh.iconHash = body.kdeString("payloadHash")
      // Attach an already-cached icon synchronously so the row shows it
      // immediately, without depending on the async fetch below.
      if let hash = fresh.iconHash,
        let cached = cachedIconPath(hash: hash)
      {
        fresh.iconFilePath = cached
      }
      return fresh
    }()
    var list = notifications[deviceId] ?? []
    // Keep a previously fetched icon when the phone re-sends the same id.
    if var existing = list.first(where: { $0.notifId == notifId }) {
      var updated = item
      updated.iconFilePath = existing.iconFilePath
      existing = updated
      list.removeAll { $0.notifId == notifId }
      list.insert(existing, at: 0)
    } else {
      list.removeAll { $0.notifId == notifId }
      list.insert(item, at: 0)
    }
    if list.count > 200 { list = Array(list.prefix(200)) }
    notifications[deviceId] = list
    guard !silent else { return }
    // Notification icons arrive as a payload transfer. Fetches are
    // serialized (the phone refuses/aborts when many payload sockets are
    // opened at once) and remembered so the UI can retry later.
    guard let hash = body.kdeString("payloadHash") else {
      iconPayloadMissing += 1
      postPhoneNotification(deviceId: deviceId, notifId: notifId)
      return
    }
    if let port = packet.payloadPort,
      let size = packet.payloadSize, size > 0, size <= 1_000_000,
      let host = devices.first(where: { $0.deviceId == deviceId })?.host, !host.isEmpty
    {
      iconFetchInfo[hash] = (host, port, size)
    }
    if cachedIconPath(hash: hash) != nil || inFlightIconFetches.contains(hash) {
      postPhoneNotification(deviceId: deviceId, notifId: notifId)
      return
    }
    guard let info = iconFetchInfo[hash] else {
      postPhoneNotification(deviceId: deviceId, notifId: notifId)
      return
    }
    log("Icon for '\(app)': hash=\(hash.prefix(8))… port=\(info.port) size=\(info.size)")
    inFlightIconFetches.insert(hash)
    fetchIconSerial(hash: hash, info: info) { [weak self] path in
      guard let self else { return }
      self.inFlightIconFetches.remove(hash)
      if let path {
        self.iconsFetched += 1
        self.setNotificationIcon(deviceId: deviceId, notifId: notifId, path: path)
      } else {
        self.iconFetchFailed += 1
        self.log("Icon for '\(app)': FAILED")
      }
      self.postPhoneNotification(deviceId: deviceId, notifId: notifId)
    }
  }

  /// Run an icon download on a serial queue with a retry, then deliver the
  /// result on the main thread. Concurrent payload connections make the
  /// phone drop some, so serializing + retrying is what makes this reliable.
  private func fetchIconSerial(
    hash: String, info: (host: String, port: UInt16, size: Int),
    completion: @escaping (String?) -> Void
  ) {
    iconFetchQueue.async { [weak self] in
      guard let self else { return }
      var result: String?
      for attempt in 1...2 {
        if let path = self.fetchNotificationIcon(
          host: info.host, port: info.port,
          size: info.size, hash: hash)
        {
          result = path
          break
        }
        if attempt < 2 {
          self.log("Icon fetch: retrying \(hash.prefix(8))…")
          Thread.sleep(forTimeInterval: 0.5)
        }
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// Fetch a notification's icon on demand (used by the UI when a row has
  /// no icon yet). Safe to call from `.task` — it never mutates state
  /// during view rendering.
  func ensureIcon(for item: PhoneNotification) async {
    guard item.iconFilePath == nil, let hash = item.iconHash else { return }
    if let cached = cachedIconPath(hash: hash) {
      setNotificationIcon(deviceId: item.deviceId, notifId: item.notifId, path: cached)
      return
    }
    guard let info = iconFetchInfo[hash] else { return }
    let path: String? = await withCheckedContinuation { cont in
      fetchIconSerial(hash: hash, info: info) { cont.resume(returning: $0) }
    }
    if let path {
      iconsFetched += 1
      setNotificationIcon(deviceId: item.deviceId, notifId: item.notifId, path: path)
      log("Icon for '\(item.appName)': fetched on demand")
    } else {
      iconFetchFailed += 1
    }
  }

  private func setNotificationIcon(deviceId: String, notifId: String, path: String) {
    guard var list = notifications[deviceId],
      let idx = list.firstIndex(where: { $0.notifId == notifId })
    else { return }
    list[idx].iconFilePath = path
    notifications[deviceId] = list
    log("Icon set on notification model (notif \(notifId))")
  }

  private func postPhoneNotification(deviceId: String, notifId: String) {
    guard let item = notifications[deviceId]?.first(where: { $0.notifId == notifId }) else {
      return
    }
    // An excluded app still reaches the dashboard — the model was updated
    // before this runs — so only the macOS banner is skipped here. Matched
    // on the app name, which is all the notification packet carries.
    guard !NotificationSettings.excludedApps.contains(item.appName) else {
      log("macOS notification suppressed for '\(item.appName)' (excluded in Settings)")
      return
    }
    var attachment: URL?
    if let path = item.iconFilePath {
      let url = URL(fileURLWithPath: path)
      if let data = try? Data(contentsOf: url), Self.isDecodableImage(data) {
        attachment = url
      }
    }
    postUserNotification(
      title: "\(item.appName) — \(displayName(deviceId))",
      body: item.preview, attachmentURL: attachment,
      codeSource: [item.title, item.text, item.ticker].joined(separator: "\n"),
      deviceId: deviceId, notifId: notifId)
  }

  // MARK: - Notification icon payloads

  private static func iconCacheDir() -> URL {
    let dir = FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appendingPathComponent("daiKonnect/icons", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Path of a previously fetched icon for this hash, if any.
  ///
  /// Deterministic name lookup only — no directory scan. Scanning also
  /// matched the temporary files of in-progress atomic writes, which then
  /// failed to decode and got deleted, killing concurrent fetches (the
  /// "INVALID at display time: exists=false" storm).
  private func cachedIconPath(hash: String) -> String? {
    let dir = Self.iconCacheDir()
    for ext in ["png", "jpg", "gif"] {
      let url = dir.appendingPathComponent("\(hash).\(ext)")
      if let data = try? Data(contentsOf: url), Self.isDecodableImage(data) {
        return url.path
      }
    }
    return nil
  }

  /// Public lookup by hash for the row view's display-time fallback.
  /// Read-only: callers must not mutate state from view code.
  func iconPath(for hash: String) -> String? {
    cachedIconPath(hash: hash)
  }

  /// Validate that `data` is a COMPLETE, decodable image.
  ///
  /// ImageIO happily decodes a truncated PNG into a partial (blank-looking)
  /// image — the "white box" bug — and `CGImageSourceGetStatus` reports
  /// complete for any in-memory Data source, so it can't detect truncation
  /// either. The only reliable check is format-level completeness: a PNG
  /// must end with its IEND chunk, a JPEG with EOI, a GIF with its
  /// terminator.
  private static func isDecodableImage(_ data: Data) -> Bool {
    guard Self.isCompleteImageData(data) else { return false }
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
  }

  private static func isCompleteImageData(_ data: Data) -> Bool {
    let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    // PNG ends with: length 0, "IEND", CRC AE 42 60 82.
    let pngIEND: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
    if data.starts(with: pngSignature) {
      return data.count > pngIEND.count && data.suffix(pngIEND.count).elementsEqual(pngIEND)
    }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) {
      return data.count > 3 && data.suffix(2).elementsEqual([0xFF, 0xD9])
    }
    if data.starts(with: [0x47, 0x49, 0x46]) {
      return data.last == 0x3B
    }
    return false
  }

  /// Compose a phone icon onto a rounded tile so monochrome glyphs are
  /// visible: Android notification icons are often black (or white) with a
  /// transparent background, which vanishes against the window. The tile
  /// colour is picked from the glyph's own luminance, so both black and
  /// white icons stay legible.
  static func tileIcon(_ data: Data) -> Data? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }
    let size = 128
    let space = CGColorSpaceCreateDeviceRGB()
    guard
      let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let dark = averageLuminance(of: cg) < 0.5
    let bg: CGColor =
      dark
      ? CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)  // dark glyph → light tile
      : CGColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)  // light glyph → dark tile
    ctx.addPath(
      CGPath(
        roundedRect: rect, cornerWidth: CGFloat(size) * 0.22,
        cornerHeight: CGFloat(size) * 0.22, transform: nil))
    ctx.setFillColor(bg)
    ctx.fillPath()
    // Aspect-fit the icon inside the tile with a margin.
    let inset = CGFloat(size) * 0.16
    let inner = rect.insetBy(dx: inset, dy: inset)
    let iw = CGFloat(cg.width)
    let ih = CGFloat(cg.height)
    let scale = min(inner.width / iw, inner.height / ih)
    let drawRect = CGRect(
      x: inner.midX - iw * scale / 2,
      y: inner.midY - ih * scale / 2,
      width: iw * scale, height: ih * scale)
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: drawRect)
    guard let out = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
  }

  /// Average luminance of the icon's opaque pixels.
  private static func averageLuminance(of image: CGImage) -> Double {
    let n = 16
    var pixels = [UInt8](repeating: 0, count: n * n * 4)
    // The context draws into this buffer, so the buffer has to stay valid
    // for as long as the context exists — `&pixels` only guarantees that
    // for the length of the call itself.
    let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8,
          bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
      return true
    }
    guard drawn else { return 0 }

    var total = 0.0
    var count = 0.0
    for i in stride(from: 0, to: pixels.count, by: 4) {
      let a = Double(pixels[i + 3]) / 255.0
      guard a > 0.5 else { continue }
      let r = Double(pixels[i]) / 255.0
      let g = Double(pixels[i + 1]) / 255.0
      let b = Double(pixels[i + 2]) / 255.0
      total += 0.2126 * r + 0.7152 * g + 0.0722 * b
      count += 1
    }
    return count > 0 ? total / count : 0
  }

  private func clearIconCache() {
    iconDataLock.lock()
    iconDataByHash.removeAll()
    iconDataLock.unlock()
    let dir = Self.iconCacheDir()
    if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
      for f in files {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
      }
      if !files.isEmpty { log("Cleared \(files.count) cached icons") }
    }
  }

  /// Wipe icon cache + clear icon paths on all stored notifications so the
  /// next notification triggers a fresh fetch — and re-fetch icons for the
  /// notifications currently on screen.
  func reFetchNotificationIcons() {
    clearIconCache()
    var toRefetch: [PhoneNotification] = []
    for (deviceId, items) in notifications {
      var changed = false
      var list = items
      for i in list.indices where list[i].iconFilePath != nil {
        list[i].iconFilePath = nil
        changed = true
      }
      if changed { notifications[deviceId] = list }
      toRefetch.append(contentsOf: list.filter { $0.iconHash != nil })
    }
    statusMessage = "Icon cache cleared; re-fetching \(toRefetch.count) icons"
    for item in toRefetch {
      Task { [weak self] in await self?.ensureIcon(for: item) }
    }
  }

  /// Download a notification icon from the phone's payload port and cache
  /// it under ~/Library/Caches/daiKonnect/icons/<hash>.<ext>.
  /// Returns the cached file path, or nil on any failure. The bytes are
  /// verified to actually decode as an image before caching: some phones
  /// misreport the size, so a short exact-sized read is followed by an
  /// EOF drain when the first attempt doesn't decode.
  private func fetchNotificationIcon(host: String, port: UInt16, size: Int, hash: String) -> String?
  {
    if let cached = cachedIconPath(hash: hash) { return cached }
    let dir = Self.iconCacheDir()
    let fd = LanTransport.tcpConnectRetrying(host: host, port: port)
    guard fd >= 0 else {
      log(
        "Icon fetch: cannot reach \(host):\(port) — \(LanTransport.lastConnectFailure ?? "unknown")"
      )
      return nil
    }
    // Clearing waits for bytes: the socket opening proves nothing, since
    // a revoked permission still lets the connection be made.
    LanTransport.setTimeouts(fd: fd, seconds: 4)
    let link = KDELink(fd: fd, remoteHost: host, outbound: true, tlsServer: false)
    defer { link.close() }
    guard let identity = store.loadIdentity(),
      let cert = store.loadCertificateChain()?.first,
      link.startTLS(identity: identity, certificate: cert)
    else {
      log("Icon fetch: TLS failed")
      return nil
    }
    // The phone sometimes under-reports the payload size, so an exact-size
    // read can be truncated. Keep the head and append the remainder —
    // discarding the head was why icons never decoded.
    // (The notice clears on bytes read, further down, not on connecting.)
    var bytes = link.readEncryptedBytes(count: size, maxBytes: 1_000_000)
    if bytes == nil || !Self.isDecodableImage(bytes!) {
      let tail = link.readEncryptedBytesUntilClose(maxBytes: 1_000_000, deadlineSeconds: 2)
      if let head = bytes, let tail {
        bytes = head + tail
        log("Icon fetch: head \(head.count)B + tail \(tail.count)B = \(head.count + tail.count)B")
      } else if let tail {
        bytes = tail
      }
    }
    guard let bytes, Self.isDecodableImage(bytes) else {
      let data = bytes ?? Data()
      let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
      log("Icon fetch: \(data.count)B don't decode (head: \(hex))")
      // Keep the raw payload so it can be inspected.
      if !data.isEmpty {
        try? data.write(to: dir.appendingPathComponent("\(hash).bin"), options: .atomic)
        log("Icon fetch: saved raw payload to \(hash).bin")
      }
      return nil
    }
    // Compose onto a rounded tile so monochrome (black/white) glyphs stay
    // visible against the window background.
    let stored = Self.tileIcon(bytes) ?? bytes
    let url = dir.appendingPathComponent("\(hash).png")
    do {
      try stored.write(to: url, options: .atomic)
    } catch {
      log("Icon fetch: cache write failed: \(error.localizedDescription)")
      return nil
    }
    // Keep the bytes in memory so the UI can render even if the cache
    // file can't be read back later.
    storeIconData(stored, hash: hash)
    let exists = FileManager.default.fileExists(atPath: url.path)
    log("Icon cached (\(stored.count)B) at \(url.path) exists=\(exists)")
    // Bytes arrived over one of our own connections, so access works.
    DispatchQueue.main.async { [weak self] in self?.noteDialSuccess() }
    return url.path
  }

  // MARK: - SMS plugin

  func requestConversations(deviceId: String) {
    log("→ SMS list request to \(displayName(deviceId))")
    send(to: deviceId, packet: KDEPacket(type: KDEPacketType.smsRequestConversations, body: [:]))
  }

  func requestConversation(deviceId: String, threadId: UInt64) {
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.smsRequestConversation,
        body: ["threadID": Int(threadId)]))
  }

  func sendSMS(deviceId: String, addresses: [String], message: String) {
    let addrObjs = addresses.map { ["address": $0] }
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.smsRequest,
        body: [
          "addresses": addrObjs,
          "messageBody": message,
          "version": 2,
        ]))
    statusMessage = "Sending SMS…"
  }

  private func handleSmsMessages(deviceId: String, body: [String: Any]) {
    guard let raw = body["messages"] as? [[String: Any]] else { return }
    let parsed: [SmsMessageItem] = raw.compactMap { m in
      guard let id = m.kdeInt64("_id").map(UInt64.init) ?? (m["_id"] as? UInt64),
        let thread = (m.kdeInt64("thread_id").map(UInt64.init) ?? (m["thread_id"] as? UInt64))
      else { return nil }
      let addrObjs = (m["addresses"] as? [[String: Any]]) ?? []
      let addrs = addrObjs.compactMap { $0.kdeString("address") }
      let text = m.kdeString("body") ?? ""
      let dateMs = m.kdeInt64("date") ?? 0
      let typeNum = m.kdeInt("type") ?? 1
      let readNum = m.kdeInt("read") ?? 1
      return SmsMessageItem(
        id: UInt64(id), threadId: UInt64(thread),
        addresses: addrs, body: text,
        date: Date(timeIntervalSince1970: Double(dateMs) / 1000),
        incoming: typeNum == 1, read: readNum == 1)
    }
    guard !parsed.isEmpty else { return }
    var convos = Dictionary(
      uniqueKeysWithValues: (conversations[deviceId] ?? []).map { ($0.threadId, $0) })
    var touchedInbox = false
    for msg in parsed {
      if var convo = convos[msg.threadId] {
        convo.merge([msg])
        convos[msg.threadId] = convo
      } else {
        convos[msg.threadId] = SmsConversation(
          threadId: msg.threadId,
          participants: msg.addresses.isEmpty ? ["Unknown"] : msg.addresses,
          messages: [msg])
      }
      if msg.incoming { touchedInbox = true }
    }
    conversations[deviceId] = convos.values.sorted { $0.lastDate > $1.lastDate }
    // Notify only about messages newer than anything we've already shown,
    // so bulk re-syncs (and app restarts) don't re-alert for old texts.
    if touchedInbox, let newest = parsed.filter(\.incoming).max(by: { $0.date < $1.date }) {
      let lastShown = lastSmsNotifiedDate(deviceId: deviceId)
      if newest.date > lastShown {
        setLastSmsNotifiedDate(deviceId: deviceId, date: newest.date)
        let from = newest.addresses.first ?? "Unknown"
        postUserNotification(
          title: "SMS from \(from)", body: newest.body,
          codeSource: newest.body)
      }
    }
    statusMessage = "SMS updated"
  }

  private func lastSmsNotifiedDate(deviceId: String) -> Date {
    if let d = lastSmsNotifyDate[deviceId] { return d }
    let t = UserDefaults.standard.double(forKey: "daiKonnect.lastSmsNotify.\(deviceId)")
    let d = t > 0 ? Date(timeIntervalSince1970: t) : .distantPast
    lastSmsNotifyDate[deviceId] = d
    return d
  }

  private func setLastSmsNotifiedDate(deviceId: String, date: Date) {
    lastSmsNotifyDate[deviceId] = date
    UserDefaults.standard.set(
      date.timeIntervalSince1970, forKey: "daiKonnect.lastSmsNotify.\(deviceId)")
  }

  // MARK: - Media (MPRIS) plugin

  /// Ask the phone which media players it is running.
  func requestPlayerList(deviceId: String) {
    log("→ media player list request to \(displayName(deviceId))")
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.mprisRequest,
        body: ["requestPlayerList": true]))
  }

  /// Ask for the current track/volume of one player.
  func requestNowPlaying(deviceId: String, player: String) {
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.mprisRequest,
        body: [
          "player": player,
          "requestNowPlaying": true,
          "requestVolume": true,
        ]))
  }

  /// Transport control. `action` is one of Play, Pause, PlayPause, Stop,
  /// Next, Previous.
  func sendMediaAction(deviceId: String, player: String, action: String) {
    log("→ media \(action) on \(player)")
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.mprisRequest,
        body: ["player": player, "action": action]))
  }

  func setMediaVolume(deviceId: String, player: String, volume: Int) {
    let clamped = max(0, min(100, volume))
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.mprisRequest,
        body: ["player": player, "setVolume": clamped]))
  }

  /// Absolute seek, in milliseconds.
  func setMediaPosition(deviceId: String, player: String, positionMs: Int) {
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.mprisRequest,
        body: ["player": player, "SetPosition": positionMs]))
  }

  /// Relative seek, in milliseconds (positive = forward).
  func seekMedia(deviceId: String, player: String, offsetMs: Int) {
    // The protocol's Seek is in microseconds.
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.mprisRequest,
        body: ["player": player, "Seek": offsetMs * 1000]))
  }

  /// Ask the phone to send the album art as a payload.
  private func requestAlbumArt(deviceId: String, player: String, albumArtUrl: String) {
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.mprisRequest,
        body: ["player": player, "albumArtUrl": albumArtUrl]))
  }

  private func handleMpris(deviceId: String, packet: KDEPacket) {
    let body = packet.body

    // A player-list response.
    if let names = body["playerList"] as? [String] {
      let existing = Dictionary(
        uniqueKeysWithValues: (mediaPlayers[deviceId] ?? []).map { ($0.name, $0) })
      mediaPlayers[deviceId] = names.map { existing[$0] ?? MediaPlayer(name: $0) }
      log(
        "Media: \(names.count) player(s) on \(displayName(deviceId)): \(names.joined(separator: ", "))"
      )
      // Ask each for its state so the tab isn't blank on first open.
      for name in names { requestNowPlaying(deviceId: deviceId, player: name) }
      return
    }

    guard let name = body.kdeString("player") else { return }

    // Album art arrives as a payload on its own connection.
    if body.kdeBool("transferringAlbumArt") == true,
      let port = packet.payloadPort, let size = packet.payloadSize, size > 0
    {
      let artURL = body.kdeString("albumArtUrl")
      log("Media: album art payload for \(name) (\(size)B)")
      downloadAlbumArt(
        deviceId: deviceId, player: name, albumArtUrl: artURL, port: port, size: size)
      return
    }

    var list = mediaPlayers[deviceId] ?? []
    var player = list.first(where: { $0.name == name }) ?? MediaPlayer(name: name)
    let previousTitle = player.title
    let previousPlaying = player.isPlaying

    if let v = body.kdeString("title") { player.title = v }
    if let v = body.kdeString("artist") { player.artist = v }
    if let v = body.kdeString("album") { player.album = v }
    if let v = body.kdeBool("isPlaying") { player.isPlaying = v }
    if let v = body.kdeBool("canPlay") { player.canPlay = v }
    if let v = body.kdeBool("canPause") { player.canPause = v }
    if let v = body.kdeBool("canGoNext") { player.canGoNext = v }
    if let v = body.kdeBool("canGoPrevious") { player.canGoPrevious = v }
    if let v = body.kdeBool("canSeek") { player.canSeek = v }
    if let v = body.kdeInt("length") { player.lengthMs = v }
    if let v = body.kdeInt("pos") { player.positionMs = v }
    if let v = body.kdeInt("volume") { player.volume = v }

    if let artURL = body.kdeString("albumArtUrl"), artURL != player.albumArtUrl {
      player.albumArtUrl = artURL
      player.albumArtPath = cachedAlbumArtPath(for: artURL)
      if player.albumArtPath == nil {
        requestAlbumArt(deviceId: deviceId, player: name, albumArtUrl: artURL)
      }
    }

    player.updated = Date()
    if let idx = list.firstIndex(where: { $0.name == name }) {
      list[idx] = player
    } else {
      list.append(player)
    }
    mediaPlayers[deviceId] = list

    // Position updates are frequent; only log meaningful changes.
    if player.title != previousTitle || player.isPlaying != previousPlaying {
      log(
        "Media: \(name) — \(player.artist.isEmpty ? "" : player.artist + " / ")\(player.title) (\(player.isPlaying ? "playing" : "paused"))"
      )
    }
  }

  // MARK: Album art payloads

  private static func albumArtDir() -> URL {
    let dir = FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appendingPathComponent("daiKonnect/albumart", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Stable, filename-safe cache key for a remote album-art URL.
  private func albumArtCacheKey(_ url: String) -> String {
    SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func cachedAlbumArtPath(for url: String) -> String? {
    let file = Self.albumArtDir().appendingPathComponent("\(albumArtCacheKey(url)).png")
    guard let data = try? Data(contentsOf: file), Self.isDecodableImage(data) else { return nil }
    return file.path
  }

  private func downloadAlbumArt(
    deviceId: String, player: String,
    albumArtUrl: String?, port: UInt16, size: Int
  ) {
    guard let albumArtUrl, cachedAlbumArtPath(for: albumArtUrl) == nil else { return }
    guard let host = devices.first(where: { $0.deviceId == deviceId })?.host, !host.isEmpty else {
      return
    }
    let key = albumArtCacheKey(albumArtUrl)

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      guard
        let bytes = self.downloadPayload(
          deviceId: deviceId, host: host, port: port, size: size,
          maxBytes: 4_000_000,
          validate: Self.isDecodableImage)
      else {
        self.log("Media: album art download failed")
        return
      }
      let file = Self.albumArtDir().appendingPathComponent("\(key).png")
      do {
        try bytes.write(to: file, options: .atomic)
      } catch {
        self.log("Media: album art write failed: \(error.localizedDescription)")
        return
      }
      DispatchQueue.main.async {
        guard var list = self.mediaPlayers[deviceId],
          let idx = list.firstIndex(where: { $0.name == player })
        else { return }
        list[idx].albumArtPath = file.path
        self.mediaPlayers[deviceId] = list
        self.log("Media: album art cached for \(player) (\(bytes.count)B)")
      }
    }
  }

  /// Download a payload the phone offers on a short-lived TLS connection.
  /// `validate` lets the caller detect a short read (the phone sometimes
  /// mis-reports the size), in which case the rest of the stream is appended
  /// rather than discarded.
  private func downloadPayload(
    deviceId: String, host: String, port: UInt16, size: Int,
    maxBytes: Int,
    validate: (Data) -> Bool
  ) -> Data? {
    // Retried: the offer stands for ten seconds, and the phone is often
    // unreachable for a moment when the artwork is announced.
    let fd = LanTransport.tcpConnectRetrying(host: host, port: port)
    guard fd >= 0 else {
      log("Payload: cannot reach \(host):\(port) — \(LanTransport.lastConnectFailure ?? "unknown")")
      requestFreshAddress(after: "Album art fetch")
      noteDialFailure("Album art fetch", deviceId: deviceId)
      return nil
    }
    // Clearing waits for the payload itself, further down.
    LanTransport.setTimeouts(fd: fd, seconds: 4)
    let link = KDELink(fd: fd, remoteHost: host, outbound: true, tlsServer: false)
    defer { link.close() }
    guard let identity = store.loadIdentity(),
      let cert = store.loadCertificateChain()?.first,
      link.startTLS(identity: identity, certificate: cert)
    else {
      log("Payload: TLS failed (handshake \(link.lastHandshakeStatus().map(String.init) ?? "n/a"))")
      notePayloadHandshakeFailure("Album art TLS", deviceId: deviceId)
      return nil
    }
    let head = link.readEncryptedBytes(count: size, maxBytes: maxBytes)
    var fetched: Data?
    if let head, validate(head) {
      fetched = head
    } else {
      let tail = link.readEncryptedBytesUntilClose(maxBytes: maxBytes, deadlineSeconds: 2)
      if let head, let tail, !tail.isEmpty { fetched = head + tail } else { fetched = head ?? tail }
    }
    if fetched != nil {
      // The artwork arrived, so outgoing connections work.
      DispatchQueue.main.async { [weak self] in self?.noteDialSuccess() }
    }
    return fetched
  }

  // MARK: - Clipboard

  /// Watch the pasteboard. There is no notification for changes, so this is
  /// a poll; half a second is well below noticing, and cheap.
  func startClipboardWatch() {
    guard clipboardTimer == nil, !AppEnvironment.isPreview else { return }
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.pollClipboard()
    }
    RunLoop.main.add(timer, forMode: .common)
    clipboardTimer = timer
  }

  private func pollClipboard() {
    let pasteboard = NSPasteboard.general
    let changeCount = pasteboard.changeCount
    guard changeCount != lastClipboardChangeCount else { return }
    let firstLook = lastClipboardChangeCount < 0
    lastClipboardChangeCount = changeCount
    // Whatever was on the clipboard before we started is not a copy the
    // user just made.
    guard !firstLook, isRunning, ClipboardSettings.enabled else { return }
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
    guard text != lastClipboardContent else { return }

    lastClipboardContent = text
    let frontmost = NSWorkspace.shared.frontmostApplication
    lastClipboardSourceBundleID = frontmost?.bundleIdentifier

    // Concealed content is what password managers and password fields mark
    // so that clipboard utilities leave it alone. That is a better signal
    // than any list of apps, so it is always honoured.
    guard !Self.isConcealed(pasteboard) else {
      log(
        "Clipboard: not sending \(text.count) character(s) — marked concealed by the app that copied it"
      )
      return
    }
    if let source = lastClipboardSourceBundleID,
      ClipboardSettings.excludedApps.contains(source)
    {
      log(
        "Clipboard: not sending \(text.count) character(s) — \(frontmost?.localizedName ?? source) is excluded"
      )
      return
    }

    lastLocalClipboardChangeMs = Int64(Date().timeIntervalSince1970 * 1000)
    var sent = 0
    for device in devices where device.paired && links[device.deviceId] != nil {
      send(
        to: device.deviceId,
        packet: KDEPacket(type: KDEPacketType.clipboard, body: ["content": text]))
      sent += 1
    }
    log("Clipboard: sent \(text.count) character(s) to \(sent) device(s)")
  }

  /// Password managers and password fields tag the pasteboard this way.
  private static func isConcealed(_ pasteboard: NSPasteboard) -> Bool {
    let markers: Set<String> = [
      "org.nspasteboard.ConcealedType",
      "org.nspasteboard.TransientType",
      "com.agilebits.onepassword",
    ]
    let types = Set((pasteboard.types ?? []).map(\.rawValue))
    return !types.isDisjoint(with: markers)
  }

  private func handleClipboardPacket(deviceId: String, packet: KDEPacket) {
    guard ClipboardSettings.enabled, isRunning else { return }
    switch packet.type {
    case KDEPacketType.clipboard:
      applyRemoteClipboard(packet.body.kdeString("content"), from: deviceId)
    case KDEPacketType.clipboardConnect:
      // The connect packet carries a timestamp, and an older clipboard
      // must not overwrite a newer one. A timestamp of zero means the
      // peer does not know when it changed, and is ignored, as its own
      // implementation does.
      let timestamp = packet.body.kdeInt64("timestamp") ?? 0
      guard timestamp != 0 else {
        log("Clipboard: \(displayName(deviceId)) sent its clipboard without a timestamp — ignored")
        return
      }
      guard timestamp >= lastLocalClipboardChangeMs else {
        log("Clipboard: \(displayName(deviceId))'s clipboard is older than this Mac's — ignored")
        return
      }
      applyRemoteClipboard(packet.body.kdeString("content"), from: deviceId)
    default:
      break
    }
  }

  private func applyRemoteClipboard(_ content: String?, from deviceId: String) {
    guard let content, !content.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    guard content != pasteboard.string(forType: .string) else { return }
    pasteboard.clearContents()
    pasteboard.setString(content, forType: .string)
    // Recorded as ours so the poll does not send it straight back, and so
    // the change count is not mistaken for a local copy.
    lastClipboardContent = content
    lastClipboardChangeCount = pasteboard.changeCount
    log("Clipboard: set from \(displayName(deviceId)) (\(content.count) character(s))")
  }

  /// Offer this Mac's clipboard when a phone connects, so it can pull the
  /// latest if its own copy is older.
  private func sendClipboardOnConnect(deviceId: String) {
    guard ClipboardSettings.enabled, isRunning else { return }
    let pasteboard = NSPasteboard.general
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
    guard !Self.isConcealed(pasteboard) else { return }
    if let source = lastClipboardSourceBundleID,
      ClipboardSettings.excludedApps.contains(source)
    {
      return
    }
    send(
      to: deviceId,
      packet: KDEPacket(
        type: KDEPacketType.clipboardConnect,
        body: [
          "content": text,
          "timestamp": lastLocalClipboardChangeMs,
        ]))
    log("Clipboard: offered this Mac's clipboard to \(displayName(deviceId))")
  }

  // MARK: - Mac media (the phone drives this Mac)

  /// The phone asking about, or controlling, this Mac's media.
  private func handleMacMprisRequest(deviceId: String, body: [String: Any]) {
    guard AppCapabilities.allowRemoteMediaControl else { return }

    if body.kdeBool("requestPlayerList") == true {
      log("→ Mac media player list request from \(displayName(deviceId))")
      sendMacPlayerList(deviceId: deviceId)
      return
    }
    if let action = body.kdeString("action") {
      performMacMediaAction(action)
      return
    }
    // Absolute position, in milliseconds.
    if let position = body.kdeInt("SetPosition") {
      seekMac(toMilliseconds: position)
      return
    }
    // Relative offset, in microseconds (the phone's skip buttons).
    if let offset = body.kdeInt("Seek") {
      let current = lastMacState?.positionMs ?? 0
      seekMac(toMilliseconds: current + offset / 1000)
      return
    }
    if let artURL = body.kdeString("albumArtUrl") {
      log("→ Mac album art request from \(displayName(deviceId))")
      serveMacAlbumArt(
        deviceId: deviceId,
        player: body.kdeString("player") ?? "",
        albumArtUrl: artURL)
      return
    }
    if body.kdeBool("requestNowPlaying") == true || body.kdeBool("requestVolume") == true {
      refreshMacNowPlaying(force: true)
    }
    // setVolume / SetPosition / Seek have no MediaRemote equivalent, so the
    // state below reports volume as unsupported (-1) and canSeek as false.
  }

  private func sendMacPlayerList(deviceId: String) {
    guard MacMediaController.shared.isAvailable else {
      send(to: deviceId, packet: KDEPacket(type: KDEPacketType.mpris, body: ["playerList": []]))
      return
    }
    MacMediaController.shared.playerSnapshot { [weak self] name, _, _ in
      guard let self else { return }
      self.send(
        to: deviceId,
        packet: KDEPacket(
          type: KDEPacketType.mpris,
          body: [
            "playerList": [name],
            "supportAlbumArtPayload": true,
          ]))
      // Send the track straight away: the phone only asks for a player's
      // status when its media view is open, so relying on that request
      // leaves it blank until then.
      self.refreshMacNowPlaying(force: true)
    }
  }

  /// Seeks this Mac's player and tells the phone immediately, so its
  /// scrubber moves on release instead of waiting for the player to report
  /// the new position.
  private func seekMac(toMilliseconds ms: Int) {
    let limit = lastMacState?.durationMs ?? 0
    let clamped = max(0, limit > 0 ? min(ms, limit) : ms)
    MacMediaController.shared.seek(toMilliseconds: clamped)
    log("Mac media: seek to \(clamped)ms")
    reportOptimisticMacState(positionMs: clamped)
  }

  /// Serves the cover art the phone asked for. The packet announcing the
  /// port goes out only once the port is actually open.
  private func serveMacAlbumArt(deviceId: String, player: String, albumArtUrl: String) {
    guard let data = MacMediaController.artworkData(forFileURL: albumArtUrl) else {
      log("Media: no cached album art for \(albumArtUrl)")
      return
    }
    PayloadUploader.serve(data) { [weak self] port in
      DispatchQueue.main.async {
        guard let self else { return }
        self.send(
          to: deviceId,
          packet: KDEPacket(
            type: KDEPacketType.mpris,
            body: [
              "player": player,
              "albumArtUrl": albumArtUrl,
              "transferringAlbumArt": true,
            ],
            payloadSize: data.count,
            payloadPort: port))
        self.log(
          "Media: serving album art to \(self.displayName(deviceId)) (\(data.count)B on port \(port))"
        )
      }
    }
  }

  private func performMacMediaAction(_ action: String) {
    let command: MacMediaController.Command?
    // The playing state we expect afterwards; nil when it isn't knowable
    // (Next/Previous replace the track, and the query will say so).
    let expectedPlaying: Bool?
    switch action {
    case "Play":
      command = .play
      expectedPlaying = true
    case "Pause":
      command = .pause
      expectedPlaying = false
    case "PlayPause":
      command = .togglePlayPause
      expectedPlaying = lastMacState.map { !$0.isPlaying }
    case "Stop":
      command = .stop
      expectedPlaying = false
    case "Next":
      command = .nextTrack
      expectedPlaying = nil
    case "Previous":
      command = .previousTrack
      expectedPlaying = nil
    default:
      command = nil
      expectedPlaying = nil
    }
    guard let command else { return }
    MacMediaController.shared.send(command)
    log("Mac media: \(action)")
    if let expectedPlaying { reportOptimisticMacState(playing: expectedPlaying) }
    // Ask again once the player has caught up: confirms the optimistic
    // state above (or corrects it if the player refused) and picks up the
    // new track for Next/Previous. Long enough that the player has
    // published the change, so it can't revert the optimistic flip.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.refreshMacNowPlaying()
    }
  }

  /// Query this Mac's player and send its state to every paired, connected
  /// device — but only when something meaningful changed, so the phone's
  /// position interpolation isn't disturbed.
  private func refreshMacNowPlaying(force: Bool = false) {
    guard isRunning else { return }
    // Keep the chain alive while the feature is switched off, so turning
    // it back on resumes polling without a restart.
    guard AppCapabilities.allowRemoteMediaControl else {
      scheduleNextMacPoll(after: Self.macIdlePollInterval)
      return
    }
    let targets = devices.filter { links[$0.deviceId] != nil && paired[$0.deviceId] != nil }
    guard !targets.isEmpty else {
      scheduleNextMacPoll(after: Self.macIdlePollInterval)
      return
    }

    MacMediaController.shared.playerSnapshot { [weak self] name, nameChanged, state in
      guard let self else { return }

      let signature = self.macSignature(name: name, state: state)

      // The phone extrapolates position itself, so a stale position only
      // matters when it drifted (e.g. someone seeked on the Mac).
      var positionDrift = Int.max
      if let at = self.lastMacPositionSentAt {
        // Only a playing player is expected to have moved on since the last
        // send. Counting elapsed time while paused made every poll look like a
        // seek, so the same stale position was resent over and over.
        let elapsed =
          state?.isPlaying == true ? Int(Date().timeIntervalSince(at) * 1000) : 0
        let expected = self.lastMacPositionSentMs + elapsed
        positionDrift = abs(expected - (state?.positionMs ?? 0))
      }

      guard force || nameChanged || signature != self.lastMacSignature || positionDrift > 3000
      else {
        self.scheduleNextMacPoll(
          after: state == nil
            ? Self.macIdlePollInterval
            : Self.macActivePollInterval)
        return
      }
      self.lastMacSignature = signature
      self.lastMacPositionSentMs = state?.positionMs ?? 0
      self.lastMacPositionSentAt = Date()

      self.lastMacState = state
      self.lastMacPlayerName = name
      self.log(
        "Mac media: \(name) — \(state?.artist ?? "") / \(state?.title ?? "")"
          + " playing=\(state?.isPlaying ?? false) art=\(state?.albumArtFileURL != nil ? "yes" : "no")"
          + " seek=\((state?.durationMs ?? 0) > 0 ? "yes" : "no")"
          + " -> \(targets.count) device(s)")
      for device in targets {
        self.sendMacState(
          to: device.deviceId, name: name,
          nameChanged: nameChanged, state: state)
      }
      self.scheduleNextMacPoll(
        after: state == nil
          ? Self.macIdlePollInterval
          : Self.macActivePollInterval)
    }
  }

  /// Sends one player's state to a device. Also the single place that
  /// knows the wire shape, so the optimistic update below stays in step.
  private func sendMacState(
    to deviceId: String, name: String,
    nameChanged: Bool, state: MacNowPlaying?
  ) {
    if nameChanged {
      // The phone only applies state for names it already knows.
      send(
        to: deviceId,
        packet: KDEPacket(
          type: KDEPacketType.mpris,
          body: ["playerList": [name]]))
    }
    var body: [String: Any] = ["player": name]
    if let state {
      body["title"] = state.title
      body["artist"] = state.artist
      body["album"] = state.album
      body["isPlaying"] = state.isPlaying
      body["length"] = state.durationMs
      body["pos"] = state.positionMs
      body["canPlay"] = true
      body["canPause"] = true
      body["canGoNext"] = true
      body["canGoPrevious"] = true
      // A known length is the best available "seekable" signal; live
      // streams report none. The phone shows its scrubber only for
      // players it believes can seek.
      body["canSeek"] = state.durationMs > 0
    } else {
      body["isPlaying"] = false
    }
    // -1 means "volume control unsupported", which makes the phone hide
    // its volume slider rather than show a dead one.
    body["volume"] = -1
    // Always sent, empty when there is no art: the phone keeps the previous
    // URL when the field is absent, which leaves a stale cover behind. Its
    // presence (and a `file://` value) is also what makes the phone ask us
    // for the image.
    body["albumArtUrl"] = state?.albumArtFileURL ?? ""
    send(to: deviceId, packet: KDEPacket(type: KDEPacketType.mpris, body: body))
  }

  /// Reports the playing state a transport command is expected to produce,
  /// so the phone's button flips on the tap instead of up to a poll later.
  /// The query that follows confirms it (or corrects it if the player
  /// refused).
  private func reportOptimisticMacState(playing: Bool? = nil, positionMs: Int? = nil) {
    guard var state = lastMacState else { return }
    if let playing { state.isPlaying = playing }
    if let positionMs { state.positionMs = positionMs }
    lastMacState = state
    lastMacSignature = macSignature(name: lastMacPlayerName, state: state)
    lastMacPositionSentMs = state.positionMs
    lastMacPositionSentAt = Date()
    for device in devices
    where links[device.deviceId] != nil && paired[device.deviceId] != nil {
      sendMacState(
        to: device.deviceId, name: lastMacPlayerName,
        nameChanged: false, state: state)
    }
  }

  private func macSignature(name: String, state: MacNowPlaying?) -> String {
    [
      name,
      state?.title ?? "", state?.artist ?? "", state?.album ?? "",
      state.map { "\($0.isPlaying)" } ?? "",
      state.map { "\($0.durationMs)" } ?? "",
    ].joined(separator: "\u{1}")
  }

  /// How often to ask the Mac what is playing. The query spawns an
  /// osascript process, so it runs briskly while something is playing and
  /// backs off when there is nothing to report.
  private static let macActivePollInterval: TimeInterval = 20
  private static let macIdlePollInterval: TimeInterval = 30

  /// Queues the next poll. Cancels any pending one first, so a forced
  /// refresh (the phone asking) doesn't leave a poll scheduled twice.
  private func scheduleNextMacPoll(after delay: TimeInterval) {
    macPollWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.macPollWorkItem = nil
      self?.refreshMacNowPlaying()
    }
    macPollWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  // MARK: - Find-my-phone (ring) + ping + telephony

  /// Sends the ring request. Per convention, sending it a second time cancels the ringing.
  func toggleRing(deviceId: String) {
    if ringingDevices.contains(deviceId) {
      send(to: deviceId, packet: KDEPacket(type: KDEPacketType.findMyPhoneRequest, body: [:]))
      ringingDevices.remove(deviceId)
      statusMessage = "Ring cancelled"
    } else {
      send(to: deviceId, packet: KDEPacket(type: KDEPacketType.findMyPhoneRequest, body: [:]))
      ringingDevices.insert(deviceId)
      statusMessage = "Ringing \(displayName(deviceId))… tap again to stop"
    }
  }

  func sendPing(deviceId: String, message: String = "Hello from daiKonnect!") {
    send(to: deviceId, packet: KDEPacket(type: KDEPacketType.ping, body: ["message": message]))
  }

  func muteCall(deviceId: String) {
    // Telephony mute request (sent while the phone is ringing).
    send(to: deviceId, packet: KDEPacket(type: "kdeconnect.telephony.request_mute", body: [:]))
  }

  private func handleTelephony(deviceId: String, body: [String: Any]) {
    let event = body.kdeString("event") ?? ""
    let contact = body.kdeString("contactName") ?? ""
    let number = body.kdeString("phoneNumber") ?? ""
    let who = contact.isEmpty ? number : "\(contact) (\(number))"
    switch event {
    case "ringing":
      lastCallEvent[deviceId] = "Incoming call: \(who)"
      postUserNotification(title: "Incoming call — \(displayName(deviceId))", body: who)
    case "talking":
      lastCallEvent[deviceId] = "In call: \(who)"
    case "missedCall":
      lastCallEvent[deviceId] = "Missed call: \(who)"
      postUserNotification(title: "Missed call — \(displayName(deviceId))", body: who)
    case "sms":
      // Incoming-SMS event; the message list itself arrives via sms.messages.
      requestConversations(deviceId: deviceId)
    default:
      if !event.isEmpty { lastCallEvent[deviceId] = "\(event): \(who)" }
    }
  }

  // MARK: - macOS user notifications

  /// Human-readable authorization state for the Diagnostics panel. Also
  /// called when the app becomes active: permission can be changed in System
  /// Settings while daiKonnect runs, and macOS does not tell us, so without
  /// this the notice would still claim notifications are off after they have
  /// been turned on.
  func refreshNotificationAuth() {
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      let text: String
      let state: NotificationPermission
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        text = "allowed"
        state = .allowed
      case .denied:
        text = "denied — enable in System Settings → Notifications"
        state = .denied
      case .notDetermined:
        text = "not asked yet"
        state = .notDetermined
      @unknown default:
        text = "unknown"
        state = .unknown
      }
      DispatchQueue.main.async {
        guard let self else { return }
        let previous = self.notificationPermission
        self.notificationAuthStatus = text
        self.notificationPermission = state
        if previous != .unknown, previous != state {
          self.log("Notification permission is now \(state.rawValue)")
        }
      }
    }
  }

  /// Ask for notification permission if it hasn't been decided yet.
  ///
  /// macOS only ever shows the prompt once: if permission was refused, there
  /// is nothing to ask, so the app says so and offers the Settings pane
  /// instead of silently dropping every phone alert.
  func ensureNotificationPermission() {
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self else { return }
        switch settings.authorizationStatus {
        case .notDetermined:
          self.log("Asking for notification permission")
          self.requestNotificationPermission()
        case .denied:
          self.log(
            "Notification permission is off — phone alerts cannot be shown until it is enabled in System Settings"
          )
          self.notificationAuthStatus = "denied — enable in System Settings → Notifications"
          self.notificationPermission = .denied
        default:
          self.refreshNotificationAuth()
        }
      }
    }
  }

  /// Opens System Settings at daiKonnect's notification pane — the only way
  /// to restore permission once it has been refused.
  func openNotificationSettings() {
    let candidates = [
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
      "x-apple.systempreferences:com.apple.preference.notifications",
    ]
    for candidate in candidates {
      if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
    }
  }

  /// Ask the user for notification permission (called from the Diagnostics
  /// panel; otherwise permission is requested lazily on the first event).
  func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      [weak self] _, _ in
      self?.refreshNotificationAuth()
    }
  }

  /// Post a test notification to verify the macOS path end to end.
  func sendTestNotification() {
    postUserNotification(title: "\(AppMeta.AppName) test", body: "macOS notifications are working.")
  }

  /// `codeSource` is the message text to look for a one-time code in; it is
  /// separate from the displayed body so a sender's phone number can't be
  /// mistaken for one.
  /// `deviceId` and `notifId` let the banner offer a button that dismisses
  /// the notification on the phone, and identify what to dismiss.
  private func postUserNotification(
    title: String, body: String,
    attachmentURL: URL? = nil, codeSource: String? = nil,
    deviceId: String? = nil, notifId: String? = nil
  ) {
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      switch settings.authorizationStatus {
      case .notDetermined:
        // Ask in context, only when there is something to show.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
          [weak self] granted, _ in
          self?.refreshNotificationAuth()
          if granted {
            self?.deliverUserNotification(
              title: title, body: body,
              attachmentURL: attachmentURL,
              codeSource: codeSource,
              deviceId: deviceId, notifId: notifId)
          }
        }
      case .authorized, .provisional, .ephemeral:
        self?.deliverUserNotification(
          title: title, body: body,
          attachmentURL: attachmentURL,
          codeSource: codeSource,
          deviceId: deviceId, notifId: notifId)
      default:
        self?.log("macOS notification suppressed (not allowed): \(title)")
      }
    }
  }

  private func deliverUserNotification(
    title: String, body: String,
    attachmentURL: URL? = nil,
    codeSource: String? = nil,
    deviceId: String? = nil, notifId: String? = nil
  ) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body.isEmpty ? "(no content)" : body
    content.sound = .default
    // A phone notification gets a "Dismiss on phone" button; the "Copy
    // <code>" button appears when the message contains a number that looks
    // like a one-time code.
    let code = OTPCodeFinder.find(in: codeSource ?? body)
    let dismissible = deviceId != nil && notifId != nil
    if dismissible || code != nil {
      content.categoryIdentifier = NotificationCategory.register(
        code: code, dismissible: dismissible)
    }
    if let deviceId, let notifId {
      content.userInfo = [
        NotificationCategory.deviceKey: deviceId,
        NotificationCategory.notifIdKey: notifId,
      ]
    }
    if let url = attachmentURL,
      let attachment = try? UNNotificationAttachment(identifier: "icon", url: url)
    {
      content.attachments = [attachment]
    }
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req) { [weak self] error in
      if let error {
        self?.log("macOS notification failed: \(error.localizedDescription)")
      } else {
        let category = content.categoryIdentifier
        let buttons = category.isEmpty ? 0 : NotificationCategory.actionCount(for: category)
        self?.log(
          "macOS notification shown: \(title) [category: \(category.isEmpty ? "none" : category), buttons: \(buttons)]"
        )
      }
    }
  }
}
