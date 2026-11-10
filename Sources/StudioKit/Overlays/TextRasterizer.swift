// Text layers: token replacement, layout (the largest font that fits the layer's box) and CoreText rasterization into
// an `OverlayBitmap` at exactly the pixel size the layer is drawn at, so text stays sharp without mipmaps.
import AppKit
import CoreText

/// Values for the tokens a text layer may contain.
struct OverlayTokens: Equatable {
    var now = Date()
    var elapsed: TimeInterval? = nil        // recording or stream time; nil when neither runs
    var timeZone = TimeZone.current

    static let names = ["{time}", "{timer}"]
    static func contains(_ s: String) -> Bool { names.contains { s.contains($0) } }

    /// `{time}`: local clock as HH:mm. `{timer}`: elapsed time as M:SS, or H:MM:SS from an hour on.
    func replace(_ s: String) -> String {
        guard Self.contains(s) else { return s }
        // Render threads call this for every text layer on every frame: the calendar only when `{time}` is used.
        var out = s
        if out.contains("{timer}") {
            let e = max(0, Int((elapsed ?? 0).rounded(.down)))
            let timer = e >= 3600 ? String(format: "%d:%02d:%02d", e / 3600, e / 60 % 60, e % 60) : String(format: "%d:%02d", e / 60, e % 60)
            out = out.replacingOccurrences(of: "{timer}", with: timer)
        }
        if out.contains("{time}") {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
            let t = cal.dateComponents([.hour, .minute], from: now)
            out = out.replacingOccurrences(of: "{time}", with: String(format: "%02d:%02d", t.hour ?? 0, t.minute ?? 0))
        }
        return out
    }
}

/// Where everything goes in a text bitmap; rectangles in pixels, origin top-left.
struct TextLayout {
    var fontSize: CGFloat
    var font: CTFont
    var lines: [CTLine]
    var origins: [CGPoint]      // left end of each baseline
    var lineWidths: [CGFloat]
    var block: CGRect           // the lines' typographic box (ascent to descent, widest line)
    var plate: CGRect?          // block grown by the padding; the plate's shape when the spec has one
}

