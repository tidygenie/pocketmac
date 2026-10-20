import Foundation

let PocketMacPort: UInt16 = UInt16(ProcessInfo.processInfo.environment["POCKETMAC_PORT"] ?? "") ?? 47800
let PocketMacBonjourType = "_pocketmac._tcp"

enum VideoCodec: UInt8 { case h264 = 1, hevc = 2 }

enum StreamQuality: UInt8, CaseIterable {
    case saver = 0, balanced = 1, sharp = 2

    /// Max encoded width and max bitrate (bits/s). Static screens cost ~0 bytes
    /// regardless, because only changed frames are sent.
    var maxWidth: Int { [1280, 1920, 2940][Int(rawValue)] }
    var maxBitrate: Int { [3_000_000, 8_000_000, 16_000_000][Int(rawValue)] }
    var label: String { ["Battery saver", "Balanced", "Sharp"][Int(rawValue)] }
}

/// Shape of the virtual screen the Mac creates when its lid is closed.
enum LidDisplayFit: UInt8, CaseIterable {
    case phone = 0, phoneRoomy = 1, laptop = 2

    var label: String { ["Fit iPhone (big text)", "Fit iPhone (more space)", "Laptop size"][Int(rawValue)] }
}

struct StreamSettings: Equatable {
    var quality: StreamQuality = .balanced
    var maxFPS: UInt8 = 30
    var codec: VideoCodec = .hevc
    var clientPixelWidth: UInt16 = 2532   // iPhone 12 landscape
    var clientPixelHeight: UInt16 = 1170
    var lidFit: LidDisplayFit = .phone

    func encode(into w: inout WireWriter) {
        w.u8(quality.rawValue); w.u8(maxFPS); w.u8(codec.rawValue)
        w.u16(clientPixelWidth); w.u16(clientPixelHeight); w.u8(lidFit.rawValue)
    }

    static func decode(_ r: inout WireReader) throws -> StreamSettings {
        var s = StreamSettings()
        s.quality = StreamQuality(rawValue: try r.u8()) ?? .balanced
        s.maxFPS = min(max(try r.u8(), 5), 60)
        s.codec = VideoCodec(rawValue: try r.u8()) ?? .hevc
        s.clientPixelWidth = try r.u16()
        s.clientPixelHeight = try r.u16()
        s.lidFit = LidDisplayFit(rawValue: try r.u8()) ?? .phone
        return s
    }
}

enum QuickAction: UInt8, CaseIterable {
    case lockScreen = 1, sleepDisplay, missionControl, spotlight, appSwitcher, showDesktop
    case volumeUp, volumeDown, mute, playPause, nextTrack, previousTrack
    case screenshot, forceQuit, lidModeOn, lidModeOff, sleepMac, wakeDisplay
}

struct VideoFormat: Equatable {
    var codec: VideoCodec
    var width: UInt16
    var height: UInt16
    var parameterSets: [Data]
}

struct VideoFrame {
    var frameID: UInt32
    var keyframe: Bool
    var captureMicros: UInt64
    var data: Data   // AVCC / HVCC: 4-byte big-endian length-prefixed NAL units
}

struct HostStatus: Equatable {
    var hostName = ""
    var battery: Int8 = -1      // percent, -1 = unknown / desktop
    var charging = false
    var onAC = false
    var lidClosed = false
    var lidMode = false          // "stay awake with lid closed" active
    var lidHelperInstalled = false
    var screenPermission = false
    var accessibilityPermission = false
    var virtualDisplay = false

    func encode(into w: inout WireWriter) {
        w.string(hostName); w.i8(battery)
        var flags: UInt16 = 0
        let bits = [charging, onAC, lidClosed, lidMode, lidHelperInstalled, screenPermission, accessibilityPermission, virtualDisplay]
        for (i, b) in bits.enumerated() where b { flags |= 1 << UInt16(i) }
        w.u16(flags)
    }

    static func decode(_ r: inout WireReader) throws -> HostStatus {
        var s = HostStatus()
        s.hostName = try r.string()
        s.battery = try r.i8()
        let f = try r.u16()
        func bit(_ i: Int) -> Bool { f & (1 << UInt16(i)) != 0 }
        s.charging = bit(0); s.onAC = bit(1); s.lidClosed = bit(2); s.lidMode = bit(3)
        s.lidHelperInstalled = bit(4); s.screenPermission = bit(5); s.accessibilityPermission = bit(6)
        s.virtualDisplay = bit(7)
        return s
    }
}

// MARK: - iPhone → Mac

enum ClientMessage {
    case startStream(StreamSettings)
    case updateSettings(StreamSettings)
    case frameAck(UInt32)
    case requestKeyframe
    case setPaused(Bool)
    case mouseMove(x: Float, y: Float)
    case mouseButton(button: UInt8, down: Bool, x: Float, y: Float, clicks: UInt8, flags: UInt32)
    case scroll(dx: Float, dy: Float)
    case key(code: UInt16, down: Bool, flags: UInt32)
    case text(String)
    case action(QuickAction)
    case clipboard(String)
    case ping(UInt64)

