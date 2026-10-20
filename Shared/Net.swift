import Foundation
import Network
import CryptoKit

enum PMNet {
    /// TCP tuned for interactive use; peer-to-peer (AWDL) allowed so the phone and
    /// Mac can talk directly even with no Wi-Fi router at all.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 4
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        p.serviceClass = .interactiveVideo
        return p
    }
}

/// Length-prefixed frames over an NWConnection. All callbacks run on `queue`.
final class FramedConnection {
    static let maxFrame = 16 << 20

    let connection: NWConnection
    let queue: DispatchQueue
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    private(set) var pendingSendBytes = 0
    private var closed = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the connection if needed and begins reading.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let e): self?.shutdown(e)
            case .cancelled: self?.shutdown(nil)
            default: break
            }
        }
        if connection.state == .setup { connection.start(queue: queue) }
        readHeader()
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.shutdown(error); return }
            guard let data, data.count == 4 else { self.shutdown(isComplete ? nil : WireError("short header")); return }
            let len = data.reduce(0) { ($0 << 8) | Int($1) }
            guard len <= Self.maxFrame else { self.shutdown(WireError("frame too large")); return }
            if len == 0 { self.deliver(Data()); self.readHeader(); return }
            self.readBody(len)
        }
    }

    private func readBody(_ len: Int) {
        connection.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.shutdown(error); return }
            guard let data, data.count == len else { self.shutdown(isComplete ? nil : WireError("short body")); return }
            self.deliver(data)
            self.readHeader()
        }
    }

    private func deliver(_ d: Data) {
        guard !closed else { return }
        onMessage?(d)
    }

    func send(_ payload: Data) {
        guard !closed else { return }
        var frame = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        let n = frame.count
        pendingSendBytes += n
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingSendBytes -= n
            if let error { self.shutdown(error) }
        })
    }

    func close() { shutdown(nil) }

    private func shutdown(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let cb = onClose
        onClose = nil
        onMessage = nil
        cb?(error)
    }

    var isClosed: Bool { closed }

    var remoteDescription: String {
        if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }
}

/// Plaintext during the handshake, AES-GCM afterwards.
final class SecureChannel {
    let framed: FramedConnection
    private var sendCipher: CipherState?
    private var recvCipher: CipherState?
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(_ framed: FramedConnection) {
        self.framed = framed
        framed.onMessage = { [weak self] data in self?.received(data) }
        framed.onClose = { [weak self] e in self?.onClose?(e) }
    }

    var isEncrypted: Bool { sendCipher != nil }

    func activate(_ keys: SessionKeys, isServer: Bool) {
        sendCipher = CipherState(key: isServer ? keys.serverToClient : keys.clientToServer)
        recvCipher = CipherState(key: isServer ? keys.clientToServer : keys.serverToClient)
    }

    func sendPlain(_ d: Data) { framed.send(d) }

    func send(_ d: Data) {
        guard let c = sendCipher else { return }
        do { framed.send(try c.seal(d)) } catch { framed.close() }
    }

    private func received(_ d: Data) {
        if let c = recvCipher {
            guard let plain = try? c.open(d) else { framed.close(); return }
            onMessage?(plain)
        } else {
            onMessage?(d)
        }
    }

    func close() { framed.close() }
}

/// "Happy eyeballs": try every known path to the Mac at once (Bonjour/AWDL,
/// Tailscale name, manual IP) and keep whichever connects first.
final class ConnectionRacer {
    private let queue: DispatchQueue
    private let parameters: NWParameters
    private var candidates: [NWConnection] = []
    private var tried = Set<String>()
    private var done = false
    private var expectingMore = true
    private var lastError: Error?
    private let completion: (Result<NWConnection, Error>) -> Void

    init(queue: DispatchQueue, timeout: TimeInterval = 10, completion: @escaping (Result<NWConnection, Error>) -> Void) {
        self.queue = queue
        self.parameters = PMNet.parameters()
        self.completion = completion
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail(WireError("Couldn't reach the Mac. Is PocketMac Host running and are both devices online (same Wi-Fi or Tailscale)?"))
        }
    }

    /// Must be called on `queue`.
    func add(_ endpoint: NWEndpoint) {
        guard !done, tried.insert("\(endpoint)").inserted else { return }
        let c = NWConnection(to: endpoint, using: parameters)
        candidates.append(c)
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready: self.win(c)
            case .failed(let e): self.lastError = e; self.drop(c)
            case .waiting(let e): self.lastError = e; self.drop(c)
            default: break
            }
        }
        c.start(queue: queue)
    }

    /// Call when no further endpoints will be added (e.g. Bonjour gave up).
    func noMoreEndpoints() {
        expectingMore = false
        if candidates.isEmpty { fail(lastError ?? WireError("No route to the Mac.")) }
    }

    func cancel() {
        done = true
        candidates.forEach { $0.cancel() }
        candidates.removeAll()
    }

    private func win(_ c: NWConnection) {
        guard !done else { c.cancel(); return }
        done = true
        for other in candidates where other !== c { other.cancel() }
        candidates.removeAll()
        c.stateUpdateHandler = nil
        completion(.success(c))
    }

    private func drop(_ c: NWConnection) {
        c.cancel()
        candidates.removeAll { $0 === c }
        if candidates.isEmpty && !expectingMore { fail(lastError ?? WireError("No route to the Mac.")) }
    }

    private func fail(_ e: Error) {
        guard !done else { return }
        done = true
        candidates.forEach { $0.cancel() }
        candidates.removeAll()
        completion(.failure(e))
    }
}

