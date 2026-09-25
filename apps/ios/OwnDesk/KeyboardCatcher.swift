import OwnDeskProtocol
import OwnDeskTouch
import UIKit

protocol KeyboardCatcherDelegate: AnyObject {
    func keyboardTyped(_ text: String)
    func keyboardKey(_ code: String, modifiers: [Modifier], down: Bool)
    func keyboardClosed()
}

/// Something for the soft keyboard to type into. What it types is forwarded as text, which is the
/// only way a phone keyboard produces characters faithfully in any language; Return and Backspace,
/// which are not text, go as keys.
///
/// Above the keyboard sits a bar with what an iPhone keyboard lacks and a Mac needs: Escape, Tab,
/// the arrows, and the modifiers. A modifier tapped there applies to the next key or character, so
/// ⌘ then C sends Command-C.
final class KeyboardCatcher: UIView, UIKeyInput {
    weak var delegate: KeyboardCatcherDelegate?
    private lazy var bar = KeyBar(
        onKey: { [weak self] code in self?.tapKey(code) },
        onHide: { [weak self] in _ = self?.resignFirstResponder() })
    /// Hardware presses that went to the Mac as keys, so their release goes the same way.
    private var sentAsKeys = Set<UIPress>()

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }

    // No autocorrect, no capitals, no smart punctuation: this is a remote keyboard, so what the
    // finger presses is what the Mac should receive.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    /// Always true, so Backspace keeps working on what is already on the Mac.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        let held = bar.takeModifiers()
        if text == "\n" {
            press("Enter", held)
            return
        }
        // A character typed with a modifier held is a shortcut, which has to be a key press:
        // a Command-held "c" is not text.
        if !held.isEmpty, text.count == 1, let character = text.first, let key = KeyCodes.key(for: character) {
            var modifiers = held
            if key.shift, !modifiers.contains(.shift) { modifiers.insert(.shift, at: 0) }
            press(key.code, modifiers)
            return
        }
        delegate?.keyboardTyped(text)
    }

    func deleteBackward() {
        press("Backspace", bar.takeModifiers())
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            bar.clearModifiers()
            delegate?.keyboardClosed()
        }
        return resigned
    }

    private func tapKey(_ code: String) {
        press(code, bar.takeModifiers())
    }

    private func press(_ code: String, _ modifiers: [Modifier]) {
        delegate?.keyboardKey(code, modifiers: modifiers, down: true)
        delegate?.keyboardKey(code, modifiers: modifiers, down: false)
    }

    // A hardware keyboard while this has focus: printable keys become text through insertText, as
    // soft-keyboard typing does, and everything else goes to the Mac as a key.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, HardwareKeys.isKeyNotText(key), !HardwareKeys.isModifierOnly(key),
               let delegate, HardwareKeys.send(press, down: true, to: delegate) {
                sentAsKeys.insert(press)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = release(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = release(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for press in presses {
            if sentAsKeys.remove(press) != nil, let delegate {
                _ = HardwareKeys.send(press, down: false, to: delegate)
            } else {
                rest.insert(press)
            }
        }
        return rest
    }
}

/// Hardware keyboards. `UIKey.keyCode` is the USB HID usage, which the shared table names.
enum HardwareKeys {
    static func modifiers(_ flags: UIKeyModifierFlags) -> [Modifier] {
        var out: [Modifier] = []
        if flags.contains(.shift) { out.append(.shift) }
        if flags.contains(.control) { out.append(.control) }
        if flags.contains(.alternate) { out.append(.alt) }
        if flags.contains(.command) { out.append(.meta) }
        if flags.contains(.alphaShift) { out.append(.capslock) }
        return out
    }

    /// Sends a press to the Mac as a key. False when the Mac has no such key, so the caller can pass
    /// it on to the system instead.
    static func send(_ press: UIPress, down: Bool, to delegate: KeyboardCatcherDelegate) -> Bool {
        guard let key = press.key, let code = KeyCodes.w3cCode(forHID: key.keyCode.rawValue) else { return false }
        delegate.keyboardKey(code, modifiers: modifiers(key.modifierFlags), down: down)
        return true
    }

    /// Whether a press should reach the Mac as a key rather than as text: anything held with ⌘, ⌃
    /// or ⌥, and every key that types nothing, such as the arrows, Escape, Tab, Return, Backspace and
    /// the function keys.
    static func isKeyNotText(_ key: UIKey) -> Bool {
        if !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty { return true }
        let characters = key.charactersIgnoringModifiers
        guard !characters.hasPrefix("UIKeyInput"), let scalar = characters.unicodeScalars.first else { return true }
        return scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value)
    }

    /// Shift, Control, Option or Command on its own. While typing text these ride along as flags on
    /// the keys they change, rather than going to the Mac as keys held down.
    static func isModifierOnly(_ key: UIKey) -> Bool {
        (0xE0...0xE7).contains(key.keyCode.rawValue)
    }
}