    func encode() -> Data {
        var w = WireWriter()
        switch self {
        case .startStream(let s): w.u8(0x20); s.encode(into: &w)
        case .updateSettings(let s): w.u8(0x21); s.encode(into: &w)
        case .frameAck(let id): w.u8(0x22); w.u32(id)
        case .requestKeyframe: w.u8(0x23)
        case .setPaused(let p): w.u8(0x24); w.bool(p)
        case let .mouseMove(x, y): w.u8(0x30); w.f32(x); w.f32(y)
        case let .mouseButton(b, down, x, y, clicks, flags):
            w.u8(0x31); w.u8(b); w.bool(down); w.f32(x); w.f32(y); w.u8(clicks); w.u32(flags)
        case let .scroll(dx, dy): w.u8(0x32); w.f32(dx); w.f32(dy)
        case let .key(code, down, flags): w.u8(0x33); w.u16(code); w.bool(down); w.u32(flags)
        case .text(let t): w.u8(0x34); w.longString(t)
        case .action(let a): w.u8(0x35); w.u8(a.rawValue)
        case .clipboard(let t): w.u8(0x36); w.longString(t)
        case .ping(let t): w.u8(0x37); w.u64(t)
        }
        return w.data
    }

    static func decode(_ d: Data) throws -> ClientMessage {
        var r = WireReader(d)
        switch try r.u8() {
        case 0x20: return .startStream(try StreamSettings.decode(&r))
        case 0x21: return .updateSettings(try StreamSettings.decode(&r))
        case 0x22: return .frameAck(try r.u32())
        case 0x23: return .requestKeyframe
        case 0x24: return .setPaused(try r.bool())
        case 0x30: return .mouseMove(x: try r.f32(), y: try r.f32())
        case 0x31:
            return .mouseButton(button: try r.u8(), down: try r.bool(), x: try r.f32(), y: try r.f32(),
                                clicks: try r.u8(), flags: try r.u32())
        case 0x32: return .scroll(dx: try r.f32(), dy: try r.f32())
        case 0x33: return .key(code: try r.u16(), down: try r.bool(), flags: try r.u32())
        case 0x34: return .text(try r.longString())
        case 0x35:
            guard let a = QuickAction(rawValue: try r.u8()) else { throw WireError("unknown action") }
            return .action(a)
        case 0x36: return .clipboard(try r.longString())
        case 0x37: return .ping(try r.u64())
        case let t: throw WireError("unknown client message \(t)")
        }
    }
}

// MARK: - Mac → iPhone

enum ServerMessage {
    case videoFormat(VideoFormat)
    case videoFrame(VideoFrame)
    case status(HostStatus)
    case clipboard(String)
    case pong(UInt64)
    case cursor(x: Float, y: Float)
    case notice(String)

    func encode() -> Data {
        var w = WireWriter(capacity: 64)
        switch self {
        case .videoFormat(let f):
            w.u8(0x10); w.u8(f.codec.rawValue); w.u16(f.width); w.u16(f.height)
            w.u8(UInt8(f.parameterSets.count))
            for p in f.parameterSets { w.blob16(p) }
        case .videoFrame(let f):
            w = WireWriter(capacity: f.data.count + 16)
            w.u8(0x11); w.u32(f.frameID); w.bool(f.keyframe); w.u64(f.captureMicros); w.raw(f.data)
        case .status(let s): w.u8(0x12); s.encode(into: &w)
        case .clipboard(let t): w.u8(0x13); w.longString(t)
        case .pong(let t): w.u8(0x14); w.u64(t)
        case let .cursor(x, y): w.u8(0x15); w.f32(x); w.f32(y)
        case .notice(let t): w.u8(0x16); w.string(t)
        }
        return w.data
    }

    static func decode(_ d: Data) throws -> ServerMessage {
        var r = WireReader(d)
        switch try r.u8() {
        case 0x10:
            guard let codec = VideoCodec(rawValue: try r.u8()) else { throw WireError("bad codec") }
            let w = try r.u16(), h = try r.u16()
            let n = Int(try r.u8())
            var sets = [Data]()
            for _ in 0..<n { sets.append(try r.blob16()) }
            return .videoFormat(VideoFormat(codec: codec, width: w, height: h, parameterSets: sets))
        case 0x11:
            let id = try r.u32(), key = try r.bool(), t = try r.u64()
            return .videoFrame(VideoFrame(frameID: id, keyframe: key, captureMicros: t, data: r.rest()))
        case 0x12: return .status(try HostStatus.decode(&r))
        case 0x13: return .clipboard(try r.longString())
        case 0x14: return .pong(try r.u64())
        case 0x15: return .cursor(x: try r.f32(), y: try r.f32())
        case 0x16: return .notice(try r.string())
        case let t: throw WireError("unknown server message \(t)")
        }
    }
}

/// Monotonic microseconds (same clock on both ends is NOT assumed; only used for RTT on one side).
func monotonicMicros() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }
