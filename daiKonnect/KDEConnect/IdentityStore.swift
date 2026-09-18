import Foundation
import Security
import CryptoKit

/// Own device identity: persistent deviceId, display name, and the
/// self-signed RSA certificate used for the TLS links.
///
/// KDE Connect requires every device to own a self-signed certificate whose
/// Common Name equals the deviceId. The peer pins the certificate fingerprint
/// at pairing time. Generating X.509 by hand in Swift is a lot of ASN.1, so
/// this store shells out to the system `openssl` once and reuses thePEM files
/// afterwards (stored in Application Support/daiKonnect).
final class IdentityStore {
    static let shared = IdentityStore()

    let deviceId: String
    var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "daiKonnect.deviceName") }
    }

    private let directory: URL
    private let certURL: URL
    private let certDERURL: URL
    private let keyURL: URL
    private let p12URL: URL
    private var cachedOwnCertificate: SecCertificate?
    private static let p12Password = "daikonnect"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("daiKonnect", isDirectory: true)
        directory = dir
        certURL = dir.appendingPathComponent("cert.pem")
        certDERURL = dir.appendingPathComponent("cert.der")
        keyURL = dir.appendingPathComponent("key.pem")
        p12URL = dir.appendingPathComponent("identity.p12")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Stable device id: random UUIDv4 without hyphens (32 alnum chars).
        deviceId = IdentityStore.resolveDeviceId(directory: dir, certURL: certURL)
        try? deviceId.write(to: dir.appendingPathComponent("deviceId"), atomically: true, encoding: .utf8)
        // Kept in step for anything else that looks there, though this file is
        // now the source of truth.
        UserDefaults.standard.set(deviceId, forKey: "daiKonnect.deviceId")

        let host = Host.current().localizedName ?? "Mac"
        let fallback = UserDefaults.standard.string(forKey: "daiKonnect.deviceName") ?? host
        deviceName = IdentityStore.sanitizeDeviceName(fallback)
    }

    /// The device id, kept beside the certificate rather than in preferences.
    ///
    /// It used to live in UserDefaults, which is per bundle identifier, so
    /// renaming the app minted a fresh identity while the certificate — and
    /// everything the phone had pinned against the old identity — stayed put.
    /// The result was a device advertising one id while presenting a
    /// certificate whose common name was another, which KDE Connect requires
    /// to be the same.
    ///
    /// So the certificate's common name wins when the two disagree: it is the
    /// identity the phone already knows.
    private static func resolveDeviceId(directory: URL, certURL: URL) -> String {
        let idURL = directory.appendingPathComponent("deviceId")
        if let saved = try? String(contentsOf: idURL, encoding: .utf8), saved.count >= 32 {
            return saved
        }
        if let existing = certificateCommonName(certURL: certURL), existing.count >= 32 {
            return existing
        }
        if let saved = UserDefaults.standard.string(forKey: "daiKonnect.deviceId"), saved.count >= 32 {
            return saved
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Common name of the certificate at `certURL`, which KDE Connect sets to
    /// the device id.
    static func certificateCommonName(certURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: certURL.path),
              let openssl = findOpenSSL() else { return nil }
        let (code, output) = run(openssl, args: ["x509", "-in", certURL.path, "-noout", "-subject"])
        guard code == 0, let start = output.range(of: "CN=") else { return nil }
        let rest = output[start.upperBound...]
        return String(rest.prefix { $0 != "," && $0 != "\n" }).trimmingCharacters(in: .whitespaces)
    }

    /// Device names must be 1-32 chars without `"',;:.!?()[]<>`
    static func sanitizeDeviceName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\"',;:.!?()[]<>")
        var clean = name.components(separatedBy: forbidden).joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = "Mac" }
        if clean.count > 32 { clean = String(clean.prefix(32)) }
        return clean
    }

    var hasCertificate: Bool {
        FileManager.default.fileExists(atPath: certURL.path) &&
        FileManager.default.fileExists(atPath: keyURL.path)
    }

    /// Generate the self-signed cert with openssl if missing. Returns an error string on failure.
    @discardableResult
    func ensureCertificate() -> String? {
        if hasCertificate {
            // KDE Connect requires the certificate's common name to be the
            // device id; Android regenerates its own certificate when the two
            // drift apart. Should be unreachable now that the id follows the
            // certificate, but a mismatched pair must not go on the wire.
            if let named = IdentityStore.certificateCommonName(certURL: certURL), named != deviceId {
                return "Certificate names device \(named) but this device is \(deviceId)"
            }
            return nil
        }
        guard let openssl = IdentityStore.findOpenSSL() else {
            return "No openssl binary found. Install Xcode CLT or `brew install openssl`."
        }
        let subject = "/O=KDE/OU=KDE Connect/CN=\(deviceId)"
        let args = ["req", "-x509", "-newkey", "rsa:2048",
                    "-keyout", keyURL.path, "-out", certURL.path,
                    "-days", "3650", "-nodes", "-subj", subject]
        let (code, err) = IdentityStore.run(openssl, args: args)
        guard code == 0 else { return "openssl req failed: \(err)" }
        // Bundle into PKCS#12 so Security.framework can import a SecIdentity.
        let p12args = ["pkcs12", "-export",
                       "-out", p12URL.path, "-inkey", keyURL.path, "-in", certURL.path,
                       "-passout", "pass:\(Self.p12Password)", "-name", "daiKonnect"]
        let (code2, err2) = IdentityStore.run(openssl, args: p12args)
        guard code2 == 0 else { return "openssl pkcs12 failed: \(err2)" }
        // DER copy for Security.framework (which wants raw DER, not PEM).
        if let err = ensureDER(openssl: openssl) { return err }
        return nil
    }

    /// (Re)create cert.der from cert.pem; also backfills older installs.
    private func ensureDER(openssl: String) -> String? {
        if FileManager.default.fileExists(atPath: certDERURL.path) { return nil }
        let (code, err) = IdentityStore.run(openssl, args: ["x509", "-in", certURL.path,
                                                            "-outform", "DER",
                                                            "-out", certDERURL.path])
        guard code == 0 else { return "openssl x509 DER export failed: \(err)" }
        return nil
    }

    /// Load our SecIdentity (certificate + private key) for TLS.
    ///
    /// The identity is imported memory-only (`kSecImportToMemoryOnly`), so the
    /// private key never lands in the login keychain and macOS never pops up
    /// an "enter password for imported private key" dialog. The deployment
    /// target is macOS 15, where that option exists, so no keychain fallback
    /// (and no legacy ACL API) is needed.
    func loadIdentity() -> SecIdentity? {
        guard let data = try? Data(contentsOf: p12URL) else { return nil }
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: Self.p12Password,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let arr = items as? [[String: Any]],
              let dict = arr.first, let ident = dict[kSecImportItemIdentity as String] else { return nil }
        return (ident as! SecIdentity)
    }

    /// Our own certificate chain, used when presenting our identity on a link.
    func loadCertificateChain() -> [SecCertificate]? {
        if let openssl = Self.findOpenSSL() { _ = ensureDER(openssl: openssl) }
        guard let data = try? Data(contentsOf: certDERURL),
              let cert = SecCertificateCreateWithData(nil, data as CFData) else { return nil }
        return [cert]
    }

    /// Our own certificate, needed to compute the pairing verification key.
    /// Cached because the pairing banner asks for it on every render.
    func ownCertificate() -> SecCertificate? {
        if let cachedOwnCertificate { return cachedOwnCertificate }
        guard let certificate = loadCertificateChain()?.first else { return nil }
        cachedOwnCertificate = certificate
        return certificate
    }

    /// SHA-256 fingerprint (hex) of our certificate, for display/debug.
    func ownFingerprint() -> String? {
        if let openssl = Self.findOpenSSL() { _ = ensureDER(openssl: openssl) }
        guard let data = try? Data(contentsOf: certDERURL),
              let cert = SecCertificateCreateWithData(nil, data as CFData) else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(of cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - helpers

    static func findOpenSSL() -> String? {
        for candidate in ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"] {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    static func run(_ launchPath: String, args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, out)
    }
}