/// The row above the soft keyboard.
final class KeyBar: UIInputView {
    private let onKey: (String) -> Void
    private let onHide: () -> Void
    private var held: [Modifier] = []
    private var modifierButtons: [Modifier: UIButton] = [:]

    init(onKey: @escaping (String) -> Void, onHide: @escaping () -> Void) {
        self.onKey = onKey
        self.onHide = onHide
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    /// The modifiers tapped since the last key, in the order the wire lists them, and forgets them:
    /// each applies to one key only.
    func takeModifiers() -> [Modifier] {
        let order: [Modifier] = [.shift, .control, .alt, .meta]
        let taken = order.filter(held.contains)
        clearModifiers()
        return taken
    }

    func clearModifiers() {
        held.removeAll()
        modifierButtons.values.forEach { style($0, on: false) }
    }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        row.addArrangedSubview(key("esc", code: "Escape"))
        row.addArrangedSubview(key("tab", code: "Tab"))
        for (label, modifier) in [("⇧", Modifier.shift), ("⌃", .control), ("⌥", .alt), ("⌘", .meta)] {
            let button = keyButton(title: label, id: "key-\(modifier.rawValue)") { [weak self] in self?.toggle(modifier) }
            modifierButtons[modifier] = button
            row.addArrangedSubview(button)
        }
        for (symbol, code) in [("arrow.left", "ArrowLeft"), ("arrow.up", "ArrowUp"), ("arrow.down", "ArrowDown"), ("arrow.right", "ArrowRight")] {
            row.addArrangedSubview(keyButton(symbol: symbol, id: "key-\(code)") { [weak self] in self?.onKey(code) })
        }
        // Kept out of the scrolling row, so closing the keyboard never means hunting for the key.
        let hide = keyButton(symbol: "keyboard.chevron.compact.down", id: "key-hide") { [weak self] in self?.onHide() }
        hide.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hide)

        NSLayoutConstraint.activate([
            hide.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            hide.heightAnchor.constraint(equalToConstant: 34),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func key(_ title: String, code: String) -> UIButton {
        keyButton(title: title, id: "key-\(code)") { [weak self] in self?.onKey(code) }
    }

    private func keyButton(title: String? = nil, symbol: String? = nil, id: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        if let symbol { config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)) }
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = id
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        style(button, on: false)
        return button
    }

    private func style(_ button: UIButton, on: Bool) {
        button.configuration?.baseBackgroundColor = on ? UIColor(Theme.accent) : UIColor(white: 0.32, alpha: 1)
        button.configuration?.baseForegroundColor = .white
    }

    private func toggle(_ modifier: Modifier) {
        if let index = held.firstIndex(of: modifier) { held.remove(at: index) } else { held.append(modifier) }
        if let button = modifierButtons[modifier] { style(button, on: held.contains(modifier)) }
    }
}
