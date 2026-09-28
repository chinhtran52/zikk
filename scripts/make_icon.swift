// Renders the app icon at every macOS size into App/Assets.xcassets/AppIcon.appiconset.
// Style: flat vertical gradient with a single white glyph (a lightning bolt drawn as a path; SF Symbols
// must not be used in app icons).
//
// Usage:
//   swift scripts/make_icon.swift                                   # default Zikk icon
//   swift scripts/make_icon.swift --top 22C55E --bottom 0E7490      # custom gradient
//   swift scripts/make_icon.swift --text A --top F97316 --bottom DB2777  # a letter instead of the bolt
//   swift scripts/make_icon.swift --output path/to/AppIcon.appiconset
import AppKit

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let key = arguments.next() {
    guard key.hasPrefix("--"), let value = arguments.next() else { fatalError("Usage: --top RRGGBB --bottom RRGGBB [--text X] [--output DIR]") }
    options[String(key.dropFirst(2))] = value
}

func color(_ hex: String?, default fallback: NSColor) -> NSColor {
    guard let hex, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return fallback }
    return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

let output = URL(fileURLWithPath: options["output"] ?? "App/Assets.xcassets/AppIcon.appiconset")
let topColor = color(options["top"], default: NSColor(red: 0.36, green: 0.47, blue: 0.96, alpha: 1))
let bottomColor = color(options["bottom"], default: NSColor(red: 0.58, green: 0.34, blue: 0.86, alpha: 1))
let glyphText = options["text"]

/// Lightning bolt in a 100×100 unit square (y up).
func boltPath(in rect: CGRect) -> NSBezierPath {
    let points: [(CGFloat, CGFloat)] = [
        (60, 100), (18, 44), (46, 44), (36, 0), (82, 60), (53, 60), (60, 100),
    ]
    let path = NSBezierPath()
    for (index, point) in points.enumerated() {
        let p = CGPoint(x: rect.minX + point.0 / 100 * rect.width, y: rect.minY + point.1 / 100 * rect.height)
        if index == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    path.lineJoinStyle = .round
    return path
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        // macOS icon grid: 824/1024 body with continuous corners and a soft drop shadow.
        let inset = s * 100 / 1024
        let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        NSColor.black.setFill()
        shape.fill()
        context.restoreGState()

        context.saveGState()
        shape.addClip()
        // Top → bottom: electric indigo to violet (same family as the reference icon).
        let gradient = NSGradient(colors: [topColor, bottomColor])!
        gradient.draw(in: body, angle: -90)
        context.restoreGState()

        if let glyphText {
            let font = NSFont.systemFont(ofSize: body.height * 0.55, weight: .heavy)
            let text = NSAttributedString(string: glyphText, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: CGPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2))
            return true
        }

        // Bolt, centered optically, with rounded joins.
        let boltSize = body.width * 0.58
        let boltRect = CGRect(x: body.midX - boltSize / 2 + boltSize * 0.02, y: body.midY - boltSize / 2, width: boltSize, height: boltSize)
        let bolt = boltPath(in: boltRect)
        NSColor.white.setFill()
        NSColor.white.setStroke()
        bolt.lineWidth = boltSize * 0.06
        bolt.fill()
        bolt.stroke()
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(size: pixels).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
