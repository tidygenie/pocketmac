import Foundation
import Network
import AVFoundation
import UIKit

/// Hardware decode + display in one step (AVSampleBufferDisplayLayer): no pixel
/// copies on the CPU, which is what keeps the iPhone cool and the battery happy.
final class VideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    /// All renderer state lives on this queue (frames from an old and a new connection can overlap).
    private let queue = DispatchQueue(label: "pocketmac.render", qos: .userInteractive)
    private var format: VideoFormat?
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private var lastKeyRequest: UInt64 = 0
    var onNeedKeyframe: (() -> Void)?
    var onSize: ((CGSize) -> Void)?

    init() {
        layer.videoGravity = .resize
        layer.backgroundColor = UIColor.black.cgColor
        // A running clock so frames are shown the moment they're decoded.
        var tb: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                           timebaseOut: &tb) == noErr, let tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            layer.controlTimebase = tb
        }
    }

    func handle(_ f: VideoFormat) { queue.async { self.apply(f) } }
    func handle(_ frame: VideoFrame) { queue.async { self.enqueue(frame) } }

    private func apply(_ f: VideoFormat) {
        guard f != format else { return }
        format = f
        formatDescription = f.makeFormatDescription()
        waitingForKeyframe = true
        let size = CGSize(width: Int(f.width), height: Int(f.height))
        DispatchQueue.main.async { self.onSize?(size) }
    }

    private func enqueue(_ frame: VideoFrame) {
        let r = layer.sampleBufferRenderer
        if r.status == .failed {
            r.flush(removingDisplayedImage: false, completionHandler: nil)
            waitingForKeyframe = true
            askKeyframe()
        }
        if waitingForKeyframe && !frame.keyframe { askKeyframe(); return }
        guard let fd = formatDescription, let sb = frame.makeSampleBuffer(fd, displayImmediately: true) else {
            waitingForKeyframe = true
            askKeyframe()
            return
        }
        waitingForKeyframe = false
        r.enqueue(sb)
    }

    func reset() {
        queue.async {
            self.format = nil
            self.formatDescription = nil
            self.waitingForKeyframe = true
            self.layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        }
    }

    private func askKeyframe() {
        let now = monotonicMicros()
        guard now - lastKeyRequest > 500_000 else { return }
        lastKeyRequest = now
        onNeedKeyframe?()
    }
}

/// Hooks the SwiftUI toolbar can call into the UIKit remote view.
final class RemoteControls {
    var toggleKeyboard: (() -> Void)?
    var resetZoom: (() -> Void)?
}