enum TextRasterizer {
    static func weight(_ name: String) -> NSFont.Weight {
        switch name { case "regular": .regular; case "medium": .medium; case "bold": .bold; case "heavy": .heavy; default: .semibold }
    }
    /// The named font, or the system font at the spec's weight when the name is empty or not installed on this Mac.
    /// A family name (what the inspector stores) gets the face nearest the spec's weight; a PostScript or full face
    /// name is used as it is. CoreText rather than NSFontManager: this runs on the overlay queue.
    static func font(_ spec: TextSpec, size: CGFloat) -> CTFont {
        if !spec.fontName.isEmpty {
            let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: spec.fontName,
                                          kCTFontTraitsAttribute: [kCTFontWeightTrait: weight(spec.weight).rawValue]]
            let wanted = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            if let match = CTFontDescriptorCreateMatchingFontDescriptor(wanted, Set([kCTFontFamilyNameAttribute as String]) as CFSet) {
                return CTFontCreateWithFontDescriptor(match, size, nil)
            }
            if let f = NSFont(name: spec.fontName, size: size) { return f as CTFont }
        }
        return NSFont.systemFont(ofSize: size, weight: weight(spec.weight)) as CTFont
    }

    /// Font families the inspector offers, those of a short list that this Mac has (all ship with macOS).
    static let families: [String] = {
        let wanted = ["Avenir Next", "Helvetica Neue", "Futura", "Gill Sans", "Rockwell", "Georgia", "Didot", "American Typewriter", "Menlo", "Marker Felt", "Impact"]
        let installed = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
        return wanted.filter(installed.contains)
    }()
    static func cgColor(_ v: [Double]?) -> CGColor? {
        guard let v = v, v.count >= 3, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGColor(colorSpace: space, components: [v[0], v[1], v[2], v.count > 3 ? v[3] : 1].map { CGFloat(min(1, max(0, $0))) })
    }
    /// Space kept around the lines: the plate padding, or room for the shadow's blur when there is no plate.
    static func padding(_ spec: TextSpec, fontSize: CGFloat) -> CGFloat {
        spec.plate != nil ? CGFloat(max(0, spec.platePadding)) * fontSize : spec.shadow ? 0.12 * fontSize : 0
    }

    /// The largest font size at which the lines plus padding fit `size`, and where each line and the plate go. Lines
    /// break only at the string's own line breaks; a line too wide for the box makes the font smaller instead.
    static func layout(_ spec: TextSpec, string: String, size: CGSize) -> TextLayout {
        let strings = string.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func measure(_ s: CGFloat) -> (CTFont, [CTLine], [CGFloat], CGFloat, CGSize) {
            let f = font(spec, size: s)
            let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(spec.color) ?? CGColor(gray: 1, alpha: 1)]
            let lines = strings.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
            let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth($0)) }
            let lineH = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)
            let pad = padding(spec, fontSize: s)
            let needed = CGSize(width: (widths.max() ?? 0) + 2 * pad, height: lineH * CGFloat(lines.count) + 2 * pad)
            return (f, lines, widths, lineH, needed)
        }
        // Metrics scale almost linearly with size; the system font's optical sizes and tracking make it not quite, so
        // refine from a first estimate and step down until it fits.
        var s: CGFloat = 100
        var m = measure(s)
        for _ in 0..<6 {
            let ratio = min(size.width / max(m.4.width, 1e-3), size.height / max(m.4.height, 1e-3))
            if ratio >= 1 && ratio < 1.01 { break }
            s = max(1, min(4096, s * ratio * (ratio < 1 ? 0.995 : 1)))
            m = measure(s)
            if s <= 1 { break }
        }
        while (m.4.width > size.width + 0.5 || m.4.height > size.height + 0.5) && s > 1 { s = max(1, s * 0.97); m = measure(s) }
        let (f, lines, widths, lineH, needed) = m
        let pad = padding(spec, fontSize: s)
        let plateX: CGFloat
        switch spec.alignment {
        case "left": plateX = 0
        case "right": plateX = size.width - needed.width
        default: plateX = ((size.width - needed.width) / 2).rounded()
        }
        let plate = CGRect(x: plateX, y: ((size.height - needed.height) / 2).rounded(), width: needed.width, height: needed.height)
        let block = plate.insetBy(dx: pad, dy: pad)
        let origins = widths.enumerated().map { i, w -> CGPoint in
            let x: CGFloat = spec.alignment == "left" ? block.minX : spec.alignment == "right" ? block.maxX - w : block.midX - w / 2
            return CGPoint(x: x, y: block.minY + CGFloat(i) * lineH + CTFontGetAscent(f))
        }
        return TextLayout(fontSize: s, font: f, lines: lines, origins: origins, lineWidths: widths, block: block, plate: spec.plate != nil ? plate : nil)
    }

    /// Rasterizes `string` (tokens already replaced) with `spec` at exactly `width` x `height` pixels.
    static func render(_ spec: TextSpec, string: String, width: Int, height: Int) -> OverlayBitmap? {
        let size = CGSize(width: width, height: height)
        let l = layout(spec, string: string, size: size)
        return OverlayBitmap.draw(width: width, height: height) { ctx in
            // User space is bottom-up: flip a top-left rectangle or baseline with H − y.
            if let p = l.plate, let color = cgColor(spec.plate) {
                let r = CGRect(x: p.minX, y: size.height - p.maxY, width: p.width, height: p.height)
                let radius = min(CGFloat(max(0, spec.plateRadius)) * p.height, p.height / 2, p.width / 2)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.setFillColor(color); ctx.fillPath()
            }
            if spec.shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: -0.04 * l.fontSize), blur: 0.1 * l.fontSize, color: CGColor(gray: 0, alpha: 0.6))
            }
            ctx.textMatrix = .identity
            ctx.setShouldSmoothFonts(false)     // no LCD-style smoothing on a transparent bitmap
            for (line, o) in zip(l.lines, l.origins) {
                ctx.textPosition = CGPoint(x: o.x, y: size.height - o.y)
                CTLineDraw(line, ctx)
            }
        }
    }
}
