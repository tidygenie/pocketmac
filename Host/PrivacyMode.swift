import Foundation
import CoreGraphics

/// "Privacy while remote":
///  * iPhone connects → the Mac's own screen goes dark (backlight off: saves most
///    of the display's power, and nobody nearby sees what you're doing). The
///    desktop keeps running, so the iPhone still sees and controls everything.
///  * iPhone disconnects → the Mac locks itself and the brightness comes back.
///    Tapping ✕ on the phone locks at once; an unexpected drop (network switch,
///    app sent to background) waits a grace period so a quick reconnect doesn't
///    lock you out mid-session.
/// Uses only the normal brightness keys and the standard ⌃⌘Q lock shortcut.
final class PrivacyMode {
    static let shared = PrivacyMode()

    enum EndReason { case userDisconnected, dropped, local }

    private let queue = DispatchQueue(label: "pocketmac.privacy")
    private let keys = InputInjector()
    private let cfg = HostConfig.shared
    private var connected = false
    private var pendingFinish: DispatchWorkItem?
    private var keepDarkTimer: DispatchSourceTimer?
    private let dryRun = ProcessInfo.processInfo.environment["POCKETMAC_PRIVACY_DRYRUN"] != nil

    private static let brightnessUp: Int32 = 2      // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown: Int32 = 3    // NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let fullScale = 17               // 16 steps + margin → guaranteed 0

    /// Undo a dark screen left over from a crash, force-quit or reboot.
    func recoverOnLaunch() {
        queue.async { if self.cfg.screenDarkenedByUs { self.restoreBrightness() } }
    }

    func sessionStarted() {
        queue.async {
            self.connected = true
            self.pendingFinish?.cancel()
            self.pendingFinish = nil
            guard self.cfg.darkScreenWhileConnected else { return }
            self.darken()
            self.startKeepDark()
        }
    }

    func sessionEnded(_ reason: EndReason) {
        queue.async {
            self.connected = false
            self.stopKeepDark()
            switch reason {
            case .local:
                // Someone at the Mac disconnected the phone: they're right there, don't lock.
                self.log("disconnected on the Mac — screen back on, not locking")
                self.restoreBrightness()
            case .userDisconnected:
                self.finish(lock: self.cfg.lockOnDisconnect)
            case .dropped:
                let lock = self.cfg.lockOnDisconnect
                let grace = Int(ProcessInfo.processInfo.environment["POCKETMAC_LOCK_GRACE"] ?? "") ?? self.cfg.lockGraceSeconds
                self.log("connection dropped — \(lock ? "locking" : "screen back on") in \(grace) s unless the iPhone returns")
                let w = DispatchWorkItem { [weak self] in
                    guard let self, !self.connected else { return }
                    self.finish(lock: lock)
                }
                self.pendingFinish = w
                self.queue.asyncAfter(deadline: .now() + .seconds(grace), execute: w)
            }
        }
    }

    /// Lid opened/closed or a monitor came/went.
    func displaysChanged() {
        queue.asyncAfter(deadline: .now() + 1) {
            if self.connected {
                if self.cfg.darkScreenWhileConnected && !self.cfg.screenDarkenedByUs { self.darken() }
            } else if self.pendingFinish == nil && self.cfg.screenDarkenedByUs {
                self.restoreBrightness()   // e.g. lid opened after a lid-closed session
            }
        }
    }

    // MARK: - Internals (on queue)

    private func finish(lock: Bool) {
        pendingFinish = nil
        if lock {
            log("locking Mac")
            if !dryRun { pressLockShortcut() }
            Thread.sleep(forTimeInterval: 0.6)   // lock screen first, then light the screen
        }
        restoreBrightness()
    }

    /// ⌃⌘Q pressed like a real keyboard: ⌃ down, ⌘ down, Q, ⌘ up, ⌃ up.
    private func pressLockShortcut() {
        let ctrl: UInt32 = 0x40000, cmd: UInt32 = 0x100000
        keys.key(59, down: true, flags: ctrl)
        keys.key(55, down: true, flags: ctrl | cmd)
        keys.key(12, down: true, flags: ctrl | cmd)
        keys.key(12, down: false, flags: ctrl | cmd)
        keys.key(55, down: false, flags: ctrl)
        keys.key(59, down: false, flags: 0)
    }

    private var builtInDisplayActive: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) != 0 }
    }

    private func darken() {
        // Lid closed: the built-in screen is already off; the iPhone uses the virtual screen.
        guard builtInDisplayActive else { return }
        log("Mac screen dark while iPhone is connected")
        cfg.screenDarkenedByUs = true
        press(Self.brightnessDown, Self.fullScale)
    }

    private func restoreBrightness() {
        guard cfg.screenDarkenedByUs else { return }
        // Lid closed: keep the flag and restore when the lid opens (displaysChanged).
        guard builtInDisplayActive else { return }
        cfg.screenDarkenedByUs = false
        log("Mac screen brightness restored")
        // From a known 0, step up to the chosen level (exact, regardless of where it was).
        press(Self.brightnessDown, Self.fullScale)
        press(Self.brightnessUp, cfg.restoreBrightnessSteps)
    }

    /// Auto-brightness can creep the backlight back up; nudge it down again while connected.
    private func startKeepDark() {
        stopKeepDark()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self, self.connected, self.cfg.darkScreenWhileConnected, self.builtInDisplayActive else { return }
            if self.cfg.screenDarkenedByUs { self.press(Self.brightnessDown, 3) } else { self.darken() }
        }
        t.resume()
        keepDarkTimer = t
    }

    private func stopKeepDark() {
        keepDarkTimer?.cancel()
        keepDarkTimer = nil
    }

    private func press(_ key: Int32, _ times: Int) {
        guard !dryRun else { return }
        for _ in 0..<times {
            SystemControl.mediaKey(key)
            usleep(30_000)
        }
    }

    private func log(_ s: String) { NSLog("PocketMac privacy: \(s)") }
}
