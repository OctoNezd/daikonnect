import Foundation
import Security
import Darwin

/// Serves a payload to a peer over a short-lived TLS connection.
///
/// This is the mirror image of reading a payload: the peer connects to us and
/// acts as the TLS *client*, so this side is the TLS server — the same
/// reversed-role arrangement the phone uses when it serves us notification
/// icons.
enum PayloadUploader {
    /// Opens a port and serves `data` to the first peer that connects.
    ///
    /// `onReady` is called on a background queue with the chosen port, so the
    /// caller can advertise it (in `payloadTransferInfo`) and only then is the
    /// connection accepted.
    static func serve(_ data: Data, timeout: TimeInterval = 20,
                      onReady: @escaping (UInt16) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var listenFD: Int32 = -1
            var port: UInt16 = 0
            for candidate in KDE_TCP_PORT_MIN...KDE_TCP_PORT_MAX {
                let fd = LanTransport.makeTCPListenSocket(port: candidate)
                if fd >= 0 {
                    listenFD = fd
                    port = candidate
                    break
                }
            }
            guard listenFD >= 0 else { return }
            defer { Darwin.close(listenFD) }

            onReady(port)

            guard LanTransport.waitReadable(fd: listenFD, timeoutSeconds: Int(timeout)) else {
                return
            }
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            guard clientFD >= 0 else { return }

            let store = IdentityStore.shared
            guard let identity = store.loadIdentity(),
                  let certificate = store.loadCertificateChain()?.first else {
                Darwin.close(clientFD)
                return
            }

            let link = KDELink(fd: clientFD,
                               remoteHost: LanTransport.peerIP(fd: clientFD),
                               outbound: false,
                               tlsServer: true)
            guard link.startTLS(identity: identity, certificate: certificate) else {
                link.close()
                return
            }
            _ = link.sendEncrypted(data)
            link.close()
        }
    }
}
