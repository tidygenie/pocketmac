import AppKit
import SwiftUI
import ServiceManagement
import Combine

@main
enum PocketMacHostMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let server = HostServer.shared
    private let config = HostConfig.shared

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        server.onChange = { [weak self] in self?.updateIcon() }
        server.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.server.streamer.displaysChanged()
            PrivacyMode.shared.displaysChanged()
        }
        PrivacyMode.shared.recoverOnLaunch()
        VirtualDisplayManager.shared.startMonitoring()

        // Re-apply lid mode preference after a reboot (pmset setting persists, but keep them in sync).
        if config.lidModeWanted && !SystemControl.sleepDisabled() && SystemControl.helperInstalled {
            SystemControl.setLidMode(true, allowPrompt: false)
        }

        NSLog("PocketMac Host ready. ID \(DeviceID.pretty(config.deviceID)), port \(PocketMacPort)")
        if ProcessInfo.processInfo.environment["POCKETMAC_HEADLESS"] != nil { return }
        if !config.hasPassword || !CGPreflightScreenCaptureAccess() || !InputInjector.hasPermission {
            showSettings()
        }
    }

    private func updateIcon() {
        let connected = server.connectedDevice != nil
        let name = connected ? "iphone.radiowaves.left.and.right" : "macbook.and.iphone"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "PocketMac")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = connected ? "PocketMac: \(server.connectedDevice!) connected" : "PocketMac Host"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let dev = server.connectedDevice {
            menu.addItem(withTitle: "Connected: \(dev)", action: nil, keyEquivalent: "")
            if let a = server.connectedAddress { menu.addItem(withTitle: "   from \(a)", action: nil, keyEquivalent: "") }
        } else {
            menu.addItem(withTitle: config.hasPassword ? "Ready — waiting for iPhone" : "Set a password first", action: nil, keyEquivalent: "")
        }
        let idItem = NSMenuItem(title: "ID: \(DeviceID.pretty(config.deviceID))  (click to copy)", action: #selector(copyID), keyEquivalent: "")
        idItem.target = self
        menu.addItem(idItem)
        menu.addItem(.separator())

        if config.isPairingOpen {
            let until = config.pairingDeadline.map { "until " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "(no iPhone paired yet)"
            menu.addItem(withTitle: "Pairing open \(until)", action: nil, keyEquivalent: "")
        } else {
            add(menu, "Pair new iPhone (5 min)", #selector(openPairing))
        }
        let lid = NSMenuItem(title: "Keep running with lid closed", action: #selector(toggleLid), keyEquivalent: "")
        lid.target = self
        lid.state = SystemControl.sleepDisabled() ? .on : .off
        menu.addItem(lid)
        if server.connectedDevice != nil { add(menu, "Disconnect iPhone", #selector(disconnect)) }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(showSettings), key: ",")
        add(menu, "Quit PocketMac Host", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    @objc private func copyID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DeviceID.pretty(config.deviceID), forType: .string)
    }

    @objc private func openPairing() { config.openPairing() }

    @objc private func toggleLid() {
        let on = !SystemControl.sleepDisabled()
        if on && !confirmLidMode() { return }
        config.lidModeWanted = on
        SystemControl.setLidMode(on, allowPrompt: true)
        VirtualDisplayManager.shared.evaluate()
    }

    private func confirmLidMode() -> Bool {
        let a = NSAlert()
        a.messageText = "Keep the Mac running with the lid closed?"
        a.informativeText = "macOS will not sleep at all until you turn this off — even in a bag. Don't put a running Mac in a closed bag; it can get hot. PocketMac turns it off automatically when the battery drops to \(config.batteryGuardPercent)% (needs the helper)."
        a.addButton(withTitle: "Turn On")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc private func disconnect() { server.disconnectAll() }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "PocketMac Host"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(confirmLid: { [weak self] in self?.confirmLidMode() ?? false }))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject private var config = HostConfig.shared
    @ObservedObject private var m: SettingsModel
    let confirmLid: () -> Bool
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(confirmLid: @escaping () -> Bool) {
        self.confirmLid = confirmLid
        m = SettingsModel()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This Mac's ID").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(DeviceID.pretty(config.deviceID))
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(DeviceID.pretty(config.deviceID), forType: .string)
                        }
                    }
                    Text("On the iPhone, enter this ID and your password. The ID is a fingerprint of this Mac's encryption key, so nobody can pretend to be this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(statusLine).font(.callout).padding(.top, 2)
                }
            }

            Section("Password") {
                SecureField(config.hasPassword ? "New password" : "Password (at least 8 characters)", text: $m.pw1)
                SecureField("Repeat password", text: $m.pw2)
                HStack {
                    Button(config.hasPassword ? "Change password" : "Set password") { savePassword() }
                        .disabled(m.pw1.isEmpty)
                    Text(m.pwMessage).font(.caption).foregroundStyle(m.pwMessage.hasPrefix("✓") ? .green : .red)
                }
                Text(config.hasPassword ? "Password is set. Only a PBKDF2 key is stored, never the password itself."
                     : "No password yet — the iPhone can't connect until you set one.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Paired iPhone") {
                if config.devices.isEmpty {
                    Text("None yet. The first iPhone that logs in with the right password gets paired; after that, all other devices are refused.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(config.devices) { d in
                    HStack {
                        Image(systemName: "iphone")
                        VStack(alignment: .leading) {
                            Text(d.name)
                            Text("Paired \(d.added.formatted(date: .abbreviated, time: .shortened))" +
                                 (d.lastSeen.map { " · last seen \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { config.removeDevice(d) }
                    }
                }
                HStack {
                    if config.isPairingOpen {
                        Text(config.pairingDeadline.map { "Pairing open until \($0.formatted(date: .omitted, time: .shortened))" }
                             ?? "Pairing open (no iPhone paired yet)")
                            .foregroundStyle(.orange)
                        if config.pairingDeadline != nil { Button("Close") { config.closePairing() } }
                    } else {
                        Button("Pair new iPhone (opens for 5 min)") { config.openPairing() }
                    }
                }
            }

            Section("Permissions") {
                permissionRow("Screen Recording", ok: CGPreflightScreenCaptureAccess(),
                              help: "So the iPhone can see the screen.") {
                    if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
                }
                permissionRow("Accessibility", ok: InputInjector.hasPermission,
                              help: "So touches and typing control the Mac.") {
                    InputInjector.requestPermission()
                    openPrivacy("Privacy_Accessibility")
                }
            }

            Section("How the iPhone finds this Mac") {
                ForEach(NetInfo.addresses(), id: \.address) { a in
                    HStack {
                        Text(a.kind).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                        Text(a.address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Text("Same Wi-Fi, or iPhone near the Mac with no Wi-Fi: found automatically (Bonjour / peer-to-peer).\nDifferent networks: install Tailscale on both and enter the Tailscale address on the iPhone. Port \(String(PocketMacPort)).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Turn the Mac's screen dark while my iPhone is connected", isOn: Binding(
                    get: { config.darkScreenWhileConnected }, set: { config.darkScreenWhileConnected = $0 }))
                Toggle("Lock the Mac when my iPhone disconnects", isOn: Binding(
                    get: { config.lockOnDisconnect }, set: { config.lockOnDisconnect = $0 }))
                Stepper("If the connection drops, wait \(config.lockGraceSeconds) s before locking", value: Binding(
                    get: { config.lockGraceSeconds }, set: { config.lockGraceSeconds = $0 }), in: 10...300, step: 10)
                Stepper("Brightness afterwards: \(config.restoreBrightnessSteps) of 16", value: Binding(
                    get: { config.restoreBrightnessSteps }, set: { config.restoreBrightnessSteps = $0 }), in: 2...16)
            } header: { Text("While your iPhone is connected") } footer: {
                Text("The desktop keeps running for the iPhone while the Mac's own screen is black, so nobody nearby sees it and the backlight doesn't use power. Tapping ✕ on the iPhone locks the Mac at once; a network drop or switching apps on the iPhone waits the time above so a quick reconnect doesn't lock you out. Disconnecting from this Mac's menu never locks.")
            }

            Section("Lid closed") {
                Toggle("Keep running with lid closed", isOn: Binding(get: { m.lidOn }, set: { on in
                    if on && !confirmLid() { return }
                    config.lidModeWanted = on
                    SystemControl.setLidMode(on, allowPrompt: true)
                    m.lidOn = SystemControl.sleepDisabled()
                    VirtualDisplayManager.shared.evaluate()
                }))
                Text("Uses `pmset disablesleep` (asks for your Mac password). When the lid is closed PocketMac adds a virtual screen shaped for your iPhone, so you still see and control a full desktop.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if m.helper {
                        Label("Helper installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Remove helper") { _ = SystemControl.removeHelper(); m.helper = SystemControl.helperInstalled }
                    } else {
                        Button("Install helper") { _ = SystemControl.installHelper(); m.helper = SystemControl.helperInstalled }
                        Spacer()
                    }
                }
                Text("Optional. Lets PocketMac run only `pmset -a disablesleep 0/1` without a password, so you can switch lid mode from the iPhone and the battery guard can turn it off.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Battery guard: turn off at \(config.batteryGuardPercent)%", value: Binding(
                    get: { config.batteryGuardPercent }, set: { config.batteryGuardPercent = $0 }), in: 5...50, step: 5)
            }

            Section("General") {
                Toggle("Start PocketMac Host at login", isOn: Binding(get: { m.loginItem }, set: {
                    LoginItem.set($0); m.loginItem = LoginItem.isEnabled
                }))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 600)
        .onReceive(timer) { _ in
            m.tick += 1
            m.lidOn = SystemControl.sleepDisabled()
            m.helper = SystemControl.helperInstalled
        }
    }

    private var statusLine: String {
        _ = m.tick
        let s = HostServer.shared
        if let d = s.connectedDevice { return "● Connected: \(d)" }
        return "○ \(s.listenerState)"
    }

    private func savePassword() {
        guard m.pw1.count >= 8 else { m.pwMessage = "Use at least 8 characters."; return }
        guard m.pw1 == m.pw2 else { m.pwMessage = "Passwords don't match."; return }
        config.setPassword(m.pw1)
        m.pw1 = ""; m.pw2 = ""
        m.pwMessage = "✓ Saved"
    }

    private func permissionRow(_ title: String, ok: Bool, help: String, grant: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Allow…", action: grant) }
        }
        .id("\(title)\(m.tick)")
    }

    private func openPrivacy(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(u)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var pw1 = ""
    @Published var pw2 = ""
    @Published var pwMessage = ""
    @Published var tick = 0
    @Published var lidOn = SystemControl.sleepDisabled()
    @Published var helper = SystemControl.helperInstalled
    @Published var loginItem = LoginItem.isEnabled
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("PocketMac: login item change failed: \(error)")
        }
    }
}

enum NetInfo {
    struct Addr { let kind: String; let address: String }

    static func addresses() -> [Addr] {
        var out = [Addr]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(sa.pointee.sa_family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6),
                  getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if sa.pointee.sa_family == UInt8(AF_INET) {
                let parts = ip.split(separator: ".").compactMap { Int($0) }
                if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) {
                    out.append(Addr(kind: "Tailscale", address: ip))
                } else if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    out.append(Addr(kind: "Wi-Fi / LAN", address: ip))
                }
            } else if ip.hasPrefix("fd7a:115c:a1e0") {
                out.append(Addr(kind: "Tailscale IPv6", address: ip))
            } else if name.hasPrefix("en"), !ip.hasPrefix("fe80"), !ip.hasPrefix("fd") {
                out.append(Addr(kind: "Public IPv6", address: ip))
            }
        }
        if !out.contains(where: { $0.kind == "Tailscale" }) {
            out.append(Addr(kind: "Tailscale", address: "not running — needed for different networks"))
        }
        return out
    }
}
