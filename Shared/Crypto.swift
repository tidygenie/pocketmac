import Foundation
import CryptoKit
import CommonCrypto

enum PMCrypto {
    static let defaultIterations: UInt32 = 210_000

    /// PBKDF2-HMAC-SHA256. Used only to turn the human password into a 32-byte key.
    static func passwordKey(_ password: String, salt: Data, iterations: UInt32) -> Data {
        let pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let rc = salt.withUnsafeBytes { saltPtr -> Int32 in
            pw.withUnsafeBufferPointer { pwPtr in
                pwPtr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { pwBase in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwBase, pw.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         iterations, &out, out.count)
                }
            }
        }
        precondition(rc == kCCSuccess, "PBKDF2 failed")
        return Data(out)
    }

    static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        let rc = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        precondition(rc == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(b)
    }

    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    static func hmac(_ key: Data, _ msg: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    /// Constant-time comparison.
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }

    static func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pubRaw: Data) throws -> Data {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw)
        let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
        let raw = secret.withUnsafeBytes { Data($0) }
        // Reject low-order points (all-zero output).
        guard raw.contains(where: { $0 != 0 }) else { throw WireError("invalid public key") }
        return raw
    }
}

/// The Mac's ID is a fingerprint of its long-term public key:
/// 60 bits shown as 12 Crockford-base32 characters, e.g. "K7QM-4XPA-9TZC".
/// Typing the ID on the phone therefore *authenticates the Mac* — nobody can
/// impersonate it without its private key.
enum DeviceID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func from(publicKey: Data) -> String {
        let h = PMCrypto.sha256(publicKey)
        var bits: UInt64 = 0
        for i in 0..<8 { bits = (bits << 8) | UInt64(h[i]) }
        bits >>= 4 // keep top 60 bits
        var chars = [Character]()
        for i in (0..<12).reversed() {
            chars.append(alphabet[Int((bits >> UInt64(i * 5)) & 0x1F)])
        }
        return String(chars)
    }

    /// Normalise user input: upper-case, drop separators, fix look-alikes.
    static func normalize(_ input: String) -> String {
        var out = ""
        for ch in input.uppercased() {
            switch ch {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            case "U": out.append("V")
            default:
                if alphabet.contains(ch) { out.append(ch) }
            }
        }
        return out
    }

    static func pretty(_ id: String) -> String {
        let n = normalize(id)
        guard n.count == 12 else { return n }
        let a = Array(n)
        return String(a[0..<4]) + "-" + String(a[4..<8]) + "-" + String(a[8..<12])
    }

    static func isValid(_ id: String) -> Bool { normalize(id).count == 12 }
}

/// One direction of the encrypted stream. AES-256-GCM with an implicit 64-bit
/// counter nonce, so any replayed / reordered / dropped record fails to open.
final class CipherState {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: Data) { self.key = SymmetricKey(data: key) }

    private func nextNonce() throws -> AES.GCM.Nonce {
        var n = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { n.append(contentsOf: $0) }
        counter += 1
        return try AES.GCM.Nonce(data: n)
    }

    func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try nextNonce())
        var out = box.ciphertext
        out.append(box.tag)
        return out
    }

    func open(_ record: Data) throws -> Data {
        guard record.count >= 16 else { throw WireError("record too short") }
        let ct = record.prefix(record.count - 16)
        let tag = record.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: try nextNonce(), ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: key)
    }
}