final class RemoteSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting(String)
        case connected
        case needsPassword(String?)
        case failed(String)
    }

    let id = UUID()
    @Published private(set) var phase: Phase = .connecting("Connecting…")
    @Published private(set) var status: HostStatus?
    @Published var toast: String?
    @Published private(set) var fps = 0
    @Published private(set) var kbps = 0
    @Published private(set) var rttMs = -1
    @Published var passwordInput = ""
    @Published var rememberPassword = true
    @Published var toolbarOpen = true
    @Published var zoomed = false
    @Published var keyboardVisible = false
    @Published private(set) var lastMacClipboard: String?

    private(set) var mac: SavedMac
    let renderer = VideoRenderer()
    let controls = RemoteControls()
    var onCursor: ((CGPoint) -> Void)?

    private let store = AppStore.shared
    private var core: ClientCore?
    private var credential: MacCredential?
    private var password: String?
    private var wantsConnection = false
    private var suspended = false
    private var reconnectAttempt = 0
    private var everConnected = false
    private var timers: [Timer] = []
    private let counters = Counters()
    private var toastWork: DispatchWorkItem?

    init(mac: SavedMac) { self.mac = mac }

    var isConnected: Bool { phase == .connected }

    // MARK: Lifecycle

    /// `password` nil → use the Face ID-protected key if we have one, else ask.
    func start(password: String?) {
        if let password, !password.isEmpty {
            self.password = password
            connect()
            return
        }
        if credential != nil { connect(); return }
        guard store.hasCredential(for: mac.id) else { phase = .needsPassword(nil); return }
        phase = .connecting("Unlocking…")
        let id = mac.id
        DispatchQueue.global(qos: .userInitiated).async {
            let c = self.store.loadCredential(for: id)   // shows Face ID
            DispatchQueue.main.async {
                if let c { self.credential = c; self.connect() } else { self.phase = .needsPassword(nil) }
            }
        }
    }

    func submitPassword() {
        let pw = passwordInput
        passwordInput = ""
        guard !pw.isEmpty else { return }
        credential = nil
        start(password: pw)
    }

    func retry() { connect() }

    func disconnect() {
        wantsConnection = false
        stopTimers()
        core?.close()
        core = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// App went to background: iOS will freeze us anyway, so close cleanly.
    func suspend() {
        guard wantsConnection, isConnected else { return }
        suspended = true
        core?.send(.setPaused(true))
        stopTimers()
        let c = core
        core = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { c?.close() }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        connect(quiet: true)
    }

    private func connect(quiet: Bool = false) {
        core?.close()
        wantsConnection = true
        if !quiet || !everConnected { phase = .connecting("Connecting to \(mac.name)…") }
        renderer.reset()

        let cred = credential, pw = password
        let core = ClientCore(identity: store.identity, macID: mac.id, deviceName: store.deviceName) { salt, iters in
            if let cred, cred.salt == salt, cred.iterations == iters { return cred.key }
            if let pw { return PMCrypto.passwordKey(pw, salt: salt, iterations: iters) }
            return nil
        }
        self.core = core
        core.onState = { [weak self, weak core] st in
            DispatchQueue.main.async {
                guard let self, let core, core === self.core else { return }
                self.handle(st)
            }
        }
        core.onAuthenticated = { [weak self] info, key in
            DispatchQueue.main.async { self?.authenticated(info, key: key) }
        }
        core.onMessage = { [weak self, weak core] m in
            guard let self, let core else { return }
            self.received(m, core: core)
        }
        renderer.onNeedKeyframe = { [weak core] in core?.send(.requestKeyframe) }

        // Race every path we know: Bonjour/peer-to-peer (nearby) + internet address (Tailscale).
        var endpoints = [NWEndpoint]()
        let discovery = Discovery.shared
        if let f = discovery.found[mac.id] { endpoints.append(f.endpoint) }
        let addr = mac.internetAddress.trimmingCharacters(in: .whitespaces)
        if !addr.isEmpty, let port = NWEndpoint.Port(rawValue: mac.port) {
            endpoints.append(.hostPort(host: NWEndpoint.Host(addr), port: port))
        }
        let waitForBonjour = discovery.found[mac.id] == nil
        core.connect(endpoints, moreComing: waitForBonjour)
        if waitForBonjour {
            discovery.start()
            var tries = 0
            let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak core] t in
                tries += 1
                guard let self, let core, core === self.core else { t.invalidate(); return }
                if let f = discovery.found[self.mac.id] {
                    core.addEndpoint(f.endpoint)
                    core.noMoreEndpoints()
                    t.invalidate()
                } else if tries >= 14 {
                    core.noMoreEndpoints()
                    t.invalidate()
                }
            }
            timers.append(t)
        }
    }

    private func handle(_ st: ClientCore.State) {
        switch st {
        case .connecting:
            if !everConnected || phase != .connected { phase = .connecting("Connecting to \(mac.name)…") }
        case .authenticating:
            if phase != .connected { phase = .connecting("Logging in…") }
        case .connected:
            phase = .connected
            everConnected = true
            reconnectAttempt = 0
            core?.send(.startStream(store.settings.streamSettings()))
            startTimers()
            UIApplication.shared.isIdleTimerDisabled = store.settings.keepScreenOn
        case .closed(let e):
            stopTimers()
            guard wantsConnection, !suspended else { return }
            if let f = e as? HandshakeFailure {
                wantsConnection = false
                switch f.code {
                case .badCredentials:
                    if password == nil, credential != nil {
                        credential = nil
                        store.deleteCredential(for: mac.id)
                        phase = .needsPassword("The saved login no longer works (password changed?). Enter the Mac password.")
                    } else {
                        password = nil
                        phase = .needsPassword(f.message == "Password needed." ? nil : "Wrong password. Try again.")
                    }
                default:
                    phase = .failed(f.description)
                }
                return
            }
            // Network drop (Wi-Fi ↔ cellular, tunnel, Mac asleep…): retry with backoff.
            if everConnected && reconnectAttempt < 6 {
                reconnectAttempt += 1
                let delay = min(8.0, pow(2.0, Double(reconnectAttempt - 1)) * 0.5)
                phase = .connecting("Connection lost — reconnecting…")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.wantsConnection, !self.suspended, self.phase != .connected else { return }
                    self.connect(quiet: true)
                }
            } else {
                wantsConnection = false
                phase = .failed(Self.friendly(e))
            }
        }
    }

    private func authenticated(_ info: ClientHandshake.ServerHelloInfo, key: Data) {
        let c = MacCredential(salt: info.salt, iterations: info.iterations, key: key)
        credential = c
        if password != nil, rememberPassword {
            let id = mac.id
            DispatchQueue.global(qos: .utility).async { self.store.saveCredential(c, for: id) }
        }
        password = nil
        mac.name = info.hostName
        mac.lastConnected = Date()
        store.upsert(mac)
    }

    // MARK: Messages (network queue)

    private func received(_ m: ServerMessage, core: ClientCore) {
        switch m {
        case .videoFormat(let f):
            renderer.handle(f)
        case .videoFrame(let f):
            core.send(.frameAck(f.frameID))
            renderer.handle(f)
            counters.add(bytes: f.data.count)
        case .status(let s):
            DispatchQueue.main.async { self.status = s }
        case .clipboard(let text):
            DispatchQueue.main.async {
                self.lastMacClipboard = text
                if self.store.settings.clipboardSync {
                    UIPasteboard.general.string = text
                    self.showToast("Copied from Mac")
                }
            }
        case .pong(let t):
            let ms = Int((monotonicMicros() - t) / 1000)
            DispatchQueue.main.async { self.rttMs = ms }
        case let .cursor(x, y):
            DispatchQueue.main.async { self.onCursor?(CGPoint(x: CGFloat(x), y: CGFloat(y))) }
        case .notice(let n):
            DispatchQueue.main.async { self.showToast(n, seconds: 6) }
        }
    }

    func send(_ m: ClientMessage) { core?.send(m) }

    static func friendly(_ e: Error?) -> String {
        guard let e else { return "Disconnected." }
        if let w = e as? WireError { return w.description }
        if let nw = e as? NWError, case let .posix(code) = nw {
            switch code {
            case .ECONNREFUSED: return "The Mac refused the connection. Is PocketMac Host running on it?"
            case .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN:
                return "Couldn't reach the Mac. Check that it's awake, and that both devices are on the same Wi-Fi or both have Tailscale on."
            case .ECONNRESET: return "The connection was reset."
            default: break
            }
        }
        if let nw = e as? NWError, case .dns = nw { return "Couldn't find that internet address. Check the Tailscale name or IP." }
        return "\(e)"
    }

    func updateStream() {
        guard isConnected else { return }
        core?.send(.updateSettings(store.settings.streamSettings()))
    }

    func sendClipboardToMac(andPaste: Bool) -> Bool {
        guard let s = UIPasteboard.general.string, !s.isEmpty else { showToast("iPhone clipboard is empty"); return false }
        send(.clipboard(s))
        showToast(andPaste ? "Pasted on Mac" : "Sent to Mac clipboard")
        return true
    }

    func showToast(_ s: String, seconds: Double = 2.2) {
        toast = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    // MARK: Stats

    private func startTimers() {
        stopTimers()
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let (frames, bytes) = self.counters.take()
            self.fps = frames
            self.kbps = bytes * 8 / 1000
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.core?.send(.ping(monotonicMicros()))
        })
        core?.send(.ping(monotonicMicros()))
    }

    private func stopTimers() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }
}

private final class Counters {
    private let lock = NSLock()
    private var frames = 0, bytes = 0
    func add(bytes b: Int) { lock.lock(); frames += 1; bytes += b; lock.unlock() }
    func take() -> (Int, Int) { lock.lock(); defer { frames = 0; bytes = 0; lock.unlock() }; return (frames, bytes) }
}
