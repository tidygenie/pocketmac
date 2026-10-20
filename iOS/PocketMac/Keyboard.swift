import UIKit

enum ModifierFlag {
    static let shift: UInt32 = 0x20000
    static let control: UInt32 = 0x40000
    static let option: UInt32 = 0x80000
    static let command: UInt32 = 0x100000
}

/// macOS virtual key codes (US ANSI layout) for shortcuts like ⌘C.
enum KeyMap {
    static let returnKey: UInt16 = 36, tab: UInt16 = 48, space: UInt16 = 49, delete: UInt16 = 51, escape: UInt16 = 53
    static let forwardDelete: UInt16 = 117, left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
    static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// Key code and whether Shift is implied (e.g. "A", "?").
    static func code(for ch: Character) -> (UInt16, Bool)? {
        if let c = codes[ch] { return (c, false) }
        if let base = shifted[ch], let c = codes[base] { return (c, true) }
        let lower = Character(ch.lowercased())
        if lower != ch, let c = codes[lower] { return (c, true) }
        return nil
    }
}

/// Invisible first responder that turns the iOS keyboard into Mac keystrokes.
final class KeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var accessory: UIView?

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { accessory }

    var hasText: Bool { true }   // keeps ⌫ always enabled
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }

    // UITextInputTraits — no autocorrect, so every key is sent as typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
}

/// The bar above the keyboard: Esc, Tab, sticky ⌘⌥⌃⇧, arrows and common shortcuts.
final class KeyboardBar: UIInputView {
    enum Item {
        case key(String, UInt16, UInt32)   // title, code, flags
        case modifier(String, UInt32)
        case hide
    }

    var onKey: ((UInt16, UInt32) -> Void)?
    var onModifiersChanged: ((UInt32) -> Void)?
    var onHide: (() -> Void)?
    private(set) var oneShot: UInt32 = 0
    private(set) var locked: UInt32 = 0
    private var modifierButtons: [UInt32: UIButton] = [:]
    private var lastModifierTap: [UInt32: TimeInterval] = [:]

    var activeModifiers: UInt32 { oneShot | locked }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
        let cmd = ModifierFlag.command
        let items: [Item] = [
            .hide,
            .key("esc", KeyMap.escape, 0), .key("tab", KeyMap.tab, 0),
            .modifier("⌘", cmd), .modifier("⌥", ModifierFlag.option), .modifier("⌃", ModifierFlag.control),
            .modifier("⇧", ModifierFlag.shift),
            .key("←", KeyMap.left, 0), .key("↑", KeyMap.up, 0), .key("↓", KeyMap.down, 0), .key("→", KeyMap.right, 0),
            .key("⌦", KeyMap.forwardDelete, 0),
            .key("⌘C", 8, cmd), .key("⌘V", 9, cmd), .key("⌘X", 7, cmd), .key("⌘Z", 6, cmd),
            .key("⌘A", 0, cmd), .key("⌘F", 3, cmd), .key("⌘S", 1, cmd), .key("⌘W", 13, cmd), .key("⌘T", 17, cmd),
            .key("⌘Tab", KeyMap.tab, cmd), .key("⌘Space", KeyMap.space, cmd),
            .key("home", KeyMap.home, 0), .key("end", KeyMap.end, 0), .key("pg↑", KeyMap.pageUp, 0), .key("pg↓", KeyMap.pageDown, 0),
        ] + KeyMap.functionKeys.enumerated().map { .key("F\($0.offset + 1)", $0.element, 0) }

        for item in items { stack.addArrangedSubview(button(for: item)) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(for item: Item) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = UIColor.secondarySystemFill
        cfg.baseForegroundColor = .label
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        let b = UIButton(configuration: cfg)
        switch item {
        case let .key(title, code, flags):
            b.configuration?.title = title
            b.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onKey?(code, flags | self.activeModifiers)
                self.clearOneShot()
            }, for: .touchUpInside)
        case let .modifier(title, flag):
            b.configuration?.title = title
            modifierButtons[flag] = b
            b.addAction(UIAction { [weak self] _ in self?.tapModifier(flag) }, for: .touchUpInside)
        case .hide:
            b.configuration?.image = UIImage(systemName: "keyboard.chevron.compact.down")
            b.addAction(UIAction { [weak self] _ in self?.onHide?() }, for: .touchUpInside)
        }
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        return b
    }

    /// Tap = next key only (orange). Double-tap = locked (blue). Tap again = off.
    private func tapModifier(_ flag: UInt32) {
        let now = CACurrentMediaTime()
        if locked & flag != 0 {
            locked &= ~flag
        } else if oneShot & flag != 0 {
            oneShot &= ~flag
            if now - (lastModifierTap[flag] ?? 0) < 0.4 { locked |= flag }
        } else {
            oneShot |= flag
        }
        lastModifierTap[flag] = now
        refresh()
    }

    func clearOneShot() {
        guard oneShot != 0 else { return }
        oneShot = 0
        refresh()
    }

    private func refresh() {
        for (flag, b) in modifierButtons {
            b.configuration?.baseBackgroundColor = locked & flag != 0 ? .systemBlue
                : oneShot & flag != 0 ? .systemOrange : .secondarySystemFill
        }
        onModifiersChanged?(activeModifiers)
    }
}
