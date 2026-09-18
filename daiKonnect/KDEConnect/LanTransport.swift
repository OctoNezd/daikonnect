import Foundation
import Security
import Darwin

// MARK: - Constants

let KDE_UDP_PORT: UInt16 = 1716
let KDE_TCP_PORT_MIN: UInt16 = 1716
let KDE_TCP_PORT_MAX: UInt16 = 1764
let KDE_MAX_PACKET_BYTES = 2_000_000

// MARK: - KDELink: one TCP connection to a peer (plaintext -> TLS upgrade)

/// A single LAN link to a KDE Connect peer.
///
/// Lifecycle (mirrors kdeconnect-kde LanLinkProvider):
///  1. TCP connect (outbound) or accept (inbound) in plaintext.
///  2. Outbound side sends its plaintext identity; inbound side reads it.
///  3. Both sides upgrade the SAME socket to TLS — the TCP initiator acts as
///     the TLS *server* and the acceptor acts as the TLS *client* (reversed roles).
///  4. Both sides exchange identities again over the encrypted channel.
final class KDELink: @unchecked Sendable {
    let remoteHost: String
    let directionOutbound: Bool
    /// TLS role. Defaults to the KDE Connect convention (TCP initiator is the
    /// TLS server), but payload-transfer connections always use TLS-client
    /// mode regardless of who dialed (mirrors GSConnect's download path).
    private let tlsServer: Bool
    private let fd: Int32
    /// Strong reference: a call in flight keeps the session alive, so
    /// teardown can never free it underneath a read or write.
    private var tls: SecureTransportSession?
    private var tlsActive = false
    /// Guards against closing the descriptor twice. `close()` runs on the way
    /// out of every link and `deinit` runs after it, and a second close() of a
    /// recycled number takes down an unrelated socket.
    private var fdClosed = false
    /// Serializes concurrent WRITES (SecureTransport needs one direction at a
    /// time). Reads are single-threaded by construction (one pump thread per
    /// link), and read/write concurrency across directions is safe — but
    /// teardown must never run while either is in flight (see close()).
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closedFlag = false
    /// Peer fingerprint captured on the handshake thread; reading it needs no
    /// TLS calls, so it is safe from any thread at any time.
    private var cachedPeerFP: String?
    /// DER of the same certificate, kept so the pairing verification key can
    /// be computed later without another TLS call.
    private var cachedPeerCertDER: Data?

    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closedFlag
    }

    /// SHA-256 fingerprint of the peer certificate (nil until the handshake
    /// completes, and always nil on outbound links where the phone presents
    /// no certificate — by design, see startTLS).
    func peerFingerprint() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedPeerFP
    }

    /// Why the last `readEncryptedLine` ended, so a dropped link says whether
    /// the phone closed it or TLS failed. Written and read on the pump thread.
    private(set) var lastReadFailure: String?

    /// Status from the last TLS handshake attempt, for diagnostics.
    func lastHandshakeStatus() -> OSStatus? {
        stateLock.lock(); defer { stateLock.unlock() }
        return tls?.lastHandshakeStatus
    }

    /// DER of the peer certificate, or nil where no certificate was presented.
    func peerCertificateDER() -> Data? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedPeerCertDER
    }

    private func checkOpen() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !closedFlag
    }

    init(fd: Int32, remoteHost: String, outbound: Bool, tlsServer: Bool? = nil) {
        self.fd = fd
        self.remoteHost = remoteHost
        self.directionOutbound = outbound
        self.tlsServer = tlsServer ?? outbound
        LanTransport.setTimeouts(fd: fd, seconds: 20)
    }

    deinit {
        // Defensive only: close() normally ran first, in which case there is
        // nothing left to do here.
        stateLock.lock()
        let alreadyClosed = fdClosed
        fdClosed = true
        stateLock.unlock()
        guard !alreadyClosed else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    func close() {
        stateLock.lock()
        guard !closedFlag else { stateLock.unlock(); return }
        closedFlag = true
        fdClosed = true
        let session = tls
        tls = nil
        tlsActive = false
        stateLock.unlock()
        // Unblock any in-flight read, then mark the session closed. It is
        // released by ARC once the last call holding it returns, so no
        // grace period is needed.
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        if let session { SecureTransportShim.close(session) }
    }

    // MARK: plaintext framing

    func sendPlaintext(_ data: Data) -> Bool {
        guard checkOpen() else { return false }
        writeLock.lock(); defer { writeLock.unlock() }
        guard checkOpen() else { return false }
        return LanTransport.sendAll(fd: fd, data: data)
    }

    func readPlaintextLine() -> Data? {
        guard checkOpen() else { return nil }
        return LanTransport.readLine(fd: fd, maxBytes: KDE_MAX_PACKET_BYTES)
    }

    // MARK: TLS upgrade (reversed roles: initiator = server)

    /// Upgrade the connected socket to TLS. Outbound links become the TLS server.
    ///
    /// Both sides present their certificate (the phone presents its own as the
    /// TLS server certificate whenever IT initiated the TCP connection).
    /// Verification is done manually later via certificate fingerprint pinning.
    /// We deliberately do NOT request TLS client certificates: SecureTransport's
    /// server-side client authentication fails with errSSLXCertChainInvalid for
    /// self-signed certs on modern macOS, and the phone's certificate is
    /// reliably captured on inbound links (see KDEConnectService), where the
    /// phone acts as the TLS server.
    func startTLS(identity: SecIdentity, certificate: SecCertificate) -> Bool {
        guard checkOpen() else { return false }
        guard let session = SecureTransportShim.makeSession(fd: fd, isServer: tlsServer,
                                                            identity: identity,
                                                            certificate: certificate) else { return false }

        guard SecureTransportShim.handshake(session) else {
            SecureTransportShim.close(session)
            return false
        }

        stateLock.lock()
        // If close() ran during the handshake, drop everything instead of
        // installing a link on a dead socket.
        guard !closedFlag else {
            stateLock.unlock()
            SecureTransportShim.close(session)
            return false
        }
        tls = session
        tlsActive = true
        let peerCertificate = SecureTransportShim.copyPeerCertificate(session)
        cachedPeerFP = peerCertificate.map { IdentityStore.fingerprint(of: $0) }
        cachedPeerCertDER = peerCertificate.map { SecCertificateCopyData($0) as Data }
        stateLock.unlock()
        return true
    }

    // MARK: encrypted framing (newline-delimited JSON)

    func sendPacket(_ packet: KDEPacket) -> Bool {
        guard let data = packet.encode() else { return false }
        return sendEncrypted(data)
    }

    func sendEncrypted(_ data: Data) -> Bool {
        guard checkOpen() else { return false }
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock()
        guard !closedFlag, let session = tls, tlsActive else { stateLock.unlock(); return false }
        stateLock.unlock()
        var sent = 0
        return data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Bool in
            guard let base = ptr.baseAddress else { return false }
            while sent < data.count {
                let written = SecureTransportShim.write(session, from: base.advanced(by: sent), length: data.count - sent)
                if written < 0 { return false }
                if written > 0 { sent += Int(written) } else { Thread.sleep(forTimeInterval: 0.01) }
            }
            return true
        }
    }

    func readEncryptedLine() -> Data? {
        stateLock.lock()
        guard !closedFlag, let session = tls, tlsActive else { stateLock.unlock(); return nil }
        stateLock.unlock()
        var line = Data()
        var byte: UInt8 = 0
        lastReadFailure = nil
        while line.count < KDE_MAX_PACKET_BYTES {
            let got = withUnsafeMutableBytes(of: &byte) { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return SecureTransportShim.read(session, into: base, length: 1)
            }
            if got == 1 {
                if byte == 0x0A { return line }
                line.append(byte)
                continue
            }
            if got == 0 {
                lastReadFailure = "peer closed the connection"
                return nil
            }
            if got == -1 {
                // Both halves matter: an SSL-level failure with a clean socket
                // means the stack rejected something, while a socket error
                // means the connection itself went away.
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                let state: String
                switch session.lastReadState {
                case .idle: state = "idle"
                case .handshake: state = "handshaking"
                case .connected: state = "connected"
                case .closed: state = "closed"
                case .aborted: state = "aborted"
                @unknown default: state = "state \(session.lastReadState.rawValue)"
                }
                lastReadFailure = "TLS read failed (SSLRead \(session.lastReadStatus), session \(state), socket error \(socketError))"
                return nil
            }
            Thread.sleep(forTimeInterval: 0.005) // would block
        }
        lastReadFailure = "packet exceeded \(KDE_MAX_PACKET_BYTES) bytes"
        return nil
    }

    /// Read exactly `count` raw bytes (payload transfers have no framing).
    /// Returns whatever was received when the peer closes early or the
    /// deadline passes — returning nil there discarded the head of a payload
    /// whose size the phone over-reported, which broke icon decoding.
    func readEncryptedBytes(count: Int, maxBytes: Int = 4_000_000, deadlineSeconds: TimeInterval = 6) -> Data? {
        stateLock.lock()
        guard !closedFlag, let session = tls, tlsActive else { stateLock.unlock(); return nil }
        stateLock.unlock()
        guard count > 0, count <= maxBytes else { return nil }
        var out = Data()
        out.reserveCapacity(count)
        var tmp = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while out.count < count {
            if Date() >= deadline { break }
            let want = min(tmp.count, count - out.count)
            let got = tmp.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return SecureTransportShim.read(session, into: base, length: want)
            }
            if got > 0 {
                out.append(tmp, count: got)
            } else if got == -2 {
                Thread.sleep(forTimeInterval: 0.005)
            } else {
                break // EOF or error
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Read until the peer closes (or cap/timeout). Used to recover payloads
    /// whose declared size was short. Bounded by deadline so an idle-open
    /// connection can't stall it forever.
    func readEncryptedBytesUntilClose(maxBytes: Int = 4_000_000, deadlineSeconds: TimeInterval = 5) -> Data? {
        stateLock.lock()
        guard !closedFlag, let session = tls, tlsActive else { stateLock.unlock(); return nil }
        stateLock.unlock()
        var out = Data()
        var tmp = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while out.count < maxBytes, Date() < deadline {
            let want = min(tmp.count, maxBytes - out.count)
            let got = tmp.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return SecureTransportShim.read(session, into: base, length: want)
            }
            if got > 0 {
                out.append(tmp, count: got)
            } else if got == -2 {
                Thread.sleep(forTimeInterval: 0.005)
            } else {
                break // EOF or error
            }
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Raw socket helpers

enum LanTransport {
    static func setTimeouts(fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        withUnsafePointer(to: &tv) { ptr in
            let p = UnsafeRawPointer(ptr)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
        }
        var one: Int32 = 1
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // Writing to a socket the peer has already closed raises SIGPIPE, whose
        // default action kills the process. Every socket KDE Connect uses is
        // torn down underneath its writer at some point, so opt out globally.
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func sendAll(fd: Int32, data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Bool in
            guard let base = ptr.baseAddress else { return false }
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    static func readLine(fd: Int32, maxBytes: Int) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < maxBytes {
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n == 1 {
                if byte == 0x0A { return line }
                line.append(byte)
            } else if n == 0 {
                return nil
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }
        return nil
    }

    static func makeTCPListenSocket(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    /// Blocking connect with a timeout (non-blocking connect + select).
    /// Describes why the last `tcpConnect` on this thread failed. Thread-local
    /// because connects run on several queues at once, and a shared static
    /// would report another attempt's error.
    private static let connectFailureKey = "daiKonnect.lastConnectFailure"
    static var lastConnectFailure: String? {
        get { Thread.current.threadDictionary[connectFailureKey] as? String }
        set { Thread.current.threadDictionary[connectFailureKey] = newValue }
    }

    /// The errno behind the last failure on this thread, so a caller can tell
    /// a refused port (nothing listening — pointless to retry) from an
    /// unreachable host (the phone is asleep — worth waiting for).
    private static let connectErrnoKey = "daiKonnect.lastConnectErrno"
    static var lastConnectErrno: Int32? {
        get { Thread.current.threadDictionary[connectErrnoKey] as? Int32 }
        set { Thread.current.threadDictionary[connectErrnoKey] = newValue }
    }

    private static func describeErrno(_ code: Int32) -> String {
        "\(code) \(String(cString: strerror(code)))"
    }

    static func tcpConnect(host: String, port: UInt16, timeoutSeconds: Int = 6) -> Int32 {
        lastConnectFailure = nil
        lastConnectErrno = nil
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastConnectFailure = "socket() failed: \(describeErrno(errno))"
            lastConnectErrno = errno
            return -1
        }
        // Non-blocking for the connect phase.
        var flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let rc: Int32 = host.withCString { cstr -> Int32 in
            var bin = in_addr()
            if inet_pton(AF_INET, cstr, &bin) == 1 {
                addr.sin_addr = bin
                return withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            // Fallback to DNS.
            var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var info: UnsafeMutablePointer<addrinfo>?
            let portStr = String(port)
            guard getaddrinfo(cstr, portStr, &hints, &info) == 0, let first = info else {
                Darwin.close(fd)
                lastConnectFailure = "cannot resolve \(cstr)"
                return -1
            }
            defer { freeaddrinfo(info) }
            return connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        }
        if rc == 0 {
            flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            return fd
        }
        if errno != EINPROGRESS {
            lastConnectFailure = "connect() failed: \(describeErrno(errno))"
            lastConnectErrno = errno
            Darwin.close(fd)
            return -1
        }
        let ready = waitWritable(fd: fd, timeoutSeconds: timeoutSeconds)
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        guard ready, soError == 0 else {
            lastConnectFailure = ready
                ? "connect() refused: \(describeErrno(soError))"
                : "connect() timed out after \(timeoutSeconds)s"
            lastConnectErrno = ready ? soError : ETIMEDOUT
            Darwin.close(fd)
            return -1
        }
        flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return fd
    }

    /// Connect, retrying until the deadline.
    ///
    /// A phone's Wi-Fi sleeps between packets — doze, power saving — and while
    /// it sleeps it does not even answer ARP, so a dial fails outright with
    /// EHOSTUNREACH though the phone can still reach us. A payload socket is
    /// offered for ten seconds, so most of that window is worth spending
    /// waiting for the phone to wake rather than losing the transfer.
    ///
    /// A refused port stops it early: that means nothing is listening, which
    /// no amount of waiting will change.
    static func tcpConnectRetrying(host: String, port: UInt16,
                                   deadlineSeconds: TimeInterval = 8,
                                   attemptTimeoutSeconds: Int = 2,
                                   retryDelay: TimeInterval = 0.5) -> Int32 {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        var fd = Int32(-1)
        repeat {
            fd = tcpConnect(host: host, port: port, timeoutSeconds: attemptTimeoutSeconds)
            if fd >= 0 { return fd }
            if lastConnectErrno == ECONNREFUSED { return fd }
            Thread.sleep(forTimeInterval: retryDelay)
        } while Date() < deadline
        return fd
    }

    static func peerIP(fd: Int32) -> String {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }) == 0 else { return "" }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var a = addr.sin_addr
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    // MARK: UDP

    static func makeUDPListenSocket(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        #if os(macOS)
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    static func makeUDPBroadcastSocket() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func udpSend(fd: Int32, data: Data, host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        host.withCString { cstr in
            _ = inet_pton(AF_INET, cstr, &addr.sin_addr)
        }
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, base, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// All IPv4 broadcast addresses (per-interface directed broadcast + global).
    static func broadcastAddresses() -> [String] {
        var result = ["255.255.255.255"]
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let first = ifaddrs else { return result }
        defer { freeifaddrs(ifaddrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let maskSa = cur.pointee.ifa_netmask else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = maskSa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bcast = ip | ~mask
            var out = in_addr(s_addr: bcast)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &out, &buf, socklen_t(INET_ADDRSTRLEN))
            let str = String(cString: buf)
            if !result.contains(str) { result.append(str) }
        }
        return result
    }

    // MARK: fd_set helpers (FD_SET macros aren't imported into Swift)

    /// Runs `select()` waiting for `fd` to become readable (accept timeout).
    static func waitReadable(fd: Int32, timeoutSeconds: Int) -> Bool {
        let setPtr = UnsafeMutablePointer<fd_set>.allocate(capacity: 1)
        defer { setPtr.deallocate() }
        memset(UnsafeMutableRawPointer(setPtr), 0, MemoryLayout<fd_set>.size)
        UnsafeMutableRawPointer(setPtr)
            .assumingMemoryBound(to: Int32.self)[Int(fd) / 32] |= Int32(1 << (Int(fd) % 32))
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let ready = select(fd + 1, setPtr, nil, nil, &tv)
        return ready > 0
    }

    /// Runs `select()` waiting for `fd` to become writable (connect timeout).
    static func waitWritable(fd: Int32, timeoutSeconds: Int) -> Bool {
        let setPtr = UnsafeMutablePointer<fd_set>.allocate(capacity: 1)
        defer { setPtr.deallocate() }
        memset(UnsafeMutableRawPointer(setPtr), 0, MemoryLayout<fd_set>.size)
        UnsafeMutableRawPointer(setPtr).assumingMemoryBound(to: Int32.self)[Int(fd) / 32] |= Int32(1 << (Int(fd) % 32))
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let ready = select(fd + 1, nil, setPtr, nil, &tv)
        return ready > 0
    }
}