/// Everything the iPhone (and the test tool) needs to log in and talk to the Mac.
final class ClientCore {
    enum State {
        case connecting, authenticating, connected(hostName: String), closed(Error?)
    }

    let queue = DispatchQueue(label: "pocketmac.client", qos: .userInteractive)
    var onState: ((State) -> Void)?
    var onMessage: ((ServerMessage) -> Void)?
    /// Called after a successful login with the salt/iterations/key actually used, so the app can cache the key.
    var onAuthenticated: ((ClientHandshake.ServerHelloInfo, Data) -> Void)?

    private let identity: Curve25519.KeyAgreement.PrivateKey
    private let macID: String
    private let deviceName: String
    private let passwordKey: (Data, UInt32) -> Data?
    private var racer: ConnectionRacer?
    private var channel: SecureChannel?
    private var handshake: ClientHandshake?
    private var helloInfo: ClientHandshake.ServerHelloInfo?
    private var keys: SessionKeys?
    private var usedKey = Data()
    private var finished = false

    init(identity: Curve25519.KeyAgreement.PrivateKey, macID: String, deviceName: String,
         passwordKey: @escaping (_ salt: Data, _ iterations: UInt32) -> Data?) {
        self.identity = identity
        self.macID = macID
        self.deviceName = deviceName
        self.passwordKey = passwordKey
    }

    /// Thread-safe. `moreComing` = true if you'll call addEndpoint later (Bonjour).
    func connect(_ endpoints: [NWEndpoint], moreComing: Bool = false) {
        queue.async { [self] in
            self.onState?(.connecting)
            let racer = ConnectionRacer(queue: self.queue) { [weak self] result in
                switch result {
                case .success(let c): self?.connected(c)
                case .failure(let e): self?.finish(e)
                }
            }
            self.racer = racer
            endpoints.forEach { racer.add($0) }
            if !moreComing { racer.noMoreEndpoints() }
        }
    }

    func addEndpoint(_ e: NWEndpoint) { queue.async { self.racer?.add(e) } }
    func noMoreEndpoints() { queue.async { self.racer?.noMoreEndpoints() } }

    func send(_ m: ClientMessage) {
        let d = m.encode()
        queue.async { self.channel?.send(d) }
    }

    var pendingSendBytes: Int { channel?.framed.pendingSendBytes ?? 0 }

    func close() { queue.async { self.finish(nil) } }

    private func connected(_ c: NWConnection) {
        racer = nil
        let framed = FramedConnection(c, queue: queue)
        let ch = SecureChannel(framed)
        channel = ch
        ch.onClose = { [weak self] e in self?.finish(e ?? WireError("The Mac closed the connection.")) }
        ch.onMessage = { [weak self] d in self?.received(d) }
        framed.start()
        onState?(.authenticating)
        let hs = ClientHandshake(staticKey: identity, expectedID: macID, deviceName: deviceName)
        handshake = hs
        ch.sendPlain(hs.hello())
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.finished, self.keys == nil || !(self.channel?.isEncrypted ?? false) else { return }
            self.finish(WireError("Login timed out."))
        }
    }

    private func received(_ d: Data) {
        guard let ch = channel else { return }
        if ch.isEncrypted {
            guard let m = try? ServerMessage.decode(d) else { return } // ignore unknown (newer host)
            onMessage?(m)
            return
        }
        do {
            guard let hs = handshake else { return }
            if helloInfo == nil {
                let info = try hs.parseServerHello(d)
                helloInfo = info
                guard let pk = passwordKey(info.salt, info.iterations) else {
                    throw HandshakeFailure(code: .badCredentials, retryAfter: 0, message: "Password needed.")
                }
                usedKey = pk
                let (fin, k) = try hs.finish(passwordKey: pk)
                keys = k
                ch.sendPlain(fin)
            } else if let k = keys, let info = helloInfo {
                try hs.verifyServerFinish(d, keys: k)
                ch.activate(k, isServer: false)
                handshake = nil
                onAuthenticated?(info, usedKey)
                onState?(.connected(hostName: info.hostName))
            }
        } catch {
            finish(error)
        }
    }

    private func finish(_ e: Error?) {
        guard !finished else { return }
        finished = true
        onMessage = nil   // nothing from this connection after it's closed
        racer?.cancel(); racer = nil
        let ch = channel
        channel = nil
        ch?.onClose = nil
        ch?.close()
        onState?(.closed(e))
    }
}
