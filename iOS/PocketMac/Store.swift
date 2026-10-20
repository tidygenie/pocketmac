import Foundation
import CryptoKit
import Security
import LocalAuthentication
import UIKit

struct SavedMac: Codable, Identifiable, Equatable {
    var id: String              // normalised Mac ID (12 chars)
    var name: String
    var internetAddress: String // Tailscale name / IP / public IPv6 — optional
    var port: UInt16 = 47800
    var lastConnected: Date?

    var prettyID: String { DeviceID.pretty(id) }
}

enum InputMode: String, Codable, CaseIterable {
    case trackpad, touch
    var label: String { self == .trackpad ? "Trackpad" : "Touch" }
    var icon: String { self == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.tap" }
}

struct ClientSettings: Codable, Equatable {
    var quality: UInt8 = StreamQuality.balanced.rawValue
    var fps: UInt8 = 30
    var useHEVC = true
    var inputMode: InputMode = .trackpad
    var lidFit: UInt8 = LidDisplayFit.phone.rawValue
    var clipboardSync = true
    var keepScreenOn = true
    var reverseScroll = false
    var haptics = true
    var trackpadSpeed: Double = 1.0
    var autoSaverOnLowPower = true

    var streamQuality: StreamQuality { StreamQuality(rawValue: quality) ?? .balanced }

    func streamSettings() -> StreamSettings {
        var s = StreamSettings()
        let lowPower = autoSaverOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled
        s.quality = lowPower ? .saver : streamQuality
        s.maxFPS = lowPower ? 30 : fps
        s.codec = useHEVC ? .hevc : .h264
        let px = UIScreen.main.nativeBounds.size
        s.clientPixelWidth = UInt16(max(px.width, px.height))
        s.clientPixelHeight = UInt16(min(px.width, px.height))
        s.lidFit = LidDisplayFit(rawValue: lidFit) ?? .phone
        return s
    }
}

/// Cached login for one Mac: the PBKDF2 output, never the password itself.
struct MacCredential: Codable {
    var salt: Data
    var iterations: UInt32
    var key: Data
}

final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var macs: [SavedMac] { didSet { persist() } }
    @Published var settings: ClientSettings { didSet { persist() } }

    private let defaults = UserDefaults.standard

    private init() {
        macs = (defaults.data(forKey: "macs").flatMap { try? JSONDecoder().decode([SavedMac].self, from: $0) }) ?? []
        settings = (defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(ClientSettings.self, from: $0) })
            ?? ClientSettings()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(macs) { defaults.set(d, forKey: "macs") }
        if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: "settings") }
    }

    func upsert(_ m: SavedMac) {
        if let i = macs.firstIndex(where: { $0.id == m.id }) { macs[i] = m } else { macs.append(m) }
    }

    func remove(_ m: SavedMac) {
        macs.removeAll { $0.id == m.id }
        Keychain.delete(account: "cred-\(m.id)")
    }

    // MARK: Identity — this iPhone's long-term key, created once.

    lazy var identity: Curve25519.KeyAgreement.PrivateKey = {
        if let d = Keychain.read(account: "identity", prompt: nil),
           let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.KeyAgreement.PrivateKey()
        Keychain.write(account: "identity", data: k.rawRepresentation, protected: false)
        return k
    }()

    var deviceName: String {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let names = ["iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
                     "iPhone13,4": "iPhone 12 Pro Max"]
        return names[machine] ?? UIDevice.current.model
    }

    // MARK: Credentials (Face ID protected)

    func hasCredential(for id: String) -> Bool { Keychain.exists(account: "cred-\(id)") }

    /// Shows Face ID. Returns nil if cancelled or missing.
    func loadCredential(for id: String) -> MacCredential? {
        guard let d = Keychain.read(account: "cred-\(id)", prompt: "Unlock your Mac login") else { return nil }
        return try? JSONDecoder().decode(MacCredential.self, from: d)
    }

    func saveCredential(_ c: MacCredential, for id: String) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        Keychain.write(account: "cred-\(id)", data: d, protected: true)
    }

    func deleteCredential(for id: String) { Keychain.delete(account: "cred-\(id)") }
}

enum Keychain {
    private static let service = "PocketMac"

    static func write(account: String, data: Data, protected: Bool) {
        delete(account: account)
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecValueData: data]
        if protected, let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                               .userPresence, nil) {
            q[kSecAttrAccessControl] = ac
        } else {
            q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess, protected {
            // No passcode on the device: fall back to normal protection.
            q.removeValue(forKey: kSecAttrAccessControl)
            q[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func read(account: String, prompt: String?) -> Data? {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        if let prompt {
            let ctx = LAContext()
            ctx.localizedReason = prompt
            q[kSecUseAuthenticationContext] = ctx
        }
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func exists(account: String) -> Bool {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecUseAuthenticationContext: ctx]
        let st = SecItemCopyMatching(q as CFDictionary, nil)
        return st == errSecSuccess || st == errSecInteractionNotAllowed
    }

    static func delete(account: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
    }
}
