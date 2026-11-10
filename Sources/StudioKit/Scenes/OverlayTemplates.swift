// Screens for the parts of a stream that are not gameplay (Starting Soon, Be Right Back, Ending) and two layer
// presets (Name Tag, Camera Frame). Built only from colour, text, camera and game layers, with nothing bundled, and
// laid out separately for 16:9 and 9:16 so each canvas reads well on its own.
import CoreGraphics
import Foundation

/// Colours of the built-in screens, SDR sRGB code values.
enum ScreenStyle {
    static let ink: [Double] = [0.043, 0.047, 0.067, 1]
    static let toneA: [Double] = [0.071, 0.078, 0.11, 1]
    static let toneB: [Double] = [0.098, 0.106, 0.15, 1]
    static let white: [Double] = [1, 1, 1, 1]
    static let muted: [Double] = [0.66, 0.69, 0.78, 1]
    static let plate: [Double] = [0.07, 0.075, 0.10, 0.88]
    static let livePlate: [Double] = [0.86, 0.16, 0.22, 0.95]
    static let blue: [Double] = [0.42, 0.49, 1, 1]
    static let amber: [Double] = [1, 0.71, 0.27, 1]
    static let pink: [Double] = [0.87, 0.33, 0.96, 1]
}

extension Layer {
    static func text(_ string: String, name: String, frame: NRect, weight: String = "semibold", color: [Double] = ScreenStyle.white,
                     alignment: String = "center", plate: [Double]? = nil, plateRadius: Double = 0.3, shadow: Bool = false) -> Layer {
        Layer(name: name, source: LayerSource(type: "text", text: TextSpec(string: string, weight: weight, color: color, alignment: alignment,
                                                                            plate: plate, plateRadius: plateRadius, shadow: shadow)), frame: frame)
    }
    static func color(_ c: [Double], name: String, frame: NRect = .full, roundness: Double = 0) -> Layer {
        Layer(name: name, source: LayerSource(type: "color", color: c), frame: frame, roundness: roundness)
    }
}

extension SceneTemplate {
    /// Full-screen moments rather than gameplay layouts; the gallery lists them separately.
    var isScreen: Bool { self == .startingSoon || self == .beRightBack || self == .ending }

