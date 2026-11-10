import Foundation
import CryptoKit

/*
 PocketMac handshake (v1) — mutual authentication, forward secrecy, no server.

   iPhone                                   Mac
   ClientHello  e_c, s_c, name   ───────▶
                                 ◀───────   ServerHello  e_s, s_s, salt, iterations
   (check ID == fingerprint(s_s))
   ClientFinish HMAC(kc, th)     ───────▶   (check password-bound MAC, pinned s_c)
                                 ◀───────   ServerFinish HMAC(ks, th)

   th   = SHA256(ClientHello ‖ ServerHello)
   keys = HKDF(DH(e_c,e_s) ‖ DH(e_c,s_s) ‖ DH(s_c,e_s) ‖ PBKDF2(password), salt: th)

 - Typing the Mac ID pins the Mac's static key → a fake "Mac" can't finish the
   handshake (it lacks s_s), so it can't brute-force the password offline.
 - The Mac only answers devices it has paired (or while pairing is open), and
   only reveals success after a correct ClientFinish → guesses are online-only
   and rate-limited.
 - Ephemeral e_c/e_s give forward secrecy.
*/

enum HandshakeType: UInt8 {
    case clientHello = 0x01, serverHello = 0x02, clientFinish = 0x03, serverFinish = 0x04, error = 0x05
}

enum HandshakeErrorCode: UInt8 {
    case badCredentials = 1, notAuthorized = 2, lockedOut = 3, badVersion = 4, notConfigured = 5, protocolError = 6

    var userMessage: String {
        switch self {
        case .badCredentials: return "Wrong password."
        case .notAuthorized: return "This phone isn’t paired. On the Mac, click “Pair new phone” and try again."
        case .lockedOut: return "Too many wrong attempts. Try again later."
        case .badVersion: return "App and Mac host versions don't match. Update both."
        case .notConfigured: return "The Mac host has no password yet. Set one in PocketMac Host on the Mac."
        case .protocolError: return "Connection error during login."
        }
    }
}

struct HandshakeFailure: Error, CustomStringConvertible {
    let code: HandshakeErrorCode
    let retryAfter: UInt32
    let message: String
    var description: String {
        if code == .lockedOut, retryAfter > 0 { return "Too many wrong attempts. Try again in \(retryAfter) s." }
        return message.isEmpty ? code.userMessage : message
    }
}

struct SessionKeys {
    let clientToServer: Data
    let serverToClient: Data
    let confirmClient: Data
    let confirmServer: Data
}

enum Handshake {
    static let version: UInt8 = 1
    static let magic = Data("PKM".utf8)
    static let maxNameLength = 64

    static func transcript(_ clientHello: Data, _ serverHello: Data) -> Data {
        PMCrypto.sha256(clientHello + serverHello)
    }

    static func deriveKeys(dh1: Data, dh2: Data, dh3: Data, passwordKey: Data, transcript: Data) -> SessionKeys {
        let ikm = SymmetricKey(data: dh1 + dh2 + dh3 + passwordKey)
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: transcript,
                                         info: Data("PocketMac v1 session".utf8), outputByteCount: 128)
        let b = okm.withUnsafeBytes { Data($0) }
        return SessionKeys(clientToServer: b.subdata(in: 0..<32),
                           serverToClient: b.subdata(in: 32..<64),
                           confirmClient: b.subdata(in: 64..<96),
                           confirmServer: b.subdata(in: 96..<128))
    }

    static func errorMessage(_ code: HandshakeErrorCode, retryAfter: UInt32 = 0, message: String = "") -> Data {
        var w = WireWriter()
        w.u8(HandshakeType.error.rawValue)
        w.u8(code.rawValue)
        w.u32(retryAfter)
        w.string(message)
        return w.data
    }

    /// Throws HandshakeFailure if `msg` is an error message, otherwise checks the type.
    static func expect(_ type: HandshakeType, in msg: Data) throws -> WireReader {
        var r = WireReader(msg)
        let t = try r.u8()
        if t == HandshakeType.error.rawValue {
            let codeRaw = try r.u8()
            let retry = try r.u32()
            let message = (try? r.string()) ?? ""
            throw HandshakeFailure(code: HandshakeErrorCode(rawValue: codeRaw) ?? .protocolError,
                                   retryAfter: retry, message: message)
        }
        guard t == type.rawValue else {
            throw HandshakeFailure(code: .protocolError, retryAfter: 0, message: "Unexpected handshake message.")
        }
        return r
    }
}

// MARK: - Client (iPhone)

final class ClientHandshake {
    struct ServerHelloInfo {
        let hostStaticKey: Data
        let salt: Data
        let iterations: UInt32
        let hostName: String
        let alreadyPaired: Bool
    }

    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let expectedID: String
    private let deviceName: String
    private var helloBytes = Data()
    private var serverHelloBytes = Data()
    private var serverEphemeral = Data()
    private var serverStatic = Data()

    /// `ephemeral` is only passed by the test-vector tool; normally a fresh key per login.
    init(staticKey: Curve25519.KeyAgreement.PrivateKey, expectedID: String, deviceName: String,
         ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.staticKey = staticKey
        self.ephemeral = ephemeral
        self.expectedID = DeviceID.normalize(expectedID)
        self.deviceName = String(deviceName.prefix(Handshake.maxNameLength))
    }

