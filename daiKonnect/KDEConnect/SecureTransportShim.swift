import Foundation
import Security
import Darwin

/// One SecureTransport session over a connected socket.
///
/// This is a **class** on purpose. SecureTransport calls back into us while a
/// read or write is in flight, and those callbacks look the session up through
/// the connection reference. If the session could be freed while a call is
/// running, that lookup would touch freed memory — which shows up as
/// `malloc: pointer being freed was not allocated`. Holding a Swift reference
/// for the duration of every call (see KDELink) makes that impossible, and
/// `deinit` can then safely close the context because a reference is only
/// dropped once the call that held it has returned.
final class SecureTransportSession {
    fileprivate let fd: Int32
    fileprivate var context: SSLContext?
    /// Set once the link is torn down, so later calls bail out.
    fileprivate var isClosed = false
    fileprivate let lock = NSLock()
    /// Serializes the calls into SecureTransport.
    ///
    /// An SSLContext is not thread-safe, and a read and a write in flight on
    /// the same context is not either: Security services the outgoing queue
    /// inside `SSLRead` as well, so the two threads free the same queue entry
    /// and the process dies later with `malloc: pointer being freed was not
    /// allocated` inside `SSLRecordServiceWriteQueueInternal`. One link reads
    /// on its pump thread while the rest of the app writes, so this is the
    /// normal case, not an edge one. Held only for calls that return promptly,
    /// because the I/O functions never block (see the MSG_DONTWAIT below).
    fileprivate let ioLock = NSLock()

    fileprivate init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        // Deliberately no SSLClose here.
        //
        // SSLClose writes a close_notify through the I/O functions, and those
        // look this session up from the connection pointer with
        // `takeUnretainedValue()` — a retain/release cycle against an object
        // that is already deallocating. With a reference count of zero the
        // release half lands on memory that this deinit is about to hand back,
        // which corrupts the heap and surfaces later as
        // `malloc: pointer being freed was not allocated`.
        //
        // Letting ARC release the context frees it without re-entering us, and
        // the socket is shut down by KDELink.close() before the last reference
        // goes, so the peer still sees the connection close.
    }

    /// The last status `SSLRead` returned, and the session state at the time,
    /// for diagnostics. Written and read on the pump thread, so no lock is
    /// needed.
    var lastReadStatus: OSStatus = noErr
    /// Status from the last handshake attempt, for diagnostics under the same
    /// rules as `lastReadStatus`.
    var lastHandshakeStatus: OSStatus = noErr
    var lastReadState: SSLSessionState = .idle

    fileprivate func isUsable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !isClosed && context != nil
    }
}

/// Isolates SecureTransport, which Apple deprecated in macOS 10.15.
///
/// KDE Connect requires reversed TLS roles: the side that *initiates* the TCP
/// connection must act as the TLS *server* and vice versa. Network.framework
/// ties TLS roles to listener/connection, so it cannot express this — leaving
/// SecureTransport as the only option.
///
/// The deprecation warnings this produces are expected and accepted.
enum SecureTransportShim {

    /// Create a session over an already-connected socket.
    /// `isServer` selects the TLS role, independent of which side dialled.
    static func makeSession(fd: Int32, isServer: Bool,
                            identity: SecIdentity,
                            certificate: SecCertificate) -> SecureTransportSession? {
        let session = SecureTransportSession(fd: fd)
        guard let context = createContext(for: session, isServer: isServer,
                                          identity: identity, certificate: certificate) else {
            return nil
        }
        session.context = context
        return session
    }

    /// Run the handshake to completion.
    static func handshake(_ session: SecureTransportSession) -> Bool {
        guard session.isUsable(), let context = session.context else { return false }
        session.ioLock.lock()
        defer { session.ioLock.unlock() }

        var status = noErr
        for _ in 0..<200 {
            if session.isClosed { return false }
            status = SSLHandshake(context)
            session.lastHandshakeStatus = status
            if status == noErr { return true }
            if status == errSSLPeerAuthCompleted {
                // Trust the peer for now; the caller pins the fingerprint.
                status = SSLHandshake(context)
                session.lastHandshakeStatus = status
                if status == noErr { return true }
            }
            if status == errSSLWouldBlock {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            return false
        }
        return false
    }

    /// Read into `buffer`.
    /// Returns: >0 bytes read, 0 clean EOF, -1 error, -2 would block.
    static func read(_ session: SecureTransportSession,
                     into buffer: UnsafeMutableRawPointer,
                     length: Int) -> Int {
        guard session.isUsable(), let context = session.context else { return -1 }
        session.ioLock.lock()
        defer { session.ioLock.unlock() }
        var got = 0
        let status = SSLRead(context, buffer, length, &got)
        session.lastReadStatus = status
        var state: SSLSessionState = .idle
        if SSLGetSessionState(context, &state) == noErr { session.lastReadState = state }
        if status == noErr || status == errSSLWouldBlock {
            return got > 0 ? got : -2
        }
        if status == errSSLClosedGraceful || status == errSSLClosedNoNotify {
            return 0
        }
        return -1
    }

    /// Write from `buffer`. Returns bytes written (0 = would block), -1 error.
    static func write(_ session: SecureTransportSession,
                      from buffer: UnsafeRawPointer,
                      length: Int) -> Int {
        guard session.isUsable(), let context = session.context else { return -1 }
        session.ioLock.lock()
        defer { session.ioLock.unlock() }
        var written = 0
        let status = SSLWrite(context, buffer, length, &written)
        if status == noErr || status == errSSLWouldBlock {
            return written
        }
        return -1
    }

    /// The peer certificate, or nil if the peer presented none (outbound
    /// links, by design — see startTLS).
    static func copyPeerCertificate(_ session: SecureTransportSession) -> SecCertificate? {
        guard session.isUsable(), let context = session.context else { return nil }
        session.ioLock.lock()
        defer { session.ioLock.unlock() }
        var trust: SecTrust?
        guard SSLCopyPeerTrust(context, &trust) == noErr, let trust else { return nil }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return nil }
        return chain.first
    }

