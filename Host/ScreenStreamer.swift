import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

/// Captures the main display, encodes in hardware and paces frames to what the
/// network can carry.
///
/// Battery / bandwidth design:
///  * ScreenCaptureKit only delivers a frame when something on screen changed,
///    so a static screen costs ~0 CPU, ~0 GPU and 0 bytes.
///  * At most `maxInFlight` frames are un-acknowledged; newer frames replace the
///    queued one instead of piling up (no latency build-up on slow links).
///  * Bitrate adapts to measured queueing delay (AIMD).
///  * After motion stops, the last frame is re-encoded up to 3 times so text
///    sharpens even on a low bitrate.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "pocketmac.capture", qos: .userInteractive)

    /// Called on `queue` with messages for the phone.
    var sink: ((ServerMessage) -> Void)?
    /// Called on `queue` when the captured display changes (for input mapping).
    var onDisplay: ((CGDirectDisplayID) -> Void)?

    private var settings = StreamSettings()
    private var running = false
    private var paused = false
    private var stream: SCStream?
    private var captureGeneration = 0
    private var testPattern: TestPatternSource?
    private var warnedNoPermission = false
    private(set) var displayID: CGDirectDisplayID = CGMainDisplayID()

    private var encoder: VideoEncoder?
    private var forceKeyframe = true
    private var lastSentFormat: VideoFormat?

    private var nextFrameID: UInt32 = 1
    private var inFlight: [UInt32: UInt64] = [:]
    private var encoding = 0
    private var pending: CVPixelBuffer?
    private var lastBuffer: CVPixelBuffer?
    private var refinePasses = 0
    private var refineWork: DispatchWorkItem?

    private var bitrate = 4_000_000
    private var srttMs: Double = 0
    private var minRttMs: Double = .greatestFiniteMagnitude
    private var minRttResetAt = monotonicMicros()
    private var lastRateCheck = monotonicMicros()
    private var replacedSinceCheck = 0
    private var sentSinceCheck = 0

    // Stats (read on queue)
    private(set) var framesSent = 0
    private(set) var bytesSent = 0

    static var useTestPattern: Bool { ProcessInfo.processInfo.environment["POCKETMAC_TEST_PATTERN"] != nil }

    // MARK: Control (thread-safe)

    func start(_ s: StreamSettings) {
        queue.async {
            self.settings = s
            self.running = true
            self.paused = false
            self.bitrate = min(s.quality.maxBitrate, max(2_000_000, s.quality.maxBitrate / 2))
            self.resetFlow()
            self.startCapture()
        }
    }

    func update(_ s: StreamSettings) {
        queue.async {
            let needRestart = s.quality != self.settings.quality || s.maxFPS != self.settings.maxFPS
                || s.codec != self.settings.codec
            self.settings = s
            self.bitrate = min(self.bitrate, s.quality.maxBitrate)
            if needRestart && self.running { self.resetFlow(); self.startCapture() }
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.stopCapture()
            self.encoder = nil
            self.resetFlow()
        }
    }

    func setPaused(_ p: Bool) {
        queue.async {
            self.paused = p
            if !p { self.forceKeyframe = true; self.pending = self.lastBuffer; self.pump() }
        }
    }

    func requestKeyframe() {
        queue.async {
            self.forceKeyframe = true
            self.inFlight.removeAll()
            if let b = self.lastBuffer, self.pending == nil { self.pending = b }
            self.pump()
        }
    }

    func ack(_ id: UInt32) {
        queue.async {
            guard let sent = self.inFlight.removeValue(forKey: id) else { return }
            // TCP is ordered, so anything older was received too.
            for k in self.inFlight.keys where k < id { self.inFlight.removeValue(forKey: k) }
            let rtt = Double(monotonicMicros() - sent) / 1000
            self.srttMs = self.srttMs == 0 ? rtt : self.srttMs * 0.85 + rtt * 0.15
            self.minRttMs = min(self.minRttMs, rtt)
            self.adaptRate()
            self.pump()
        }
    }

    /// Display configuration changed (lid closed/opened, virtual display added…).
    func displaysChanged() {
        queue.asyncAfter(deadline: .now() + 0.7) {
            guard self.running, !Self.useTestPattern else { return }
            if CGMainDisplayID() != self.displayID || self.stream == nil { self.startCapture() }
        }
    }

    var statsLine: String {
        queue.sync { "\(framesSent) frames, \(bytesSent / 1024) KB, bitrate \(bitrate / 1000) kbps, rtt \(Int(srttMs)) ms" }
    }

    // MARK: Capture

    private func resetFlow() {
        inFlight.removeAll()
        encoding = 0
        pending = nil
        lastBuffer = nil
        refineWork?.cancel()
        refinePasses = 0
        forceKeyframe = true
        lastSentFormat = nil
        srttMs = 0
        minRttMs = .greatestFiniteMagnitude
    }

    private func stopCapture() {
        captureGeneration += 1
        testPattern?.stop()
        testPattern = nil
        if let s = stream {
            stream = nil
            s.stopCapture { _ in }
        }
    }

    private func startCapture() {
        stopCapture()
        let gen = captureGeneration
        let s = settings
        if Self.useTestPattern {
            let tp = TestPatternSource(width: 1920, height: 1200, fps: Int(s.maxFPS), queue: queue) { [weak self] pb in
                self?.handle(pb)
            }
            testPattern = tp
            tp.start()
            return
        }
        // Without permission, asking ScreenCaptureKit makes macOS show its "record this
        // screen" pop-up every time. Check silently first and wait for permission instead.
        guard CGPreflightScreenCaptureAccess() else {
            if !warnedNoPermission {
                warnedNoPermission = true
                sink?(.notice("Screen Recording is off for PocketMac Host. On the Mac: System Settings → Privacy & Security → Screen Recording → turn PocketMac Host on, then reopen it."))
            }
            queue.asyncAfter(deadline: .now() + 3) {
                if gen == self.captureGeneration, self.running { self.startCapture() }
            }
            return
        }
        warnedNoPermission = false
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let main = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
                    throw WireError("No display to capture")
                }
                let (w, h) = Self.outputSize(display: display.displayID, maxWidth: s.quality.maxWidth)
                let cfg = SCStreamConfiguration()
                cfg.width = w
                cfg.height = h
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(s.maxFPS))
                cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
                cfg.colorSpaceName = CGColorSpace.sRGB
                cfg.showsCursor = true
                cfg.queueDepth = 6
                cfg.capturesAudio = false
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                self.queue.async {
                    guard gen == self.captureGeneration, self.running else { stream.stopCapture { _ in }; return }
                    self.stream = stream
                    self.displayID = display.displayID
                    self.forceKeyframe = true
                    self.onDisplay?(display.displayID)
                    NSLog("PocketMac: capturing display \(display.displayID) at \(w)x\(h) @\(s.maxFPS)fps")
                }
            } catch {
                NSLog("PocketMac: capture failed: \(error)")
                self.queue.async {
                    guard gen == self.captureGeneration, self.running else { return }
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        if gen == self.captureGeneration, self.running { self.startCapture() }
                    }
                }
            }
        }
    }

    static func outputSize(display: CGDirectDisplayID, maxWidth: Int) -> (Int, Int) {
        var pw = 0, ph = 0
        if let mode = CGDisplayCopyDisplayMode(display) {
            pw = mode.pixelWidth; ph = mode.pixelHeight
        }
        if pw == 0 || ph == 0 {
            let b = CGDisplayBounds(display)
            pw = Int(b.width * 2); ph = Int(b.height * 2)
        }
        let scale = min(1.0, Double(maxWidth) / Double(pw))
        let w = max(320, Int(Double(pw) * scale)) & ~1
        let h = max(200, Int(Double(ph) * scale)) & ~1
        return (w, h)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        handle(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("PocketMac: stream stopped: \(error)")
        queue.async {
            guard stream === self.stream else { return }
            self.stream = nil
            let gen = self.captureGeneration
            self.queue.asyncAfter(deadline: .now() + 1) {
                if self.running, gen == self.captureGeneration { self.startCapture() }
            }
        }
    }

    // MARK: Encode + pacing (all on queue)

    private var maxInFlight: Int {
        let frameMs = 1000.0 / Double(max(settings.maxFPS, 1))
        guard minRttMs < 5_000 else { return 2 }   // no RTT sample yet
        return max(2, min(8, Int(minRttMs / frameMs) + 2))
    }

    private var canEncode: Bool { encoding == 0 && inFlight.count < maxInFlight }

    private func handle(_ pb: CVPixelBuffer) {
        guard running else { return }
        refineWork?.cancel()
        refinePasses = 0
        lastBuffer = pb
        guard !paused else { return }
        if canEncode {
            encode(pb)
        } else {
            if pending != nil { replacedSinceCheck += 1 }
            pending = pb
        }
    }

    private func pump() {
        guard running, !paused, canEncode, let p = pending else { return }
        pending = nil
        encode(p)
    }

    private func ensureEncoder(for pb: CVPixelBuffer) -> VideoEncoder? {
        let w = Int32(CVPixelBufferGetWidth(pb)), h = Int32(CVPixelBufferGetHeight(pb))
        if let e = encoder, e.width == w, e.height == h, e.codec == settings.codec { return e }
        encoder = VideoEncoder(width: w, height: h, codec: settings.codec, fps: Int(settings.maxFPS), bitrate: bitrate)
        if encoder == nil, settings.codec == .hevc {
            settings.codec = .h264
            encoder = VideoEncoder(width: w, height: h, codec: .h264, fps: Int(settings.maxFPS), bitrate: bitrate)
        }
        if let e = encoder { NSLog("PocketMac: encoder \(e.codec) \(w)x\(h) lowLatency=\(e.lowLatency)") }
        forceKeyframe = true
        return encoder
    }

    private func encode(_ pb: CVPixelBuffer) {
        guard let enc = ensureEncoder(for: pb) else { return }
        encoding += 1
        let key = forceKeyframe
        forceKeyframe = false
        let gen = captureGeneration
        enc.encode(pb, forceKeyframe: key) { [weak self] out in
            self?.queue.async { self?.encoded(out, generation: gen, wantedKey: key) }
        }
    }

    private var encodeFailures = 0

    private func encoded(_ out: EncodedFrame?, generation: Int, wantedKey: Bool) {
        encoding = max(0, encoding - 1)
        guard running, generation == captureGeneration else { return }
        guard let out else {
            if wantedKey { forceKeyframe = true }
            encodeFailures += 1
            if encodeFailures >= 3 {
                // e.g. the hardware encoder was reset by sleep/wake: build a fresh one.
                NSLog("PocketMac: encoder failing, recreating it")
                encoder = nil
                encodeFailures = 0
                forceKeyframe = true
                if pending == nil { pending = lastBuffer }
            }
            pump(); return
        }
        encodeFailures = 0
        if out.keyframe, let fmt = out.format, fmt != lastSentFormat {
            sink?(.videoFormat(fmt))
            lastSentFormat = fmt
        }
        guard lastSentFormat != nil else { forceKeyframe = true; pump(); return }
        let id = nextFrameID
        nextFrameID &+= 1
        inFlight[id] = monotonicMicros()
        sink?(.videoFrame(VideoFrame(frameID: id, keyframe: out.keyframe, captureMicros: monotonicMicros(), data: out.data)))
        framesSent += 1
        bytesSent += out.data.count
        sentSinceCheck += 1
        if pending != nil { pump() } else { scheduleRefine() }
    }

    private func scheduleRefine() {
        refineWork?.cancel()
        guard refinePasses < 3, lastBuffer != nil else { return }
        let delay = [0.12, 0.3, 0.7][refinePasses]
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, !self.paused, self.pending == nil, let b = self.lastBuffer else { return }
            if self.canEncode {
                self.refinePasses += 1
                self.encode(b)
            } else {
                self.scheduleRefine()
            }
        }
        refineWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func adaptRate() {
        let now = monotonicMicros()
        guard now - lastRateCheck > 700_000 else { return }
        lastRateCheck = now
        if now - minRttResetAt > 15_000_000, srttMs > 0 {
            // Let the baseline follow route changes (e.g. Wi-Fi → cellular).
            minRttMs = srttMs
            minRttResetAt = now
        }
        let queueDelay = srttMs - minRttMs
        let maxRate = settings.quality.maxBitrate
        var newRate = bitrate
        if queueDelay > 120 || (replacedSinceCheck > sentSinceCheck && queueDelay > 50) {
            newRate = max(400_000, Int(Double(bitrate) * 0.75))
        } else if queueDelay < 35 {
            newRate = min(maxRate, Int(Double(bitrate) * 1.12))
        }
        replacedSinceCheck = 0
        sentSinceCheck = 0
        if newRate != bitrate {
            bitrate = newRate
            encoder?.setBitrate(newRate)
        }
    }
}

