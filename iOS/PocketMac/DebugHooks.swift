import Foundation

/// Test-only hook, active only when this environment variable is set (never on a
/// real iPhone). Used to run the app as a Mac Catalyst build against a test host:
///   POCKETMAC_AUTOCONNECT = "ID|password|host|port"
enum DebugHooks {
    static func autoconnectIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["POCKETMAC_AUTOCONNECT"] else { return }
        let p = spec.split(separator: "|").map(String.init)
        guard p.count == 4 else { return }
        let mac = SavedMac(id: DeviceID.normalize(p[0]), name: "Test Mac", internetAddress: p[2], port: UInt16(p[3]) ?? 47800)
        NSLog("PMDEBUG autoconnect to \(p[2]):\(p[3])")
        NavModel.shared.connect(mac, password: p[1], remember: false)
    }
}
