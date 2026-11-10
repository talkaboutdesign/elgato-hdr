import AppKit
import XCTest
@testable import StudioKit

/// macOS takes ⌃Space and ⌃← / ⌃→ before the app; the scene keys use ⌃⇧, and none fire while a text field is focused.
final class SceneKeysTests: XCTestCase {
    func act(_ key: UInt16, down: Bool = true, rep: Bool = false, _ mods: NSEvent.ModifierFlags, text: Bool = false,
             zoomed: Bool = false, held: Bool = false) -> SceneKeys.Action? {
        SceneKeys.action(keyCode: key, keyDown: down, isRepeat: rep, mods: mods, textFocused: text, punchedIn: zoomed, spaceHeld: held)
    }

    func testHoldToPunchInIsControlShiftSpace() {
        XCTAssertEqual(act(SceneKeys.space, [.control, .shift]), .punchIn(true))
        XCTAssertNil(act(SceneKeys.space, .control), "⌃Space belongs to input sources")
        XCTAssertNil(act(SceneKeys.space, []))
        XCTAssertEqual(act(SceneKeys.space, rep: true, [.control, .shift], held: true), .consume, "repeats are swallowed")
        XCTAssertEqual(act(SceneKeys.space, down: false, [], held: true), .punchIn(false), "releasing ends the hold whatever the modifiers")
        XCTAssertNil(act(SceneKeys.space, down: false, [], held: false))
        // Caps Lock and the like do not matter.
        XCTAssertEqual(act(SceneKeys.space, [.control, .shift, .capsLock]), .punchIn(true))
    }

    func testNothingFiresWhileTyping() {
        XCTAssertNil(act(SceneKeys.space, [.control, .shift], text: true))
        for k in [SceneKeys.left, SceneKeys.right, SceneKeys.up, SceneKeys.down] {
            XCTAssertNil(act(k, [], text: true, zoomed: true), "arrow \(k) stays with the text field")
            XCTAssertNotNil(act(k, [], zoomed: true))
        }
        // A hold that started before focus moved into a field still ends on release.
        XCTAssertEqual(act(SceneKeys.space, down: false, [], text: true, held: true), .punchIn(false))
        XCTAssertTrue(SceneKeys.textFocused(NSTextView()))
        XCTAssertFalse(SceneKeys.textFocused(NSView()))
        XCTAssertFalse(SceneKeys.textFocused(nil))
    }

    func testArrowsMoveTheZoomOnlyWhileZoomed() {
        XCTAssertEqual(act(SceneKeys.left, [], zoomed: true), .moveFocus(dx: -0.1, dy: 0))
        XCTAssertEqual(act(SceneKeys.up, [.shift], zoomed: true), .moveFocus(dx: 0, dy: -0.2))
        XCTAssertNil(act(SceneKeys.left, []), "not zoomed: arrows nudge the selected layer instead")
        XCTAssertNil(act(SceneKeys.right, [.control, .shift], zoomed: true), "⌃⇧→ is Next Scene")
    }

    func testMenuDefaults() {
        XCTAssertEqual(SceneKeys.stepModifiers, [.control, .shift])
        XCTAssertEqual(SceneKeys.holdModifiers, [.control, .shift])
        XCTAssertEqual([SceneKeys.holdLabel, SceneKeys.previousLabel, SceneKeys.nextLabel], ["⌃⇧Space", "⌃⇧←", "⌃⇧→"])
    }
}
