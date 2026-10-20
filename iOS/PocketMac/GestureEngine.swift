import UIKit

protocol GestureEngineDelegate: AnyObject {
    var inputMode: InputMode { get }
    /// True when the picture is bigger than the visible area (zoomed or keyboard up).
    var canPanView: Bool { get }
    func gestureMoveCursor(by delta: CGPoint, speed: CGFloat)
    func gestureClick(button: UInt8, at point: CGPoint?, count: Int)
    func gestureButton(_ button: UInt8, down: Bool, at point: CGPoint?)
    func gestureDragTo(_ point: CGPoint)
    func gestureScroll(by delta: CGPoint)
    func gestureScrollEnded(velocity: CGPoint)
    func gestureZoom(scale: CGFloat, focal: CGPoint, pan: CGPoint)
    func gesturePanView(by delta: CGPoint)
    func gestureThreeFinger(_ direction: UISwipeGestureRecognizer.Direction?)
    func gestureTouchBegan()
    func gestureLongPressFeedback()
}

/// Raw-touch gesture recogniser. One place decides what every touch means, so
/// gestures never fight each other.
///
///                      Trackpad mode              Touch mode
///  1-finger tap        click at pointer           click under finger
///  double / triple     double / triple click      double / triple click
///  1-finger slide      move pointer               drag (or pan view when zoomed)
///  tap, then slide     drag (select / move)       drag
///  long press          right click                right click under finger
///  2-finger tap        right click                right click
///  2-finger slide      scroll (with momentum)     scroll (with momentum)
///  pinch               zoom the picture           zoom the picture
///  3-finger swipe      ← → Spaces, ↑ Mission Control, ↓ App windows
///  3-finger tap        show / hide keyboard
final class GestureEngine {
    weak var delegate: GestureEngineDelegate?

    private enum Phase {
        case idle
        case one
        case two
        case three
        case finishing   // some fingers still down after a multi-finger gesture
    }

    private enum TwoMode { case undecided, scroll, zoom }

    private var phase = Phase.idle
    private var touches: [UITouch] = []
    private weak var view: UIView?

    // one finger
    private var start = CGPoint.zero
    private var last = CGPoint.zero
    private var lastTime: TimeInterval = 0
    private var startTime: TimeInterval = 0
    private var moved = false
    private var dragging = false
    private var panningView = false
    private var tapDragCandidate = false
    private var longPressFired = false
    private var longPressWork: DispatchWorkItem?
    private var lastTapTime: TimeInterval = 0
    private var lastTapPoint = CGPoint.zero
    private var tapCount = 0
    private var speed: CGFloat = 0

    // two / three fingers
    private var twoMode = TwoMode.undecided
    private var startDistance: CGFloat = 1
    private var lastDistance: CGFloat = 1
    private var startCentroid = CGPoint.zero
    private var lastCentroid = CGPoint.zero
    private var multiStartTime: TimeInterval = 0
    private var multiMoved = false
    private var scrollVelocity = CGPoint.zero
    private var maxFingers = 0

    init(view: UIView) { self.view = view }

    private func loc(_ t: UITouch) -> CGPoint { t.location(in: view) }

    private func centroid() -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        let pts = touches.map(loc)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    private func distance() -> CGFloat {
        guard touches.count >= 2 else { return 1 }
        let a = loc(touches[0]), b = loc(touches[1])
        return max(1, hypot(a.x - b.x, a.y - b.y))
    }

    // MARK: Touch entry points

    func began(_ new: Set<UITouch>, event: UIEvent?) {
        let wasIdle = touches.isEmpty
        touches.append(contentsOf: new)
        maxFingers = max(maxFingers, touches.count)
        if wasIdle { delegate?.gestureTouchBegan() }
        let now = CACurrentMediaTime()

        switch touches.count {
        case 1 where phase == .idle:
            beginOne(now)
        case 2:
            if phase == .one && (dragging || panningView || (moved && delegate?.inputMode == .trackpad)) {
                return  // already busy with a one-finger action; ignore the extra finger
            }
            cancelLongPress()
            if dragging { delegate?.gestureButton(0, down: false, at: nil); dragging = false }
            phase = .two
            twoMode = .undecided
            startDistance = distance(); lastDistance = startDistance
            startCentroid = centroid(); lastCentroid = startCentroid
            multiStartTime = now; lastTime = now
            multiMoved = false
            scrollVelocity = .zero
        case 3...:
            cancelLongPress()
            phase = .three
            startCentroid = centroid(); lastCentroid = startCentroid
            multiStartTime = now
        default:
            break
        }
    }

