import Foundation
import Network
import AppKit

/// Listens on TCP 47800 (all interfaces: Wi-Fi, AWDL peer-to-peer, Tailscale) and
/// advertises itself over Bonjour. Exactly one authenticated iPhone session at a time.
final class HostServer {
    static let shared = HostServer()

    let queue = DispatchQueue(label: "pocketmac.server", qos: .userInteractive)
    let streamer = ScreenStreamer()
    let input = InputInjector()

    /// Main-thread callback: connected device name (nil = nobody) and listener state text.
    var onChange: (() -> Void)?
    private(set) var connectedDevice: String?
    private(set) var connectedAddress: String?
    private(set) var listenerState = "Starting…"

    private var listener: NWListener?
    private var active: HostSession?
    private var handshaking: [HostSession] = []
    private var failures = 0
    private var lockedUntil = Date.distantPast
    private var statusTimer: DispatchSourceTimer?
    private var lastStatus: HostStatus?
    private var lastClipboardCount = -1
    private var lastCursor: (Float, Float) = (-1, -1)

    private init() {
        streamer.sink = { [weak self] msg in
            let d = msg.encode()
            self?.queue.async { self?.active?.channel.send(d) }
        }
        streamer.onDisplay = { [weak self] id in self?.queue.async { self?.input.displayID = id } }
    }

    func start() {
        queue.async { self.startListener() }
    }

