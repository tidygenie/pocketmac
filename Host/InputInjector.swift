import Foundation
import CoreGraphics
import ApplicationServices

/// Turns phone gestures into real mouse/keyboard events (needs Accessibility permission).
/// Coordinates arrive normalised 0…1 over the captured display.
final class InputInjector {
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    private let source = CGEventSource(stateID: .hidSystemState)
    private var leftDown = false
    private var rightDown = false
    private var otherDown = false
    private var scrollRemainder = CGPoint.zero
    private var lastPoint = CGPoint.zero

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        let nx = CGFloat(min(max(x, 0), 1)), ny = CGFloat(min(max(y, 0), 1))
        return CGPoint(x: b.minX + min(nx * b.width, b.width - 1), y: b.minY + min(ny * b.height, b.height - 1))
    }

    /// Normalised cursor position on the captured display (nil if the cursor is on another display).
    func cursorPosition() -> (Float, Float)? {
        guard let loc = CGEvent(source: nil)?.location else { return nil }
        let b = CGDisplayBounds(displayID)
        guard b.width > 0, b.contains(loc) else { return nil }
        return (Float((loc.x - b.minX) / b.width), Float((loc.y - b.minY) / b.height))
    }

    func move(x: Float, y: Float) {
        let p = point(x, y)
        lastPoint = p
        let (type, button): (CGEventType, CGMouseButton) =
            leftDown ? (.leftMouseDragged, .left) : rightDown ? (.rightMouseDragged, .right)
            : otherDown ? (.otherMouseDragged, .center) : (.mouseMoved, .left)
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    func button(_ b: UInt8, down: Bool, x: Float, y: Float, clicks: UInt8, flags: UInt32) {
        let p = point(x, y)
        lastPoint = p
        let type: CGEventType
        let button: CGMouseButton
        switch b {
        case 1: type = down ? .rightMouseDown : .rightMouseUp; button = .right; rightDown = down
        case 2: type = down ? .otherMouseDown : .otherMouseUp; button = .center; otherDown = down
        default: type = down ? .leftMouseDown : .leftMouseUp; button = .left; leftDown = down
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(max(clicks, 1)))
        if flags != 0 { e.flags = CGEventFlags(rawValue: UInt64(flags)) }
        e.post(tap: .cghidEventTap)
    }

    func scroll(dx: Float, dy: Float) {
        scrollRemainder.x += CGFloat(dx)
        scrollRemainder.y += CGFloat(dy)
        let ix = Int32(scrollRemainder.x.rounded(.towardZero))
        let iy = Int32(scrollRemainder.y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return }
        scrollRemainder.x -= CGFloat(ix)
        scrollRemainder.y -= CGFloat(iy)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.post(tap: .cghidEventTap)
    }

    func key(_ code: UInt16, down: Bool, flags: UInt32) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        e.flags = CGEventFlags(rawValue: UInt64(flags))
        e.post(tap: .cghidEventTap)
    }

    func tap(_ code: UInt16, flags: UInt32 = 0) {
        key(code, down: true, flags: flags)
        key(code, down: false, flags: flags)
    }

    /// Types arbitrary Unicode (Hindi, emoji, …) independent of the Mac's keyboard layout.
    func type(_ text: String) {
        var chunk = [UniChar]()
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
            chunk.removeAll()
        }
        for ch in text {
            switch ch {
            case "\n", "\r", "\r\n": flush(); tap(36)
            case "\t": flush(); tap(48)
            default:
                let units = Array(String(ch).utf16)
                if chunk.count + units.count > 16 { flush() }
                chunk.append(contentsOf: units)
            }
        }
        flush()
    }

    /// Releases anything still held (e.g. the phone disconnected mid-drag).
    func releaseAll() {
        if leftDown { post(.leftMouseUp, .left); leftDown = false }
        if rightDown { post(.rightMouseUp, .right); rightDown = false }
        if otherDown { post(.otherMouseUp, .center); otherDown = false }
    }

    private func post(_ t: CGEventType, _ b: CGMouseButton) {
        CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: lastPoint, mouseButton: b)?
            .post(tap: .cghidEventTap)
    }
}