    /// SHA-256 fingerprint of the peer certificate, or nil if the peer
    /// presented none (outbound links, by design).
    static func copyPeerFingerprint(_ session: SecureTransportSession) -> String? {
        copyPeerCertificate(session).map { IdentityStore.fingerprint(of: $0) }
    }

    /// Mark the session closed. The context is released by `deinit`, which
    /// runs only once the last in-flight call has finished with it.
    static func close(_ session: SecureTransportSession) {
        session.lock.lock()
        session.isClosed = true
        session.lock.unlock()
    }

    // MARK: Context setup

    private static func createContext(for session: SecureTransportSession,
                                      isServer: Bool,
                                      identity: SecIdentity,
                                      certificate: SecCertificate) -> SSLContext? {
        let side: SSLProtocolSide = isServer ? .serverSide : .clientSide
        guard let context = SSLCreateContext(kCFAllocatorDefault, side, .streamType) else {
            return nil
        }

        // Non-capturing closures, so they convert to C function pointers.
        //
        // The unretained lookup stays safe only because every call that can
        // reach these callbacks holds a strong reference to the session for
        // its duration (see KDELink), so the object cannot be deallocating.
        // Nothing may call into SSL from a deinit — see SecureTransportSession.
        let readFunc: SSLReadFunc = { connection, data, dataLength in
            let session = Unmanaged<SecureTransportSession>
                .fromOpaque(connection).takeUnretainedValue()
            let wanted = dataLength.pointee
            dataLength.pointee = 0
            var total = 0
            let buffer = data.assumingMemoryBound(to: UInt8.self)
            while total < wanted {
                // Never block with the session locked: report would-block and
                // let the caller come back.
                let n = Darwin.recv(session.fd, buffer.advanced(by: total), wanted - total, MSG_DONTWAIT)
                if n > 0 { total += n; continue }
                if n == 0 {
                    // End of stream. Hand over anything already read first, so
                    // the next call is the one that reports the close.
                    dataLength.pointee = total
                    return total > 0 ? errSSLWouldBlock : errSSLClosedGraceful
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                dataLength.pointee = total
                return total > 0 ? errSSLWouldBlock : errSSLClosedAbort
            }
            dataLength.pointee = total
            // A transfer shorter than requested must say "come back", which is
            // what the callback contract means by errSSLWouldBlock. Reporting
            // success while handing over fewer bytes tells the stack a record
            // arrived complete when it did not.
            return total == wanted ? noErr : errSSLWouldBlock
        }

        let writeFunc: SSLWriteFunc = { connection, data, dataLength in
            let session = Unmanaged<SecureTransportSession>
                .fromOpaque(connection).takeUnretainedValue()
            let wanted = dataLength.pointee
            dataLength.pointee = 0
            var total = 0
            let buffer = data.assumingMemoryBound(to: UInt8.self)
            while total < wanted {
                let n = Darwin.send(session.fd, buffer.advanced(by: total), wanted - total, MSG_DONTWAIT)
                if n > 0 { total += n; continue }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                dataLength.pointee = total
                return total > 0 ? errSSLWouldBlock : errSSLClosedAbort
            }
            dataLength.pointee = total
            return total == wanted ? noErr : errSSLWouldBlock
        }

        guard SSLSetIOFuncs(context, readFunc, writeFunc) == noErr,
              SSLSetConnection(context, UnsafeRawPointer(Unmanaged.passUnretained(session).toOpaque())) == noErr else {
            return nil
        }

        // Both sides present their certificate. Verification is done by the
        // caller via fingerprint pinning. We deliberately do not request a TLS
        // client certificate: SecureTransport's server-side client
        // authentication fails with errSSLXCertChainInvalid for self-signed
        // certificates on modern macOS, and the peer's certificate is reliably
        // captured on inbound links instead.
        let chain = [identity, certificate] as CFArray
        guard SSLSetCertificate(context, chain) == noErr else { return nil }

        if !isServer {
            // Accept the peer's self-signed certificate; the caller pins it.
            SSLSetSessionOption(context, .breakOnServerAuth, true)
        }
        return context
    }
}