    private func startListener() {
        listener?.cancel()
        do {
            let params = PMNet.parameters()
            params.allowLocalEndpointReuse = true
            let loopbackOnly = ProcessInfo.processInfo.environment["POCKETMAC_LOOPBACK"] != nil
            let l: NWListener
            if loopbackOnly {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: PocketMacPort)!)
                l = try NWListener(using: params)
            } else {
                l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: PocketMacPort)!)
                let txt = NWTXTRecord(["id": HostConfig.shared.deviceID, "v": "1"])
                l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: PocketMacBonjourType,
                                               domain: nil, txtRecord: txt)
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.setListenerState("Listening on port \(PocketMacPort)")
                case .failed(let e):
                    self.setListenerState("Network error: \(e). Retrying…")
                    self.queue.asyncAfter(deadline: .now() + 3) { self.startListener() }
                case .waiting(let e): self.setListenerState("Waiting for network (\(e))")
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            setListenerState("Can't listen on port \(PocketMacPort): \(error)")
            queue.asyncAfter(deadline: .now() + 5) { self.startListener() }
        }
    }

    private func setListenerState(_ s: String) {
        if s != listenerState { NSLog("PocketMac: \(s)") }
        listenerState = s
        notifyUI()
    }

    private func notifyUI() {
        let cb = onChange
        DispatchQueue.main.async { cb?() }
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        guard handshaking.count < 4 else { c.cancel(); return }
        let s = HostSession(connection: c, server: self)
        handshaking.append(s)
        s.start()
        queue.asyncAfter(deadline: .now() + 12) { [weak s] in
            guard let s, !s.authenticated else { return }
            s.close()
        }
    }

    func sessionClosed(_ s: HostSession) {
        handshaking.removeAll { $0 === s }
        if active === s {
            active = nil
            streamer.stop()
            input.releaseAll()
            stopStatusTimer()
            connectedDevice = nil
            connectedAddress = nil
            DispatchQueue.main.async { SystemControl.holdAwake(false) }
            NSLog("PocketMac: session ended")
            notifyUI()
        }
    }

    /// Kick a revoked device off immediately.
    func disconnect(devicePublicKey: Data) {
        queue.async {
            if self.active?.deviceKey == devicePublicKey { self.active?.close() }
        }
    }

    func disconnectAll() { queue.async { self.active?.close() } }

    // MARK: Handshake policy (called on queue)

    enum HelloDecision { case proceed(paired: Bool), reject(Data) }

    func decideHello(deviceKey: Data) -> HelloDecision {
        let cfg = HostConfig.shared
        guard cfg.hasPassword else { return .reject(Handshake.errorMessage(.notConfigured)) }
        let now = Date()
        if lockedUntil > now {
            return .reject(Handshake.errorMessage(.lockedOut, retryAfter: UInt32(lockedUntil.timeIntervalSince(now)) + 1))
        }
        let paired = cfg.isPaired(deviceKey)
        if !paired && !cfg.isPairingOpen { return .reject(Handshake.errorMessage(.notAuthorized)) }
        return .proceed(paired: paired)
    }

    func recordFailure() -> Data {
        failures += 1
        if failures >= 5 {
            let secs = min(3600.0, 30 * pow(2, Double(failures - 5)))
            lockedUntil = Date().addingTimeInterval(secs)
            return Handshake.errorMessage(.lockedOut, retryAfter: UInt32(secs))
        }
        return Handshake.errorMessage(.badCredentials)
    }

    func authenticated(_ s: HostSession, paired: Bool) {
        failures = 0
        if paired {
            HostConfig.shared.touchDevice(publicKey: s.deviceKey, name: s.deviceName)
        } else {
            HostConfig.shared.addDevice(publicKey: s.deviceKey, name: s.deviceName)
        }
        handshaking.removeAll { $0 === s }
        if let old = active, old !== s {
            active = nil
            old.close()          // phone reconnected (e.g. Wi-Fi → cellular): replace the old session
            streamer.stop()
        }
        active = s
        connectedDevice = s.deviceName
        connectedAddress = s.channel.framed.remoteDescription
        DispatchQueue.main.async { SystemControl.holdAwake(true) }
        NSLog("PocketMac: \(s.deviceName) connected from \(connectedAddress ?? "?")")
        startStatusTimer()
        notifyUI()
    }

    // MARK: Session messages

    func handle(_ m: ClientMessage, from s: HostSession) {
        guard s === active else { return }
        switch m {
        case .startStream(let st), .updateSettings(let st):
            DispatchQueue.main.async {
                let vd = VirtualDisplayManager.shared
                vd.fit = st.lidFit
                vd.clientPixels = (Int(st.clientPixelWidth), Int(st.clientPixelHeight))
                if vd.isActive { vd.evaluate() }
            }
            if case .startStream = m { streamer.start(st) } else { streamer.update(st) }
            sendStatus(force: true)
        case .frameAck(let id): streamer.ack(id)
        case .requestKeyframe: streamer.requestKeyframe()
        case .setPaused(let p): streamer.setPaused(p)
        case let .mouseMove(x, y): input.move(x: x, y: y)
        case let .mouseButton(b, down, x, y, clicks, flags):
            input.button(b, down: down, x: x, y: y, clicks: clicks, flags: flags)
        case let .scroll(dx, dy): input.scroll(dx: dx, dy: dy)
        case let .key(code, down, flags): input.key(code, down: down, flags: flags)
        case .text(let t): input.type(t)
        case .action(let a):
            slowQueue.async {
                let note = SystemControl.perform(a, input: self.input)
                self.queue.async {
                    if let note { s.send(.notice(note)) }
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.sendStatus(force: true) }
                }
            }
        case .clipboard(let t):
            SystemControl.setClipboard(t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let n = SystemControl.clipboardChangeCount
                self.queue.async { self.lastClipboardCount = n }  // don't echo it back
            }
        case .ping(let t): s.send(.pong(t))
        }
        if !InputInjector.hasPermission, m.isInput { warnAccessibilityOnce(s) }
    }

    private var warnedAccessibility = false
    private func warnAccessibilityOnce(_ s: HostSession) {
        guard !warnedAccessibility else { return }
        warnedAccessibility = true
        s.send(.notice("Touch control is blocked: allow PocketMac Host in System Settings → Privacy & Security → Accessibility on the Mac."))
    }

    // MARK: Periodic status, cursor, clipboard (only while connected)

    private func startStatusTimer() {
        stopStatusTimer()
        lastStatus = nil
        lastClipboardCount = SystemControl.clipboardChangeCount
        let t = DispatchSource.makeTimerSource(queue: queue)
        var ticks = 0
        t.schedule(deadline: .now() + 0.1, repeating: 1.0 / 15)
        t.setEventHandler { [weak self] in
            guard let self, let s = self.active else { return }
            ticks += 1
            if let (x, y) = self.input.cursorPosition(), abs(x - self.lastCursor.0) + abs(y - self.lastCursor.1) > 0.0005 {
                self.lastCursor = (x, y)
                s.send(.cursor(x: x, y: y))
            }
            if ticks % 15 == 0 { self.checkClipboard(s) }
            if ticks % 75 == 0 { self.sendStatus(force: false) }
        }
        t.resume()
        statusTimer = t
    }

    private func stopStatusTimer() { statusTimer?.cancel(); statusTimer = nil }

    private func checkClipboard(_ s: HostSession) {
        DispatchQueue.main.async {
            let n = SystemControl.clipboardChangeCount
            let text = SystemControl.clipboardText()
            self.queue.async {
                guard n != self.lastClipboardCount else { return }
                self.lastClipboardCount = n
                if let text, !text.isEmpty, text.utf8.count < 1_000_000 { s.send(.clipboard(text)) }
            }
        }
    }

    func currentStatus() -> HostStatus {
        let p = SystemControl.power()
        var st = HostStatus()
        st.hostName = Host.current().localizedName ?? "Mac"
        st.battery = Int8(clamping: p.percent)
        st.charging = p.charging
        st.onAC = p.onAC
        st.lidClosed = SystemControl.lidClosed()
        st.lidMode = SystemControl.sleepDisabled()
        st.lidHelperInstalled = SystemControl.helperInstalled
        st.screenPermission = CGPreflightScreenCaptureAccess() || ScreenStreamer.useTestPattern
        st.accessibilityPermission = InputInjector.hasPermission
        st.virtualDisplay = streamer.displayID == VirtualDisplayManager.shared.displayID
        return st
    }

    /// Status reads spawn `pmset`, so they run on a utility queue, never on the input path.
    private let slowQueue = DispatchQueue(label: "pocketmac.slow", qos: .utility)

    private func sendStatus(force: Bool) {
        guard active != nil else { return }
        slowQueue.async {
            let st = self.currentStatus()
            self.queue.async {
                guard let s = self.active else { return }
                if force || st != self.lastStatus {
                    self.lastStatus = st
                    s.send(.status(st))
                }
            }
            self.batteryGuard(st)
        }
    }

    /// Lid-closed mode on battery: turn it off before the battery is flat, so the Mac can sleep safely.
    private func batteryGuard(_ st: HostStatus) {
        guard st.lidMode, !st.onAC, st.battery >= 0, Int(st.battery) <= HostConfig.shared.batteryGuardPercent,
              SystemControl.helperInstalled else { return }
        queue.async { self.active?.send(.notice("Mac battery is at \(st.battery)%. Turning off lid-closed mode so the Mac can sleep.")) }
        HostConfig.shared.lidModeWanted = false
        SystemControl.setLidMode(false, allowPrompt: false)
    }
}