/// Synthetic moving picture for testing the pipeline without Screen Recording permission.
final class TestPatternSource {
    private let width: Int, height: Int, fps: Int
    private let queue: DispatchQueue
    private let output: (CVPixelBuffer) -> Void
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var tick = 0

    init(width: Int, height: Int, fps: Int, queue: DispatchQueue, output: @escaping (CVPixelBuffer) -> Void) {
        self.width = width; self.height = height; self.fps = fps; self.queue = queue; self.output = output
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in self?.frame() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func frame() {
        tick += 1
        // 2 s of motion, then 2 s still (like real desktop use) — still periods send nothing.
        let phase = (tick / (fps * 2)) % 2
        if phase == 1 && tick % (fps * 2) != 0 { return }
        guard let pool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0.08, green: 0.1, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for i in 0..<12 {
            ctx.setFillColor(CGColor(red: CGFloat(i) / 12, green: 0.5, blue: 1 - CGFloat(i) / 12, alpha: 1))
            ctx.fill(CGRect(x: i * width / 12, y: 0, width: width / 12, height: 60))
        }
        let x = CGFloat((tick * 9) % (width - 200))
        ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: x, y: CGFloat(height / 2 - 100), width: 200, height: 200))
        CVPixelBufferUnlockBaseAddress(pb, [])
        output(pb)
    }
}
