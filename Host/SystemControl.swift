import Foundation
import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Power, lid, quick actions and clipboard.
enum SystemControl {
    // MARK: Power & lid

    struct Power { var percent: Int = -1; var charging = false; var onAC = true }

    static func power() -> Power {
        var p = Power()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return p }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                p.percent = cur * 100 / max
            }
            p.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            p.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
        return p
    }

    static func lidClosed() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (v as? Bool) ?? false
    }

    // MARK: Lid-closed mode (pmset disablesleep)

    static let helperPath = "/etc/sudoers.d/pocketmac"
    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: helperPath) }

    /// True when macOS is told not to sleep at all (so closing the lid keeps it running).
    static func sleepDisabled() -> Bool {
        guard let out = run("/usr/bin/pmset", ["-g"]) else { return false }
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
        }
        return false
    }

    /// Uses the passwordless helper if installed; otherwise (only when `allowPrompt`) asks for the admin password.
    @discardableResult
    static func setLidMode(_ on: Bool, allowPrompt: Bool) -> Bool {
        let arg = on ? "1" : "0"
        if helperInstalled, run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", arg]) != nil {
            return sleepDisabled() == on
        }
        guard allowPrompt else { return false }
        return runAsAdmin("/usr/bin/pmset -a disablesleep \(arg)") && sleepDisabled() == on
    }

    /// One-time: lets PocketMac toggle *only* `pmset -a disablesleep 0|1` without a password,
    /// so the iPhone can switch lid-closed mode and the battery guard can turn it off.
    static func installHelper() -> Bool {
        let user = NSUserName()
        guard user.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { return false }
        let script = """
        set -e
        f=$(mktemp)
        printf '%s\\n' '# PocketMac Host: lets the app toggle lid-closed mode (pmset disablesleep) without a password' \
          '\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' > "$f"
        /usr/sbin/visudo -cf "$f"
        /usr/bin/install -m 0440 -o root -g wheel "$f" \(helperPath)
        rm -f "$f"
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pocketmac-helper.sh")
        do { try script.write(to: tmp, atomically: true, encoding: .utf8) } catch { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return runAsAdmin("/bin/sh '\(tmp.path)'") && helperInstalled
    }

    static func removeHelper() -> Bool {
        runAsAdmin("/bin/rm -f \(helperPath)") && !helperInstalled
    }

    private static func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        var ok = false
        let work = {
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            ok = err == nil
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        if let err { NSLog("PocketMac: admin command failed: \(err)") }
        return ok
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Keep awake while a phone is connected

    private static var assertions: [IOPMAssertionID] = []

    static func holdAwake(_ on: Bool) {
        if on {
            guard assertions.isEmpty else { return }
            wakeDisplay()
            for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
                var id: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "PocketMac remote session" as CFString, &id) == kIOReturnSuccess {
                    assertions.append(id)
                }
            }
        } else {
            assertions.forEach { IOPMAssertionRelease($0) }
            assertions.removeAll()
        }
    }

    static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("PocketMac" as CFString, kIOPMUserActiveLocal, &id)
    }

    // MARK: Quick actions

    private static let cmd: UInt32 = 0x100000, shift: UInt32 = 0x20000, ctrl: UInt32 = 0x40000, opt: UInt32 = 0x80000

    /// Returns a message for the phone if something needs explaining.
    static func perform(_ a: QuickAction, input: InputInjector) -> String? {
        switch a {
        case .lockScreen: input.tap(12, flags: ctrl | cmd)               // ⌃⌘Q
        case .sleepDisplay: run("/usr/bin/pmset", ["displaysleepnow"])
        case .wakeDisplay: wakeDisplay()
        case .missionControl: openApp("/System/Applications/Mission Control.app")
        case .showDesktop: launch("/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", ["1"])
        case .spotlight: input.tap(49, flags: cmd)                     // ⌘Space
        case .appSwitcher: input.tap(48, flags: cmd)                   // ⌘Tab
        case .screenshot: input.tap(20, flags: cmd | shift)            // ⌘⇧3 → Desktop
        case .forceQuit: input.tap(53, flags: cmd | opt)               // ⌘⌥Esc
        case .volumeUp: mediaKey(0)
        case .volumeDown: mediaKey(1)
        case .mute: mediaKey(7)
        case .playPause: mediaKey(16)
        case .nextTrack: mediaKey(17)
        case .previousTrack: mediaKey(18)
        case .lidModeOn, .lidModeOff:
            let on = a == .lidModeOn
            guard helperInstalled else {
                return "To switch lid-closed mode from the iPhone, click “Install helper” once in PocketMac Host on the Mac."
            }
            HostConfig.shared.lidModeWanted = on
            if !setLidMode(on, allowPrompt: false) { return "Couldn't change lid-closed mode." }
            DispatchQueue.main.async { VirtualDisplayManager.shared.evaluate() }
        case .sleepMac:
            if sleepDisabled() {
                guard helperInstalled, setLidMode(false, allowPrompt: false) else {
                    return "Lid-closed mode is on; install the helper on the Mac so the iPhone can turn it off."
                }
                HostConfig.shared.lidModeWanted = false
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { run("/usr/bin/pmset", ["sleepnow"]) }
            return "Mac is going to sleep. You'll need to wake it on the Mac itself."
        }
        return nil
    }

    private static func openApp(_ path: String) {
        DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    private static func launch(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    /// Hardware media keys (volume / play) via NX system-defined events.
    private static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Clipboard

    static var clipboardChangeCount: Int { NSPasteboard.general.changeCount }

    static func clipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func setClipboard(_ s: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
}

/// Creates a virtual monitor while the lid is closed so there's still a desktop to
/// see and control. Removed again as soon as the lid opens.
final class VirtualDisplayManager {
    static let shared = VirtualDisplayManager()

    private var display: CGVirtualDisplay?
    private(set) var currentSize: (Int, Int) = (0, 0)
    var fit: LidDisplayFit = .phone
    var clientPixels: (Int, Int) = (2532, 1170)
    private var timer: Timer?

    var isActive: Bool { display != nil }
    var displayID: CGDirectDisplayID? { display?.displayID }

    /// Starts watching the lid (cheap IORegistry read every 2 s).
    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.evaluate() }
        evaluate()
    }

    /// Point size of the virtual screen for the requested fit (pixels are 2x).
    /// "Fit iPhone" on an iPhone 12 = 1266×584 pt = exactly its 2532×1170 screen, so nothing is scaled.
    func targetSize() -> (Int, Int) {
        let w = max(clientPixels.0, clientPixels.1), h = min(clientPixels.0, clientPixels.1)
        switch fit {
        case .phone: return ((w / 2) & ~1, (h / 2) & ~1)
        case .phoneRoomy: return ((w * 2 / 3) & ~1, (h * 2 / 3) & ~1)
        case .laptop: return (1470, 956)
        }
    }

    func evaluate() {
        guard SystemControl.lidClosed(), !hasOtherActiveDisplay() else { destroy(); return }
        if display != nil, currentSize == targetSize() { return }
        if HostConfig.shared.lidModeWanted || SystemControl.sleepDisabled() { create() }
    }

    private func hasOtherActiveDisplay() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).contains { $0 != display?.displayID }
    }

    func create() {
        let (w, h) = targetSize()
        if let display {
            if apply(display, w, h) { currentSize = (w, h); return }
            destroy()
        }
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = "PocketMac Screen"
        desc.maxPixelsWide = 3840
        desc.maxPixelsHigh = 2400
        desc.sizeInMillimeters = CGSize(width: 300, height: 190)
        desc.productID = 0x504D
        desc.vendorID = 0x3D5A
        desc.serialNum = 1
        desc.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async { self?.display = nil }
        }
        guard let d = CGVirtualDisplay(descriptor: desc), apply(d, w, h) else {
            NSLog("PocketMac: virtual display could not be created"); return
        }
        display = d
        currentSize = (w, h)
        NSLog("PocketMac: virtual display \(d.displayID) created \(w)x\(h)")
    }

    private func apply(_ d: CGVirtualDisplay, _ w: Int, _ h: Int) -> Bool {
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 1
        // Mode sizes are pixels; with hiDPI macOS shows them at half size in points (Retina).
        s.modes = [CGVirtualDisplayMode(width: UInt(w * 2), height: UInt(h * 2), refreshRate: 60)]
        return d.apply(s)
    }

    func destroy() {
        guard display != nil else { return }
        display = nil   // releasing the object removes the screen
        currentSize = (0, 0)
        NSLog("PocketMac: virtual display removed")
    }
}