    private func beginOne(_ now: TimeInterval) {
        phase = .one
        let p = loc(touches[0])
        start = p; last = p
        startTime = now; lastTime = now
        moved = false; dragging = false; panningView = false; longPressFired = false
        speed = 0
        tapDragCandidate = now - lastTapTime < 0.32 && hypot(p.x - lastTapPoint.x, p.y - lastTapPoint.y) < 44
        cancelLongPress()
        let w = DispatchWorkItem { [weak self] in self?.fireLongPress() }
        longPressWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func moved(_ set: Set<UITouch>, event: UIEvent?) {
        let now = CACurrentMediaTime()
        switch phase {
        case .one:
            guard let t = touches.first else { return }
            let p = loc(t)
            let d = CGPoint(x: p.x - last.x, y: p.y - last.y)
            let dt = max(now - lastTime, 1.0 / 240)
            speed = speed * 0.6 + (hypot(d.x, d.y) / CGFloat(dt)) * 0.4
            last = p; lastTime = now
            let slop: CGFloat = delegate?.inputMode == .trackpad ? 4 : 9
            if !moved && hypot(p.x - start.x, p.y - start.y) > slop {
                moved = true
                cancelLongPress()
                guard let del = delegate else { return }
                if del.inputMode == .trackpad {
                    if tapDragCandidate { del.gestureButton(0, down: true, at: nil); dragging = true }
                } else if tapDragCandidate || !del.canPanView {
                    del.gestureButton(0, down: true, at: start)
                    dragging = true
                } else {
                    panningView = true
                }
            }
            guard moved, let del = delegate else { return }
            if del.inputMode == .trackpad {
                del.gestureMoveCursor(by: d, speed: speed)
            } else if dragging {
                del.gestureDragTo(p)
            } else if panningView {
                del.gesturePanView(by: d)
            }

        case .two:
            guard touches.count >= 2 else { return }
            let c = centroid(), dist = distance()
            let dt = max(now - lastTime, 1.0 / 240)
            if twoMode == .undecided {
                if abs(dist / startDistance - 1) > 0.12 {
                    twoMode = .zoom
                } else if hypot(c.x - startCentroid.x, c.y - startCentroid.y) > 8 {
                    twoMode = .scroll
                }
                if twoMode != .undecided { multiMoved = true }
            }
            let d = CGPoint(x: c.x - lastCentroid.x, y: c.y - lastCentroid.y)
            switch twoMode {
            case .zoom: delegate?.gestureZoom(scale: dist / lastDistance, focal: lastCentroid, pan: d)
            case .scroll:
                delegate?.gestureScroll(by: d)
                let v = CGPoint(x: d.x / CGFloat(dt), y: d.y / CGFloat(dt))
                scrollVelocity = CGPoint(x: scrollVelocity.x * 0.5 + v.x * 0.5, y: scrollVelocity.y * 0.5 + v.y * 0.5)
            case .undecided: break
            }
            lastCentroid = c; lastDistance = dist; lastTime = now

        case .three:
            if touches.count >= 3 { lastCentroid = centroid() }

        default:
            break
        }
    }

    func ended(_ set: Set<UITouch>, event: UIEvent?, cancelled: Bool = false) {
        let now = CACurrentMediaTime()
        let wasCount = touches.count
        touches.removeAll { set.contains($0) }

        switch phase {
        case .one:
            cancelLongPress()
            guard let del = delegate else { break }
            if dragging {
                del.gestureButton(0, down: false, at: del.inputMode == .touch ? last : nil)
            } else if !cancelled && !moved && !longPressFired && now - startTime < 0.4 {
                tapCount = tapDragCandidate ? min(tapCount + 1, 3) : 1
                del.gestureClick(button: 0, at: del.inputMode == .touch ? start : nil, count: tapCount)
                lastTapTime = now
                lastTapPoint = start
            }
            if !(!moved && !longPressFired) { lastTapTime = 0 }
            phase = .idle

        case .two:
            if twoMode == .scroll {
                delegate?.gestureScrollEnded(velocity: now - lastTime < 0.08 ? scrollVelocity : .zero)
            } else if !cancelled && !multiMoved && wasCount == 2 && now - multiStartTime < 0.35 && maxFingers == 2 {
                delegate?.gestureClick(button: 1, at: delegate?.inputMode == .touch ? startCentroid : nil, count: 1)
            }
            phase = touches.isEmpty ? .idle : .finishing

        case .three:
            // Decide on the first finger lift, using travel measured while all three were down.
            let d = CGPoint(x: lastCentroid.x - startCentroid.x, y: lastCentroid.y - startCentroid.y)
            if !cancelled {
                if hypot(d.x, d.y) < 25 && now - multiStartTime < 0.4 {
                    delegate?.gestureThreeFinger(nil)
                } else if abs(d.x) > abs(d.y), abs(d.x) > 60 {
                    delegate?.gestureThreeFinger(d.x < 0 ? .left : .right)
                } else if abs(d.y) > 60 {
                    delegate?.gestureThreeFinger(d.y < 0 ? .up : .down)
                }
            }
            phase = touches.isEmpty ? .idle : .finishing

        case .finishing, .idle:
            if touches.isEmpty { phase = .idle }
        }
        if touches.isEmpty { maxFingers = 0 }
    }

    private func fireLongPress() {
        guard phase == .one, !moved, touches.count == 1, let del = delegate else { return }
        longPressFired = true
        del.gestureLongPressFeedback()
        del.gestureClick(button: 1, at: del.inputMode == .touch ? start : nil, count: 1)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }
}