    func screen(mirror: Bool) -> Scene {
        let wide = Canvas.wide.size(.hd), tall = Canvas.vertical.size(.hd)
        /// The background in two steps lighter towards the bottom: reads as a soft gradient on any screen.
        func tones(_ v: Bool) -> [Layer] {
            [.color(ScreenStyle.toneA, name: "Lower Tone", frame: NRect(x: 0, y: v ? 0.70 : 0.66, w: 1, h: v ? 0.30 : 0.34)),
             .color(ScreenStyle.toneB, name: "Bottom Tone", frame: NRect(x: 0, y: v ? 0.86 : 0.84, w: 1, h: v ? 0.14 : 0.16))]
        }
        /// Accent rule, title and subtitle: left-aligned on 16:9, centred on 9:16.
        func headline(_ title: String, _ subtitle: String, accent: [Double], v: Bool, x: Double = 0.08) -> [Layer] {
            if v {
                return [.color(accent, name: "Accent", frame: NRect(x: 0.44, y: 0.392, w: 0.12, h: 0.0045), roundness: 0.5),
                        .text(title, name: "Title", frame: NRect(x: 0.09, y: 0.405, w: 0.82, h: 0.075), weight: "heavy"),
                        .text(subtitle, name: "Subtitle", frame: NRect(x: 0.1, y: 0.49, w: 0.8, h: 0.028), weight: "medium", color: ScreenStyle.muted)]
            }
            // The block (rule, title, subtitle) sits on the canvas's centre line, above the lighter floor.
            return [.color(accent, name: "Accent", frame: NRect(x: x, y: 0.385, w: 0.045, h: 0.008), roundness: 0.5),
                    .text(title, name: "Title", frame: NRect(x: x, y: 0.41, w: 0.94 - x, h: 0.15), weight: "heavy", alignment: "left"),
                    .text(subtitle, name: "Subtitle", frame: NRect(x: x, y: 0.575, w: min(0.6, 0.94 - x), h: 0.05), weight: "medium", color: ScreenStyle.muted, alignment: "left")]
        }
        func clock(v: Bool) -> Layer {
            .text("{time}", name: "Clock", frame: v ? NRect(x: 0.36, y: 0.06, w: 0.28, h: 0.032) : NRect(x: 0.85, y: 0.06, w: 0.1, h: 0.055),
                  weight: "semibold", color: ScreenStyle.muted, plate: [1, 1, 1, 0.07], plateRadius: 0.5)
        }
        func live(v: Bool) -> Layer {
            .text("LIVE {timer}", name: "Live Timer", frame: v ? NRect(x: 0.34, y: 0.06, w: 0.32, h: 0.032) : NRect(x: 0.83, y: 0.06, w: 0.12, h: 0.055),
                  weight: "bold", plate: ScreenStyle.livePlate, plateRadius: 0.5)
        }
        /// The camera in a circle with an accent ring, the ring being a slightly larger disc beneath it.
        func portrait(_ frame: CGRect, canvas: CGSize, accent: [Double]) -> [Layer] {
            let pad = (min(canvas.width, canvas.height) * 0.011).rounded()
            var cam = Layer(name: "Camera", source: .camera, frame: NRect(frame, in: canvas), roundness: 0.5, mirror: mirror)
            cam.shadow = true
            return [.color(accent, name: "Camera Ring", frame: NRect(frame.insetBy(dx: -pad, dy: -pad), in: canvas), roundness: 0.5), cam]
        }
        func comp(_ layers: [Layer]) -> Composition { Composition(background: ScreenStyle.ink, layers: layers) }
        switch self {
        case .startingSoon:
            return Scene(name: name, wide: comp(tones(false) + headline("Starting Soon", "Grab a drink, we start in a moment", accent: ScreenStyle.blue, v: false) + [clock(v: false)]),
                         vertical: comp(tones(true) + headline("Starting Soon", "Grab a drink, we start in a moment", accent: ScreenStyle.blue, v: true) + [clock(v: true)]))
        case .beRightBack:
            return Scene(name: name, wide: comp(tones(false) + headline("Be Right Back", "Stay tuned, back in a moment", accent: ScreenStyle.amber, v: false) + [live(v: false)]),
                         vertical: comp(tones(true) + headline("Be Right Back", "Stay tuned, back in a moment", accent: ScreenStyle.amber, v: true) + [live(v: true)]))
        default:
            let side = (wide.height * 0.5).rounded(), wr = CGRect(x: (wide.width * 0.1).rounded(), y: ((wide.height - side) / 2).rounded(), width: side, height: side)
            let vs = (tall.width * 0.56).rounded(), vr = CGRect(x: ((tall.width - vs) / 2).rounded(), y: (tall.height * 0.19).rounded(), width: vs, height: vs)
            var vText = headline("Thanks for Watching", "See you next stream", accent: ScreenStyle.pink, v: true)
            for i in vText.indices { vText[i].frame.y += 0.16 }
            return Scene(name: name,
                         wide: comp(tones(false) + portrait(wr, canvas: wide, accent: ScreenStyle.pink) + headline("Thanks for Watching", "See you next stream", accent: ScreenStyle.pink, v: false, x: 0.44)),
                         vertical: comp(tones(true) + portrait(vr, canvas: tall, accent: ScreenStyle.pink) + vText))
        }
    }
}

/// Ready-made layers added to the scene being edited, on the canvas shown.
enum LayerPreset: String, CaseIterable, Identifiable {
    case nameTag, cameraFrame
    var id: String { rawValue }
    var name: String { self == .nameTag ? "Name Tag" : "Camera Frame" }
    var summary: String { self == .nameTag ? "Your name on a plate, bottom left" : "A coloured ring around the camera" }
    var symbol: String { self == .nameTag ? "person.text.rectangle" : "circle.circle" }

    /// Adds the preset to `c` (on a canvas of `size` pixels) and returns the new layer's id, or a reason it cannot be
    /// added.
    func apply(to c: inout Composition, canvas size: CGSize) -> Result<UUID, PresetError> {
        switch self {
        case .nameTag:
            let v = size.height > size.width
            let l = Layer.text("Your Name", name: "Name Tag", frame: v ? NRect(x: 0.05, y: 0.875, w: 0.6, h: 0.042) : NRect(x: 0.03, y: 0.865, w: 0.28, h: 0.07),
                               weight: "semibold", alignment: "left", plate: ScreenStyle.plate, plateRadius: 0.3)
            c.layers.append(l)
            return .success(l.id)
        case .cameraFrame:
            guard let i = c.layers.lastIndex(where: { $0.source.type == "camera" && $0.visible }) else { return .failure(.noCamera) }
            let cam = c.layers[i], r = cam.frame.rect(in: size)
            // Same corner shape, a constant ring width: the outer radius is the camera's plus the padding.
            let pad = (min(size.width, size.height) * 0.009).rounded()
            let outer = r.insetBy(dx: -pad, dy: -pad), inner = min(0.5, max(0, cam.roundness)) * min(r.width, r.height)
            let roundness = min(0.5, (inner + pad) / max(1, min(outer.width, outer.height)))
            let ring = Layer.color(ScreenStyle.blue, name: "Camera Frame", frame: NRect(outer, in: size), roundness: roundness)
            c.layers.insert(ring, at: i)
            return .success(ring.id)
        }
    }
    enum PresetError: Error { case noCamera }
}
