import CoreText
import XCTest
@testable import StudioKit

/// The screen templates and layer presets (plan 23 step 5), and the font choices the text inspector offers.
final class OverlayTemplateTests: XCTestCase {
    func testScreensUseOnlyColourTextCameraAndGame() {
        for t in SceneTemplate.allCases where t.isScreen {
            let s = t.scene()
            XCTAssertEqual(s.name, t.name)
            for c in Canvas.allCases {
                let comp = s.composition(c), size = c.size(.hd)
                XCTAssertFalse(comp.layers.isEmpty, "\(t) \(c)")
                XCTAssertEqual(Set(comp.layers.map(\.id)).count, comp.layers.count)
                for l in comp.layers {
                    XCTAssertTrue(["color", "text", "camera", "game"].contains(l.source.type), "\(t) \(c): \(l.source.type) — no bundled artwork")
                    let r = l.frame.rect(in: size)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(r), "\(t) \(c) \(l.displayName) leaves the canvas: \(r)")
                }
                // Every title is large and every line of text fits its box.
                for l in comp.layers where l.source.type == "text" {
                    let spec = l.source.text!, box = l.frame.rect(in: size).size
                    let layout = TextRasterizer.layout(spec, string: OverlayTokens(elapsed: 3725).replace(spec.string), size: box)
                    XCTAssertLessThanOrEqual(layout.block.width, box.width + 0.5, "\(t) \(c) \(l.displayName)")
                    if l.name == "Title" { XCTAssertGreaterThan(layout.fontSize, c == .wide ? 80 : 60, "\(t) \(c) title is \(layout.fontSize) px") }
                }
            }
        }
        XCTAssertTrue(SceneTemplate.ending.scene().wide.layers.contains { $0.source.type == "camera" })
        XCTAssertTrue(SceneTemplate.beRightBack.scene().vertical.layers.contains { $0.source.text?.string.contains("{timer}") == true })
        XCTAssertTrue(SceneTemplate.startingSoon.scene().wide.layers.contains { $0.source.text?.string.contains("{time}") == true })
        XCTAssertEqual(SceneCollection.defaults().scenes.map(\.name), ["Gameplay", "Game Only", "Camera Focus", "Just Camera"], "first launch is unchanged")
    }

    func testNameTagPreset() throws {
        for c in Canvas.allCases {
            var comp = SceneTemplate.gameplay.scene().composition(c)
            let n = comp.layers.count
            let id = try LayerPreset.nameTag.apply(to: &comp, canvas: c.size(.hd)).get()
            XCTAssertEqual(comp.layers.count, n + 1)
            let l = try XCTUnwrap(comp.layers.last)
            XCTAssertEqual(l.id, id); XCTAssertEqual(l.source.type, "text")
            XCTAssertNotNil(l.source.text?.plate); XCTAssertEqual(l.source.text?.alignment, "left")
            XCTAssertLessThan(l.frame.x, 0.1); XCTAssertGreaterThan(l.frame.y, 0.8, "bottom left")
        }
    }

    func testCameraFramePresetRingsTheCamera() throws {
        let size = Canvas.wide.size(.hd)
        var comp = SceneTemplate.gameplay.scene().wide
        let ci = try XCTUnwrap(comp.layers.firstIndex { $0.source.type == "camera" })
        let cam = comp.layers[ci]
        let id = try LayerPreset.cameraFrame.apply(to: &comp, canvas: size).get()
        let ri = try XCTUnwrap(comp.layers.firstIndex { $0.id == id })
        XCTAssertEqual(ri, ci)
        XCTAssertEqual(id, cam.id)
        XCTAssertEqual(comp.layers[ri].frame, cam.frame)
        XCTAssertEqual(comp.layers[ri].frameWidth * size.height, (size.height * 0.009).rounded(), accuracy: 0.01)
        XCTAssertEqual(comp.layers[ri].frameColor, ScreenStyle.blue)
        var none = SceneTemplate.gameOnly.scene().wide
        XCTAssertThrowsError(try LayerPreset.cameraFrame.apply(to: &none, canvas: size).get())
    }

    func testFontFamiliesHonourTheWeight() throws {
        let family = try XCTUnwrap(TextRasterizer.families.first, "no listed family installed")
        func name(_ weight: String) -> String {
            CTFontCopyPostScriptName(TextRasterizer.font(TextSpec(fontName: family, weight: weight), size: 40)) as String
        }
        XCTAssertNotEqual(name("regular"), name("heavy"), "\(family) regular and heavy are different faces")
        XCTAssertEqual(CTFontCopyFamilyName(TextRasterizer.font(TextSpec(fontName: family), size: 40)) as String, family)
        // A face name still works, and a missing font falls back to the system font.
        XCTAssertEqual(CTFontCopyPostScriptName(TextRasterizer.font(TextSpec(fontName: "Menlo-Bold"), size: 40)) as String, "Menlo-Bold")
        let missing = TextRasterizer.font(TextSpec(fontName: "NoSuchFont-ElgatoHDR"), size: 40)
        XCTAssertEqual(CTFontCopyFamilyName(missing) as String, CTFontCopyFamilyName(TextRasterizer.font(TextSpec(), size: 40)) as String)
    }

    func testTextLayerListsItsWords() {
        var l = Layer(source: LayerSource(type: "text", text: TextSpec(string: "Hello\nthere")))
        XCTAssertEqual(l.displayName, "Hello")
        l.name = "Title"
        XCTAssertEqual(l.displayName, "Title")
        XCTAssertTrue(l.isOverlay)
        XCTAssertFalse(Layer(source: .game).isOverlay)
    }
}