private extension ClientMessage {
    var isInput: Bool {
        switch self {
        case .mouseMove, .mouseButton, .scroll, .key, .text: return true
        default: return false
        }
    }
}

/// One TCP connection from an iPhone.
final class HostSession {
    let channel: SecureChannel
    private unowned let server: HostServer
    private let handshake = ServerHandshake(staticKey: HostConfig.shared.staticKey)
    private(set) var authenticated = false
    private var stage = 0
    private var paired = false
    var deviceKey: Data { handshake.clientStatic }
    var deviceName: String { handshake.clientName.isEmpty ? "iPhone" : handshake.clientName }

    init(connection: NWConnection, server: HostServer) {
        self.server = server
        channel = SecureChannel(FramedConnection(connection, queue: server.queue))
    }

    func start() {
        channel.onMessage = { [weak self] d in self?.received(d) }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.server.sessionClosed(self)
        }
        channel.framed.start()
    }

    func send(_ m: ServerMessage) { channel.send(m.encode()) }

    func close() { channel.close() }

    private func received(_ d: Data) {
        if authenticated {
            guard let m = try? ClientMessage.decode(d) else { return }
            server.handle(m, from: self)
            return
        }
        do {
            switch stage {
            case 0:
                try handshake.parseClientHello(d)
                switch server.decideHello(deviceKey: handshake.clientStatic) {
                case .reject(let msg):
                    channel.sendPlain(msg)
                    closeSoon()
                case .proceed(let p):
                    paired = p
                    let cfg = HostConfig.shared
                    channel.sendPlain(handshake.serverHello(salt: cfg.salt, iterations: cfg.iterations,
                                                            hostName: Host.current().localizedName ?? "Mac",
                                                            alreadyPaired: p))
                    stage = 1
                }
            case 1:
                guard let pk = HostConfig.shared.passwordKey else { channel.sendPlain(Handshake.errorMessage(.notConfigured)); closeSoon(); return }
                if let (finish, keys) = try handshake.verifyClientFinish(d, passwordKey: pk) {
                    channel.sendPlain(finish)
                    channel.activate(keys, isServer: true)
                    authenticated = true
                    stage = 2
                    server.authenticated(self, paired: paired)
                } else {
                    channel.sendPlain(server.recordFailure())
                    closeSoon()
                }
            default: break
            }
        } catch let f as HandshakeFailure {
            channel.sendPlain(Handshake.errorMessage(f.code))
            closeSoon()
        } catch {
            channel.sendPlain(Handshake.errorMessage(.protocolError))
            closeSoon()
        }
    }

    /// Give the error message a moment to flush before closing.
    private func closeSoon() {
        stage = 99
        server.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.close() }
    }
}
