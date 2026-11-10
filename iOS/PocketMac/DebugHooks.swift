import Foundation
import UIKit

/// Test-only hooks, active only when these environment variables are set — which
/// only a developer's Mac or the CI simulator can do, never a normal iPhone launch.
///   POCKETMAC_AUTOCONNECT = "ID|password|host|port"   connect to a test host
///   POCKETMAC_DEMO        = home | add | settings      screenshot set-up (adds a sample Mac)
///   POCKETMAC_LANDSCAPE   = 1                          turn the remote screen sideways
///   POCKETMAC_KEYBOARD    = 1                          open the keyboard once connected
enum DebugHooks {
    static func autoconnectIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let screen = env["POCKETMAC_DEMO"] {
            AppStore.shared.upsert(SavedMac(id: "K7QM4XPA9TZC", name: "MacBook Air", internetAddress: "macbook-air",
                                            lastConnected: Date().addingTimeInterval(-3600)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                switch screen {
                case "add": NavModel.shared.addForm = AddMacForm()
                case "settings": NavModel.shared.showSettings = true
                default: break
                }
            }
        }
        guard let spec = env["POCKETMAC_AUTOCONNECT"] else { return }
        let p = spec.split(separator: "|").map(String.init)
        guard p.count == 4 else { return }
        let mac = SavedMac(id: DeviceID.normalize(p[0]), name: "MacBook Air", internetAddress: p[2], port: UInt16(p[3]) ?? 47800)
        NSLog("PMDEBUG autoconnect to \(p[2]):\(p[3])")
        NavModel.shared.connect(mac, password: p[1], remember: false)
        if env["POCKETMAC_LANDSCAPE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { NSLog("PMDEBUG rotate: \($0)") }
            }
        }
        if env["POCKETMAC_KEYBOARD"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NavModel.shared.session?.controls.toggleKeyboard?() }
        }
    }
}