    func hello() -> Data {
        var w = WireWriter()
        w.u8(HandshakeType.clientHello.rawValue)
        w.raw(Handshake.magic)
        w.u8(Handshake.version)
        w.raw(ephemeral.publicKey.rawRepresentation)
        w.raw(staticKey.publicKey.rawRepresentation)
        w.string(deviceName)
        helloBytes = w.data
        return helloBytes
    }

    func parseServerHello(_ msg: Data) throws -> ServerHelloInfo {
        var r = try Handshake.expect(.serverHello, in: msg)
        serverEphemeral = try r.take(32)
        serverStatic = try r.take(32)
        let salt = try r.blob16()
        let iterations = try r.u32()
        let hostName = try r.string()
        let flags = try r.u8()
        guard DeviceID.from(publicKey: serverStatic) == expectedID else {
            throw HandshakeFailure(code: .protocolError, retryAfter: 0,
                                   message: "This Mac's ID doesn't match. Check the ID shown in PocketMac Host.")
        }
        guard iterations >= 10_000, iterations <= 5_000_000, salt.count >= 16 else {
            throw HandshakeFailure(code: .protocolError, retryAfter: 0, message: "Bad key parameters from Mac.")
        }
        serverHelloBytes = msg
        return ServerHelloInfo(hostStaticKey: serverStatic, salt: salt, iterations: iterations,
                               hostName: hostName, alreadyPaired: flags & 1 != 0)
    }

    /// Returns the ClientFinish message and the session keys.
    func finish(passwordKey: Data) throws -> (Data, SessionKeys) {
        let dh1 = try PMCrypto.dh(ephemeral, serverEphemeral)
        let dh2 = try PMCrypto.dh(ephemeral, serverStatic)
        let dh3 = try PMCrypto.dh(staticKey, serverEphemeral)
        let th = Handshake.transcript(helloBytes, serverHelloBytes)
        let keys = Handshake.deriveKeys(dh1: dh1, dh2: dh2, dh3: dh3, passwordKey: passwordKey, transcript: th)
        var w = WireWriter()
        w.u8(HandshakeType.clientFinish.rawValue)
        w.raw(PMCrypto.hmac(keys.confirmClient, th + Data("client".utf8)))
        return (w.data, keys)
    }

    func verifyServerFinish(_ msg: Data, keys: SessionKeys) throws {
        var r = try Handshake.expect(.serverFinish, in: msg)
        let mac = try r.take(32)
        let th = Handshake.transcript(helloBytes, serverHelloBytes)
        guard PMCrypto.equal(mac, PMCrypto.hmac(keys.confirmServer, th + Data("server".utf8))) else {
            throw HandshakeFailure(code: .protocolError, retryAfter: 0, message: "Mac failed to prove its identity.")
        }
    }
}

// MARK: - Server (Mac)

final class ServerHandshake {
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var clientHelloBytes = Data()
    private var serverHelloBytes = Data()
    private(set) var clientEphemeral = Data()
    private(set) var clientStatic = Data()
    private(set) var clientName = ""

    init(staticKey: Curve25519.KeyAgreement.PrivateKey, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.staticKey = staticKey
        self.ephemeral = ephemeral
    }

    func parseClientHello(_ msg: Data) throws {
        var r = try Handshake.expect(.clientHello, in: msg)
        guard try r.take(3) == Handshake.magic else { throw HandshakeFailure(code: .protocolError, retryAfter: 0, message: "") }
        guard try r.u8() == Handshake.version else { throw HandshakeFailure(code: .badVersion, retryAfter: 0, message: "") }
        clientEphemeral = try r.take(32)
        clientStatic = try r.take(32)
        clientName = String((try r.string()).prefix(Handshake.maxNameLength))
        clientHelloBytes = msg
    }

    func serverHello(salt: Data, iterations: UInt32, hostName: String, alreadyPaired: Bool) -> Data {
        var w = WireWriter()
        w.u8(HandshakeType.serverHello.rawValue)
        w.raw(ephemeral.publicKey.rawRepresentation)
        w.raw(staticKey.publicKey.rawRepresentation)
        w.blob16(salt)
        w.u32(iterations)
        w.string(hostName)
        w.u8(alreadyPaired ? 1 : 0)
        serverHelloBytes = w.data
        return serverHelloBytes
    }

    /// Verifies the client's password-bound MAC. Returns ServerFinish + keys, or nil on wrong password.
    func verifyClientFinish(_ msg: Data, passwordKey: Data) throws -> (Data, SessionKeys)? {
        var r = try Handshake.expect(.clientFinish, in: msg)
        let mac = try r.take(32)
        let dh1 = try PMCrypto.dh(ephemeral, clientEphemeral)
        let dh2 = try PMCrypto.dh(staticKey, clientEphemeral)
        let dh3 = try PMCrypto.dh(ephemeral, clientStatic)
        let th = Handshake.transcript(clientHelloBytes, serverHelloBytes)
        let keys = Handshake.deriveKeys(dh1: dh1, dh2: dh2, dh3: dh3, passwordKey: passwordKey, transcript: th)
        guard PMCrypto.equal(mac, PMCrypto.hmac(keys.confirmClient, th + Data("client".utf8))) else { return nil }
        var w = WireWriter()
        w.u8(HandshakeType.serverFinish.rawValue)
        w.raw(PMCrypto.hmac(keys.confirmServer, th + Data("server".utf8)))
        return (w.data, keys)
    }
}
