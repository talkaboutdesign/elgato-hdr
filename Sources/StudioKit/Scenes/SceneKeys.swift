import AppKit

/// The live keys that menus cannot express. macOS takes ⌃Space (input sources) and ⌃← / ⌃→ (Mission Control) before
/// an app sees them, so the defaults add ⇧. Nothing here fires while a text field has keyboard focus: there arrow keys,
/// ⌫ and ⌃Z belong to the text.
enum SceneKeys {
    static let space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    /// Hold to punch in; menus cannot see key-up, so this is a key monitor.
    static let holdModifiers: NSEvent.ModifierFlags = [.control, .shift]
    /// Next and previous scene, with ← and →.
    static let stepModifiers: NSEvent.ModifierFlags = [.control, .shift]
    static let holdLabel = "⌃⇧Space", nextLabel = "⌃⇧→", previousLabel = "⌃⇧←"

    /// `consume`: swallow the event without acting (repeats of a held key).
    enum Action: Equatable { case punchIn(Bool), moveFocus(dx: CGFloat, dy: CGFloat), consume }

    /// What a key event does. `mods` are the device-independent flags; `spaceHeld` whether a hold is in progress.
    static func action(keyCode: UInt16, keyDown: Bool, isRepeat: Bool, mods: NSEvent.ModifierFlags,
                       textFocused: Bool, punchedIn: Bool, spaceHeld: Bool) -> Action? {
        let m = mods.intersection([.command, .control, .option, .shift])
        if keyCode == space {
            // The release always ends a hold, even if focus moved into a text field meanwhile.
            if !keyDown { return spaceHeld ? .punchIn(false) : nil }
            guard !textFocused, m == holdModifiers else { return nil }
            return isRepeat || spaceHeld ? .consume : .punchIn(true)
        }
        guard keyDown, punchedIn, !textFocused, m.subtracting(.shift).isEmpty else { return nil }
        let step: CGFloat = m.contains(.shift) ? 0.2 : 0.1
        switch keyCode {
        case left: return .moveFocus(dx: -step, dy: 0)
        case right: return .moveFocus(dx: step, dy: 0)
        case down: return .moveFocus(dx: 0, dy: step)
        case up: return .moveFocus(dx: 0, dy: -step)
        default: return nil
        }
    }

    /// Whether the key window's first responder is editing text (a field editor or a text view).
    static func textFocused(_ responder: NSResponder?) -> Bool { responder is NSText }
}
