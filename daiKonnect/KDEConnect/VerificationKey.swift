import Foundation
import CryptoKit
import Security

/// The short key both devices display while pairing, so a person can compare
/// them and confirm the connection is legitimate rather than a certificate
/// swap. The phone shows the same key in its pairing screen and notification,
/// so this has to match its arithmetic exactly — from kdeconnect-android's
/// `PairingHandler`:
///
///     SHA-256( largerPublicKey || smallerPublicKey || timestamp? )
///         -> first 8 hex characters, upper case
///
/// The timestamp is appended, as decimal text, from protocol 8 on, and is the
/// one the pairing initiator chose and sent in its pair packet. Both sides
/// therefore hash identical bytes and show identical keys.
///
/// The known-answer values in `kdeconnect-android`'s PairingHandlerTest are
/// reproduced by this implementation, including its ECDSA P-256 certificates.
enum VerificationKey {
    /// Compute the key, or nil when either public key is unavailable or a
    /// protocol 8+ pairing has no timestamp yet.
    static func compute(local: SecCertificate, peer: SecCertificate,
                        timestamp: Int?, protocolVersion: Int) -> String? {
        guard let mine = subjectPublicKeyInfo(of: local),
              let theirs = subjectPublicKeyInfo(of: peer) else { return nil }

        var material = sortedConcat(mine, theirs)
        if protocolVersion >= 8 {
            guard let timestamp else { return nil }
            material.append(contentsOf: Array(String(timestamp).utf8))
        }
        return readable(material)
    }

    /// Concatenate the two keys in a deterministic order — larger first, by
    /// unsigned byte comparison — so both devices hash the same sequence
    /// whichever way round they hold them.
    static func sortedConcat(_ a: Data, _ b: Data) -> Data {
        a.lexicographicallyPrecedes(b) ? b + a : a + b
    }

    /// First 8 hex characters of the SHA-256, upper case.
    static func readable(_ material: Data) -> String {
        let hex = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8)).uppercased()
    }

    /// The certificate's DER `SubjectPublicKeyInfo`, which is what the peer
    /// hashes (`PublicKey.getEncoded()`), copied straight out of the
    /// certificate rather than rebuilt from the key.
    ///
    /// The KDE Connect ends do not agree on key type: the Android app
    /// generates ECDSA P-256 (`RsaHelper`), older installs and GSConnect use
    /// RSA. Copying the encoded structure is correct for either, because it is
    /// defined by the certificate rather than by us.
    static func subjectPublicKeyInfo(of certificate: SecCertificate) -> Data? {
        let der = SecCertificateCopyData(certificate) as Data

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        guard let outer = field(der, at: 0), outer.tag == 0x30,
              let tbs = field(der, at: outer.contentStart), tbs.tag == 0x30 else { return nil }

        // TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
        //   signature, issuer, validity, subject, subjectPublicKeyInfo, ... }
        // so it is the seventh field, or the sixth when the version is absent.
        var offset = tbs.contentStart
        var index = 0
        let spkiIndex = (field(der, at: offset)?.tag == 0xa0) ? 6 : 5
        while offset < tbs.contentEnd {
            guard let current = field(der, at: offset) else { return nil }
            if index == spkiIndex, current.tag == 0x30 {
                return der.subdata(in: offset..<current.end)
            }
            offset = current.end
            index += 1
        }
        return nil
    }

    // MARK: - DER

    private struct DerField {
        let tag: UInt8
        let contentStart: Int
        let contentEnd: Int
        /// One past the last byte of the field, header included.
        let end: Int
    }

    private static func field(_ data: Data, at offset: Int) -> DerField? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let base = data.startIndex
        let tag = data[base + offset]
        var cursor = offset + 1
        let first = data[base + cursor]
        cursor += 1

        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard count > 0, count <= 4, cursor + count <= data.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(data[base + cursor])
                cursor += 1
            }
        }

        let contentStart = cursor
        let contentEnd = contentStart + length
        guard contentEnd <= data.count else { return nil }
        return DerField(tag: tag, contentStart: contentStart, contentEnd: contentEnd, end: contentEnd)
    }
}
