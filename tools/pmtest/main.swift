// pmtest — command-line PocketMac client using the exact same Shared/ code as the
// iPhone app. Logs in, streams, decodes with VideoToolbox, writes a PNG.
//
//   pmtest --id XXXX-XXXX-XXXX --password pw [--host 127.0.0.1] [--port 47800]
//          [--seconds 6] [--codec hevc|h264] [--quality 0|1|2] [--png out.png]
//          [--identity file] [--expect-fail badCredentials|notAuthorized|lockedOut|protocolError]
//          [--dump file]   (saves the video messages, length-prefixed, as a fixture for the Android tests)
import Foundation
import Network
import CryptoKit
import VideoToolbox
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

var opts = [String: String]()
var argv = CommandLine.arguments.dropFirst()
while let a = argv.popFirst() {
    guard a.hasPrefix("--") else { continue }
    var value = "1"
    if let next = argv.first, !next.hasPrefix("--") { value = next; argv.removeFirst() }
    opts[String(a.dropFirst(2))] = value
}
guard let macID = opts["id"], let password = opts["password"] else {
    print("usage: pmtest --id ID --password PW [...]"); exit(64)
}
let host = opts["host"] ?? "127.0.0.1"
let port = UInt16(opts["port"] ?? "") ?? 47800
let seconds = Double(opts["seconds"] ?? "6") ?? 6
let identityPath = opts["identity"] ?? NSTemporaryDirectory() + "pmtest-identity.key"
let expectFail = opts["expect-fail"]

let identity: Curve25519.KeyAgreement.PrivateKey = {
    if let d = FileManager.default.contents(atPath: identityPath),
       let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) { return k }
    let k = Curve25519.KeyAgreement.PrivateKey()
    FileManager.default.createFile(atPath: identityPath, contents: k.rawRepresentation)
    return k
}()

final class Decoder {
    private var session: VTDecompressionSession?
    let fd: CMVideoFormatDescription
    var decoded = 0, errors = 0
    var last: CVPixelBuffer?

    init?(_ f: VideoFormat) {
        guard let fd = f.makeFormatDescription() else { return nil }
        self.fd = fd
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr else { return nil }
        session = s
    }

    func decode(_ frame: VideoFrame) {
        guard let session, let sb = frame.makeSampleBuffer(fd, displayImmediately: false) else { errors += 1; return }
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            if status == noErr, let img { self.decoded += 1; self.last = img } else { self.errors += 1 }
        }
        if st != noErr { errors += 1 }
    }

    func savePNG(_ path: String) -> Bool {
        guard let pb = last else { return false }
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        guard let cg, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                 UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }
}

var settings = StreamSettings()
settings.codec = opts["codec"] == "h264" ? .h264 : .hevc
settings.quality = StreamQuality(rawValue: UInt8(opts["quality"] ?? "1") ?? 1) ?? .balanced
settings.maxFPS = UInt8(opts["fps"] ?? "30") ?? 30

var decoder: Decoder?
let dump: FileHandle? = opts["dump"].flatMap { path in
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}
func dumpMessage(_ m: ServerMessage) {
    guard let dump else { return }
    let d = m.encode()
    var len = UInt32(d.count).bigEndian
    dump.write(Data(bytes: &len, count: 4))
    dump.write(d)
}
var frames = 0, keyframes = 0, bytes = 0, maxFrame = 0, formats = 0
var connectedAt = Date()
var firstFrameMs = -1.0
var rtts = [Double]()
let started = Date()

let core = ClientCore(identity: identity, macID: macID, deviceName: "pmtest") { salt, iters in
    PMCrypto.passwordKey(password, salt: salt, iterations: iters)
}

func finishAndExit() {
    let dur = Date().timeIntervalSince(connectedAt)
    print(String(format: "RESULT frames=%d keyframes=%d formats=%d decoded=%d decodeErrors=%d avgKB=%.1f maxKB=%.1f kbps=%.0f firstFrameMs=%.0f",
                 frames, keyframes, formats, decoder?.decoded ?? 0, decoder?.errors ?? 0,
                 frames > 0 ? Double(bytes) / Double(frames) / 1024 : 0, Double(maxFrame) / 1024,
                 Double(bytes) * 8 / max(dur, 0.001) / 1000, firstFrameMs))
    if !rtts.isEmpty {
        let sorted = rtts.sorted()
        print(String(format: "PING n=%d min=%.2fms median=%.2fms max=%.2fms", sorted.count, sorted[0], sorted[sorted.count / 2], sorted.last!))
    }
    if let png = opts["png"] { print("PNG \(decoder?.savePNG(png) == true ? "saved \(png)" : "FAILED")") }
    let ok = frames > 0 && (decoder?.decoded ?? 0) > 0 && (decoder?.errors ?? 1) == 0
    exit(ok ? 0 : 3)
}

core.onState = { state in
    switch state {
    case .connecting: print("state: connecting")
    case .authenticating: print("state: authenticating")
    case .connected(let name):
        connectedAt = Date()
        print("CONNECTED to \(name) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        if expectFail != nil { print("UNEXPECTED SUCCESS"); exit(5) }
        core.send(.startStream(settings))
        for i in 0..<Int(seconds * 4) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(i)) { core.send(.ping(monotonicMicros())) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if opts["pause-before-close"] != nil {
                core.send(.setPaused(true))   // like the iPhone app going to the background
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { core.close() }
            } else {
                core.close()
            }
        }
    case .closed(let e):
        if let expectFail {
            if let f = e as? HandshakeFailure, "\(f.code)" == expectFail {
                print("EXPECTED FAILURE OK: \(f.code) — \(f)"); exit(0)
            }
            print("WRONG RESULT, expected \(expectFail), got: \(String(describing: e))"); exit(6)
        }
        if let e { print("CLOSED: \(e)") }
        DispatchQueue.main.async { finishAndExit() }
    }
}

core.onMessage = { m in
    switch m {
    case .videoFormat(let f):
        dumpMessage(m)
        formats += 1
        decoder = Decoder(f)
        print("FORMAT \(f.codec) \(f.width)x\(f.height) parameterSets=\(f.parameterSets.count) decoder=\(decoder != nil)")
    case .videoFrame(let f):
        dumpMessage(m)
        if frames == 0 { firstFrameMs = Date().timeIntervalSince(connectedAt) * 1000 }
        frames += 1
        bytes += f.data.count
        maxFrame = max(maxFrame, f.data.count)
        if f.keyframe { keyframes += 1 }
        core.send(.frameAck(f.frameID))
        decoder?.decode(f)
        if opts["verbose"] != nil { print("frame \(f.frameID) key=\(f.keyframe) \(f.data.count) B") }
    case .status(let s): print("STATUS \(s.hostName) battery=\(s.battery)% ac=\(s.onAC) lid=\(s.lidClosed) lidMode=\(s.lidMode) screenPerm=\(s.screenPermission) axPerm=\(s.accessibilityPermission)")
    case .pong(let t): rtts.append(Double(monotonicMicros() - t) / 1000)
    case .notice(let n): print("NOTICE \(n)")
    case .clipboard(let c): print("CLIPBOARD \(c.prefix(40))")
    case .cursor: break
    }
}

core.connect([.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)])
dispatchMain()
