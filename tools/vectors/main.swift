// vectors — writes known-answer test vectors from the real Shared/ code so the
// Android app's Kotlin port can prove it speaks exactly the same protocol.
// Output: "name value" lines (hex unless noted). Run: tools/make-vectors.sh
import Foundation
import CryptoKit

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func key(_ seed: Int) -> Curve25519.KeyAgreement.PrivateKey {
    try! .init(rawRepresentation: Data((0..<32).map { UInt8(truncatingIfNeeded: $0 * 7 + seed * 31 + 1) }))
}

var lines = [String]()
func put(_ name: String, _ value: String) { lines.append("\(name) \(value)") }
func put(_ name: String, _ d: Data) { put(name, hex(d)) }

// Device IDs (fingerprint of a public key) and input normalisation
for i in 0..<3 {
    let k = key(100 + i)
    put("id.\(i).priv", k.rawRepresentation)
    put("id.\(i).pub", k.publicKey.rawRepresentation)
    put("id.\(i).id", Data(DeviceID.from(publicKey: k.publicKey.rawRepresentation).utf8))
}
for (i, s) in ["k7qm-4xpa-9tzc", "oil u-0IL1 xx!", "  ab cd  "].enumerated() {
    put("norm.\(i).in", Data(s.utf8))
    put("norm.\(i).out", Data(DeviceID.normalize(s).utf8))
}

// X25519
let a = key(1), b = key(2)
put("dh.a", a.rawRepresentation)
put("dh.bpub", b.publicKey.rawRepresentation)
put("dh.shared", try! PMCrypto.dh(a, b.publicKey.rawRepresentation))

// PBKDF2 (password is NFC-normalised first; the 2nd one is typed decomposed)
let salt = Data((0..<16).map { UInt8($0 * 3) })
for (i, (pw, it)) in [("testpass123", UInt32(1000)), ("pa\u{0308}ss wo\u{0308}rd ✓", 1000), ("testpass123", 210_000)].enumerated() {
    put("pbkdf2.\(i).password", Data(pw.utf8))
    put("pbkdf2.\(i).salt", salt)
    put("pbkdf2.\(i).iterations", String(it))
    put("pbkdf2.\(i).key", PMCrypto.passwordKey(pw, salt: salt, iterations: it))
}

// Full handshake with fixed keys, using the real client and server classes
let cs = key(10), ce = key(11), ss = key(20), se = key(21)
let macID = DeviceID.from(publicKey: ss.publicKey.rawRepresentation)
let client = ClientHandshake(staticKey: cs, expectedID: DeviceID.pretty(macID), deviceName: "Pixel 9 ✓", ephemeral: ce)
let server = ServerHandshake(staticKey: ss, ephemeral: se)
let password = "correct horse"
let hsSalt = Data((0..<16).map { UInt8(200 - $0) })
let ch = client.hello()
try! server.parseClientHello(ch)
let sh = server.serverHello(salt: hsSalt, iterations: 10_000, hostName: "Naresh’s MacBook Air", alreadyPaired: true)
let info = try! client.parseServerHello(sh)
let pk = PMCrypto.passwordKey(password, salt: info.salt, iterations: info.iterations)
let (cf, ck) = try! client.finish(passwordKey: pk)
let (sf, sk) = try! server.verifyClientFinish(cf, passwordKey: pk)!
try! client.verifyServerFinish(sf, keys: ck)
precondition(ck.clientToServer == sk.clientToServer && ck.serverToClient == sk.serverToClient)
put("hs.clientStatic", cs.rawRepresentation)
put("hs.clientEphemeral", ce.rawRepresentation)
put("hs.macID", Data(DeviceID.pretty(macID).utf8))
put("hs.deviceName", Data("Pixel 9 ✓".utf8))
put("hs.password", Data(password.utf8))
put("hs.clientHello", ch)
put("hs.serverHello", sh)
put("hs.clientFinish", cf)
put("hs.serverFinish", sf)
put("hs.c2s", ck.clientToServer)
put("hs.s2c", ck.serverToClient)
put("hs.error", Handshake.errorMessage(.lockedOut, retryAfter: 30, message: "slow down"))

// Encrypted records, phone → Mac (Kotlin must produce identical bytes)
var settings = StreamSettings()
settings.quality = .sharp; settings.maxFPS = 60; settings.codec = .h264
settings.clientPixelWidth = 2400; settings.clientPixelHeight = 1080; settings.lidFit = .phoneRoomy
let clientMessages: [ClientMessage] = [
    .startStream(settings), .updateSettings(StreamSettings()), .frameAck(0xDEADBEEF), .requestKeyframe,
    .setPaused(true), .mouseMove(x: 0.25, y: 0.75),
    .mouseButton(button: 1, down: true, x: 0.5, y: 0.125, clicks: 2, flags: ModifierFlagBits.command),
    .scroll(dx: -3.5, dy: 12.25), .key(code: 36, down: false, flags: 0x40000), .text("héllo ✓\n"),
    .action(.missionControl), .clipboard("clip 📋"), .ping(1_234_567_890_123),
]
let csend = CipherState(key: ck.clientToServer)
for (i, m) in clientMessages.enumerated() {
    let plain = m.encode()
    put("c2s.\(i).plain", plain)
    put("c2s.\(i).sealed", try! csend.seal(plain))
}

// Encrypted records, Mac → phone (Kotlin must open and decode them)
var status = HostStatus()
status.hostName = "MacBook Air"; status.battery = 87; status.charging = true; status.lidMode = true
status.screenPermission = true; status.accessibilityPermission = true
let serverMessages: [ServerMessage] = [
    .videoFormat(VideoFormat(codec: .hevc, width: 1920, height: 1248,
                             parameterSets: [Data([0x40, 1, 2]), Data([0x42, 3, 4, 5]), Data([0x44, 6])])),
    .videoFrame(VideoFrame(frameID: 42, keyframe: true, captureMicros: 987_654_321,
                           data: Data([0, 0, 0, 3, 0x26, 1, 0xAF, 0, 0, 0, 2, 0x02, 0x01]))),
    .status(status), .clipboard("from Mac ✓"), .pong(55), .cursor(x: 0.5, y: 0.0625), .notice("Mac locked"),
]
let ssend = CipherState(key: sk.serverToClient)
for (i, m) in serverMessages.enumerated() {
    let plain = m.encode()
    put("s2c.\(i).plain", plain)
    put("s2c.\(i).sealed", try! ssend.seal(plain))
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "vectors.txt"
try! (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
print("wrote \(lines.count) vectors to \(path)")

enum ModifierFlagBits { static let command: UInt32 = 0x100000 }
