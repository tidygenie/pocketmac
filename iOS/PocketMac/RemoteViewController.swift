import UIKit
import AVFoundation

/// Full-screen view of the Mac: shows the video, zoom/pan, and turns touches and
/// keys into Mac input.
final class RemoteViewController: UIViewController, GestureEngineDelegate {
    private let session: RemoteSession
    private let screenView = UIView()
    private let cursorRing = CAShapeLayer()
    private let keyInput = KeyInputView()
    private let keyboardBar = KeyboardBar()
    private var gestures: GestureEngine!

    private var remoteSize = CGSize(width: 16, height: 10)
    private var zoom: CGFloat = 1
    private var contentOrigin = CGPoint.zero
    private var cursor = CGPoint(x: 0.5, y: 0.5)   // normalised pointer position on the Mac
    private var keyboardOverlap: CGFloat = 0
    private var momentum: CADisplayLink?
    private var momentumVelocity = CGPoint.zero
    private var ringHide: DispatchWorkItem?
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    private var settings: ClientSettings { AppStore.shared.settings }

    init(session: RemoteSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = TouchForwardingView()
        v.backgroundColor = .black
        v.isMultipleTouchEnabled = true
        view = v
        gestures = GestureEngine(view: v)
        gestures.delegate = self
        v.engine = gestures
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        screenView.isUserInteractionEnabled = false
        screenView.backgroundColor = .black
        screenView.layer.addSublayer(session.renderer.layer)
        view.addSubview(screenView)

        cursorRing.path = UIBezierPath(ovalIn: CGRect(x: -14, y: -14, width: 28, height: 28)).cgPath
        cursorRing.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
        cursorRing.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
        cursorRing.lineWidth = 1.5
        cursorRing.opacity = 0
        view.layer.addSublayer(cursorRing)

        keyInput.frame = CGRect(x: -10, y: -10, width: 1, height: 1)
        keyInput.accessory = keyboardBar
        keyInput.onText = { [weak self] t in self?.typed(t) }
        keyInput.onBackspace = { [weak self] in self?.sendCombo(KeyMap.delete, flags: self?.takeModifiers() ?? 0) }
        keyboardBar.onKey = { [weak self] code, flags in self?.sendCombo(code, flags: flags) }
        keyboardBar.onHide = { [weak self] in self?.setKeyboard(false) }
        view.addSubview(keyInput)

        session.renderer.onSize = { [weak self] size in
            guard let self, size.width > 0, size.height > 0 else { return }
            if size != self.remoteSize { self.remoteSize = size; self.zoom = 1; self.layoutContent() }
        }
        session.onCursor = { [weak self] p in
            guard let self, !((self.view as? TouchForwardingView)?.isTouching ?? false) else { return }
            self.cursor = p
            self.updateRing()
        }
        session.controls.toggleKeyboard = { [weak self] in
            guard let self else { return }
            self.setKeyboard(!self.keyInput.isFirstResponder)
        }
        session.controls.resetZoom = { [weak self] in
            self?.zoom = 1
            self?.layoutContent()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        lightHaptic.prepare()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
    }

    // MARK: Viewport

    private var baseRect: CGRect { AVMakeRect(aspectRatio: remoteSize, insideRect: view.bounds) }

    /// Area not covered by the keyboard.
    private var visibleRect: CGRect {
        var r = view.bounds
        r.size.height = max(80, r.height - keyboardOverlap)
        return r
    }

    var canPanView: Bool {
        let f = screenView.frame, v = visibleRect
        return f.width > v.width + 2 || f.height > v.height + 2
    }

    var inputMode: InputMode { settings.inputMode }

    private func clamp(_ o: CGPoint, size: CGSize) -> CGPoint {
        let v = visibleRect
        func axis(_ o: CGFloat, _ c: CGFloat, _ lo: CGFloat, _ len: CGFloat) -> CGFloat {
            c <= len ? lo + (len - c) / 2 : min(lo, max(lo + len - c, o))
        }
        return CGPoint(x: axis(o.x, size.width, v.minX, v.width), y: axis(o.y, size.height, v.minY, v.height))
    }

    private func layoutContent() {
        let base = baseRect
        guard base.width > 0 else { return }
        let size = CGSize(width: base.width * zoom, height: base.height * zoom)
        if zoom <= 1.001 && keyboardOverlap == 0 { contentOrigin = base.origin }
        contentOrigin = clamp(contentOrigin, size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenView.frame = CGRect(origin: contentOrigin, size: size)
        session.renderer.layer.frame = screenView.bounds
        CATransaction.commit()
        updateRing()
        let z = zoom > 1.01
        if session.zoomed != z { session.zoomed = z }
    }

    private func toRemote(_ p: CGPoint) -> CGPoint {
        let f = screenView.frame
        guard f.width > 0, f.height > 0 else { return cursor }
        return CGPoint(x: min(max((p.x - f.minX) / f.width, 0), 1), y: min(max((p.y - f.minY) / f.height, 0), 1))
    }

    private func toView(_ n: CGPoint) -> CGPoint {
        let f = screenView.frame
        return CGPoint(x: f.minX + n.x * f.width, y: f.minY + n.y * f.height)
    }

    /// Keep the pointer on screen when zoomed in / keyboard up.
    private func follow(_ n: CGPoint) {
        guard canPanView else { return }
        let v = visibleRect.insetBy(dx: visibleRect.width * 0.12, dy: visibleRect.height * 0.12)
        let p = toView(n)
        var d = CGPoint.zero
        if p.x < v.minX { d.x = v.minX - p.x } else if p.x > v.maxX { d.x = v.maxX - p.x }
        if p.y < v.minY { d.y = v.minY - p.y } else if p.y > v.maxY { d.y = v.maxY - p.y }
        guard d != .zero else { return }
        contentOrigin.x += d.x
        contentOrigin.y += d.y
        layoutContent()
    }

    private func updateRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorRing.position = toView(cursor)
        CATransaction.commit()
    }

    private func flashRing() {
        guard inputMode == .trackpad else { return }
        cursorRing.opacity = 1
        ringHide?.cancel()
        let w = DispatchWorkItem { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            self?.cursorRing.opacity = 0
            CATransaction.commit()
        }
        ringHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    // MARK: GestureEngineDelegate

    func gestureTouchBegan() { stopMomentum() }

    func gestureMoveCursor(by d: CGPoint, speed: CGFloat) {
        let f = screenView.frame
        guard f.width > 0 else { return }
        let accel = 1 + min(1.6, speed / 1100)
        let k = CGFloat(settings.trackpadSpeed) * 1.15 * accel
        cursor.x = min(max(cursor.x + d.x * k / f.width, 0), 1)
        cursor.y = min(max(cursor.y + d.y * k / f.height, 0), 1)
        session.send(.mouseMove(x: Float(cursor.x), y: Float(cursor.y)))
        updateRing()
        flashRing()
        follow(cursor)
    }

    func gestureClick(button: UInt8, at point: CGPoint?, count: Int) {
        if let point { cursor = toRemote(point) }
        let x = Float(cursor.x), y = Float(cursor.y)
        let flags = takeModifiers()
        session.send(.mouseMove(x: x, y: y))
        session.send(.mouseButton(button: button, down: true, x: x, y: y, clicks: UInt8(count), flags: flags))
        session.send(.mouseButton(button: button, down: false, x: x, y: y, clicks: UInt8(count), flags: flags))
        updateRing()
        flashRing()
        if settings.haptics { (button == 1 ? mediumHaptic : lightHaptic).impactOccurred() }
    }

    func gestureButton(_ button: UInt8, down: Bool, at point: CGPoint?) {
        if let point { cursor = toRemote(point) }
        let x = Float(cursor.x), y = Float(cursor.y)
        if down { session.send(.mouseMove(x: x, y: y)) }
        session.send(.mouseButton(button: button, down: down, x: x, y: y, clicks: 1, flags: down ? takeModifiers() : 0))
        if down, settings.haptics { lightHaptic.impactOccurred() }
    }

    func gestureDragTo(_ point: CGPoint) {
        cursor = toRemote(point)
        session.send(.mouseMove(x: Float(cursor.x), y: Float(cursor.y)))
        follow(cursor)
    }

    func gestureScroll(by d: CGPoint) {
        let sign: CGFloat = settings.reverseScroll ? -1 : 1
        session.send(.scroll(dx: Float(d.x * 1.6 * sign), dy: Float(d.y * 1.6 * sign)))
    }

    func gestureScrollEnded(velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 250 else { return }
        momentumVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func momentumStep(_ link: CADisplayLink) {
        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        gestureScroll(by: CGPoint(x: momentumVelocity.x * dt, y: momentumVelocity.y * dt))
        let decay = pow(0.94, dt * 60)
        momentumVelocity = CGPoint(x: momentumVelocity.x * decay, y: momentumVelocity.y * decay)
        if hypot(momentumVelocity.x, momentumVelocity.y) < 30 { stopMomentum() }
    }

    private func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }

    func gestureZoom(scale: CGFloat, focal: CGPoint, pan: CGPoint) {
        let base = baseRect
        let n = CGPoint(x: (focal.x - screenView.frame.minX) / screenView.frame.width,
                        y: (focal.y - screenView.frame.minY) / screenView.frame.height)
        zoom = min(max(zoom * scale, 1), 6)
        let size = CGSize(width: base.width * zoom, height: base.height * zoom)
        contentOrigin = CGPoint(x: focal.x + pan.x - n.x * size.width, y: focal.y + pan.y - n.y * size.height)
        layoutContent()
    }

    func gesturePanView(by d: CGPoint) {
        contentOrigin.x += d.x
        contentOrigin.y += d.y
        layoutContent()
    }

    func gestureThreeFinger(_ direction: UISwipeGestureRecognizer.Direction?) {
        let ctrl = ModifierFlag.control
        switch direction {
        case .none: setKeyboard(!keyInput.isFirstResponder)
        case .some(.left): sendCombo(KeyMap.right, flags: ctrl)    // fingers left → next Space
        case .some(.right): sendCombo(KeyMap.left, flags: ctrl)
        case .some(.up): sendCombo(KeyMap.up, flags: ctrl)         // Mission Control
        case .some(.down): sendCombo(KeyMap.down, flags: ctrl)     // App windows
        default: break
        }
        if settings.haptics { mediumHaptic.impactOccurred() }
    }

    func gestureLongPressFeedback() {
        if settings.haptics { mediumHaptic.impactOccurred() }
    }

    // MARK: Keyboard

    private func setKeyboard(_ on: Bool) {
        if on { keyInput.becomeFirstResponder() } else { keyInput.resignFirstResponder() }
        session.keyboardVisible = on
    }

    @objc private func keyboardFrame(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let local = view.convert(end, from: nil)
        keyboardOverlap = max(0, view.bounds.maxY - local.minY)
        layoutContent()
        follow(cursor)
    }

    @objc private func keyboardHidden(_ n: Notification) {
        keyboardOverlap = 0
        session.keyboardVisible = false
        layoutContent()
    }

    private func takeModifiers() -> UInt32 {
        let m = keyboardBar.activeModifiers
        keyboardBar.clearOneShot()
        return m
    }

    private func typed(_ text: String) {
        let mods = keyboardBar.activeModifiers
        let shortcut = mods & (ModifierFlag.command | ModifierFlag.control | ModifierFlag.option) != 0
        if text == "\n" || text == "\r" {
            sendCombo(KeyMap.returnKey, flags: takeModifiers())
        } else if shortcut, text.count == 1, let ch = text.first, let (code, shift) = KeyMap.code(for: ch) {
            sendCombo(code, flags: takeModifiers() | (shift ? ModifierFlag.shift : 0))
        } else {
            if mods & ModifierFlag.shift != 0 { keyboardBar.clearOneShot() }
            session.send(.text(text))
        }
    }

    /// Presses modifiers like a real keyboard: ⌘ down, C down, C up, ⌘ up.
    private func sendCombo(_ code: UInt16, flags: UInt32) {
        let mods: [(UInt32, UInt16)] = [(ModifierFlag.control, 59), (ModifierFlag.option, 58),
                                        (ModifierFlag.shift, 56), (ModifierFlag.command, 55)]
        var held: UInt32 = 0
        for (flag, key) in mods where flags & flag != 0 {
            held |= flag
            session.send(.key(code: key, down: true, flags: held))
        }
        session.send(.key(code: code, down: true, flags: flags))
        session.send(.key(code: code, down: false, flags: flags))
        for (flag, key) in mods.reversed() where flags & flag != 0 {
            held &= ~flag
            session.send(.key(code: key, down: false, flags: held))
        }
    }
}

/// Forwards raw touches to the gesture engine.
final class TouchForwardingView: UIView {
    weak var engine: GestureEngine?
    private(set) var isTouching = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        isTouching = true
        engine?.began(touches, event: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { engine?.moved(touches, event: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        engine?.ended(touches, event: event)
        isTouching = (event?.allTouches?.contains { $0.phase != .ended && $0.phase != .cancelled }) ?? false
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        engine?.ended(touches, event: event, cancelled: true)
        isTouching = false
    }
}
