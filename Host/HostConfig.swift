import Foundation
import CryptoKit

struct PairedDevice: Codable, Identifiable, Equatable {
    var id: String { publicKey.base64EncodedString() }
    let publicKey: Data
    var name: String
    let added: Date
    var lastSeen: Date?
}

private struct HostConfigFile: Codable {
    var staticKey: Data
    var salt: Data
    var iterations: UInt32
    var passwordKey: Data?
    var devices: [PairedDevice]
    var lidModeWanted: Bool
    var batteryGuardPercent: Int
}

/// Persistent host state: identity key, password verifier, paired iPhones.
/// Stored at ~/Library/Application Support/PocketMac/host.json with 0600 perms.
/// The password itself is never stored, only its PBKDF2 key.
final class HostConfig: ObservableObject {
    static let shared = HostConfig()

    private let lock = NSLock()
    private var file: HostConfigFile
    private let url: URL
    private var pairingUntil: Date?
    let staticKey: Curve25519.KeyAgreement.PrivateKey
    let deviceID: String

    private init() {
        let env = ProcessInfo.processInfo.environment
        let dir = env["POCKETMAC_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PocketMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        url = dir.appendingPathComponent("host.json")
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(HostConfigFile.self, from: d),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: f.staticKey) {
            file = f
            staticKey = key
        } else {
            let key = Curve25519.KeyAgreement.PrivateKey()
            staticKey = key
            file = HostConfigFile(staticKey: key.rawRepresentation, salt: PMCrypto.randomBytes(16),
                                  iterations: PMCrypto.defaultIterations, passwordKey: nil, devices: [],
                                  lidModeWanted: false, batteryGuardPercent: 15)
        }
        deviceID = DeviceID.from(publicKey: staticKey.publicKey.rawRepresentation)
        saveLocked()
        // Test hook: tools/test-host.sh sets a known password in a throwaway config dir.
        if env["POCKETMAC_CONFIG_DIR"] != nil, let pw = env["POCKETMAC_SET_PASSWORD"] {
            let salt = PMCrypto.randomBytes(16)
            file.salt = salt
            file.passwordKey = PMCrypto.passwordKey(pw, salt: salt, iterations: file.iterations)
            saveLocked()
        }
    }

    private func saveLocked() {
        guard let d = try? JSONEncoder().encode(file) else { return }
        try? d.write(to: url, options: [.atomic])
        chmod(url.path, 0o600)
    }

    private func mutate(_ f: (inout HostConfigFile) -> Void) {
        lock.lock()
        f(&file)
        saveLocked()
        lock.unlock()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    private func read<T>(_ f: (HostConfigFile) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return f(file)
    }

    // MARK: Password

    var hasPassword: Bool { read { $0.passwordKey != nil } }
    var salt: Data { read { $0.salt } }
    var iterations: UInt32 { read { $0.iterations } }
    var passwordKey: Data? { read { $0.passwordKey } }

    func setPassword(_ pw: String) {
        let salt = PMCrypto.randomBytes(16)
        let key = PMCrypto.passwordKey(pw, salt: salt, iterations: PMCrypto.defaultIterations)
        mutate {
            $0.salt = salt
            $0.iterations = PMCrypto.defaultIterations
            $0.passwordKey = key
        }
    }

    // MARK: Devices

    var devices: [PairedDevice] { read { $0.devices } }

    func isPaired(_ publicKey: Data) -> Bool { read { $0.devices.contains { $0.publicKey == publicKey } } }

    func addDevice(publicKey: Data, name: String) {
        mutate {
            guard !$0.devices.contains(where: { $0.publicKey == publicKey }) else { return }
            $0.devices.append(PairedDevice(publicKey: publicKey, name: name, added: Date(), lastSeen: Date()))
        }
        lock.lock(); pairingUntil = nil; lock.unlock()
    }

    func touchDevice(publicKey: Data, name: String) {
        mutate {
            if let i = $0.devices.firstIndex(where: { $0.publicKey == publicKey }) {
                $0.devices[i].lastSeen = Date()
                $0.devices[i].name = name
            }
        }
    }

    func removeDevice(_ d: PairedDevice) {
        mutate { $0.devices.removeAll { $0.publicKey == d.publicKey } }
        HostServer.shared.disconnect(devicePublicKey: d.publicKey)
    }

    // MARK: Pairing window

    /// Pairing is open while no iPhone is paired yet, or for 5 minutes after “Pair new iPhone”.
    var isPairingOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return file.devices.isEmpty || (pairingUntil.map { $0 > Date() } ?? false)
    }

    var pairingDeadline: Date? { lock.lock(); defer { lock.unlock() }; return pairingUntil }

    func openPairing(minutes: Double = 5) {
        lock.lock(); pairingUntil = Date().addingTimeInterval(minutes * 60); lock.unlock()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func closePairing() {
        lock.lock(); pairingUntil = nil; lock.unlock()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    // MARK: Lid mode

    var lidModeWanted: Bool {
        get { read { $0.lidModeWanted } }
        set { mutate { $0.lidModeWanted = newValue } }
    }

    var batteryGuardPercent: Int {
        get { read { $0.batteryGuardPercent } }
        set { mutate { $0.batteryGuardPercent = max(5, min(50, newValue)) } }
    }
}
