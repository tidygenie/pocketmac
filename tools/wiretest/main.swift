// Round-trips every message type through encode → decode and checks the result.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) { if !ok { failures += 1; print("FAIL \(name)") } }

let client: [ClientMessage] = [
    .startStream(StreamSettings(quality: .sharp, maxFPS: 60, codec: .h264, clientPixelWidth: 2532, clientPixelHeight: 1170, lidFit: .phoneRoomy)),
    .updateSettings(StreamSettings()), .frameAck(0xDEADBEEF), .requestKeyframe, .setPaused(true),
    .mouseMove(x: 0.25, y: 0.75), .mouseButton(button: 1, down: true, x: 0.5, y: 0.125, clicks: 2, flags: 0x100000),
    .scroll(dx: -3.5, dy: 12.25), .key(code: 36, down: false, flags: 0x20000), .text("नमस्ते 👋 hello\n"),
    .action(.sleepMac), .clipboard(String(repeating: "x", count: 70_000)), .ping(123_456_789),
]
for m in client {
    let back = try! ClientMessage.decode(m.encode())
    check("\(m)".prefix(40).description, "\(back)" == "\(m)")
}
var st = HostStatus(); st.hostName = "Mac"; st.battery = 42; st.charging = true; st.lidClosed = true; st.virtualDisplay = true
let server: [ServerMessage] = [
    .videoFormat(VideoFormat(codec: .hevc, width: 1920, height: 1248, parameterSets: [Data([1, 2, 3]), Data([4]), Data()])),
    .videoFrame(VideoFrame(frameID: 7, keyframe: true, captureMicros: 99, data: Data(repeating: 9, count: 300_000))),
    .status(st), .clipboard("copied ✓"), .pong(5), .cursor(x: 0.1, y: 0.9), .notice("hi"),
]
for m in server {
    let back = try! ServerMessage.decode(m.encode())
    check("\(m)".prefix(40).description, "\(back)" == "\(m)")
}
// Truncated / garbage input must throw, never crash.
for m in client.map({ $0.encode() }) + server.map({ $0.encode() }) where m.count > 1 {
    for cut in [1, m.count / 2, m.count - 1] where cut < m.count && cut > 0 {
        _ = try? ClientMessage.decode(m.prefix(cut))
        _ = try? ServerMessage.decode(m.prefix(cut))
    }
}
for _ in 0..<20_000 {
    let junk = PMCrypto.randomBytes(Int.random(in: 0...64))
    _ = try? ClientMessage.decode(junk); _ = try? ServerMessage.decode(junk)
}
// Device ID normalisation.
check("id normalize", DeviceID.normalize("1n81-1epb-jzxh") == "1N811EPBJZXH")
check("id lookalikes", DeviceID.normalize("O0IL") == "0011")
check("id pretty", DeviceID.pretty("1N811EPBJZXH") == "1N81-1EPB-JZXH")
// Cipher: tampering must fail.
let k = PMCrypto.randomBytes(32)
let a = CipherState(key: k), b = CipherState(key: k)
var rec = try! a.seal(Data("secret".utf8))
check("cipher roundtrip", (try? b.open(rec)) == Data("secret".utf8))
rec = try! a.seal(Data("secret".utf8)); rec[rec.startIndex] ^= 1
check("cipher tamper rejected", (try? b.open(rec)) == nil)
print(failures == 0 ? "wiretest: all OK (\(client.count + server.count) message types, fuzzed)" : "wiretest: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
