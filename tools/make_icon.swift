// Usage: swift tools/make_icon.swift tools/icon-source.png GitCloudSync/Assets.xcassets/AppIcon.appiconset
import AppKit
// Cuts the rounded-square body out of the flat-background source picture and renders macOS AppIcon sizes.
let args = CommandLine.arguments
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let out = URL(fileURLWithPath: args[2])
let w = rep.pixelsWide, h = rep.pixelsHigh
func inside(_ x: Int, _ y: Int) -> Bool {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    return (c.blueComponent - c.redComponent) * 255 >= 6
}
// Edges of the thin dark outline, measured from the source picture (1254 px).
let left = 98, top = 92, right = 1147, bottom = 1161
var d = 0; while !inside(left + 4 + d, top + 4 + d) { d += 1 }
let radius = CGFloat(d + 4) / (1 - 1 / sqrt(2))
print("box", right - left, bottom - top, "radius", Int(radius))
let body = CGRect(x: left, y: h - bottom, width: right - left + 1, height: bottom - top + 1) // flipped to AppKit coords
let src = NSImage(size: NSSize(width: w, height: h)); src.addRepresentation(rep)

func render(_ px: Int) -> Data {
    let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    canvas.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: canvas)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let s = CGFloat(px) / 1024
    let target = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let r = radius * (824 / body.width) * s
    // 1 px inset hides the anti-aliased edge of the original white background.
    let inset = body.insetBy(dx: 5, dy: 5)
    let path = NSBezierPath(roundedRect: target, xRadius: r, yRadius: r)
    if px >= 64 {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 18 * s; shadow.shadowOffset = NSSize(width: 0, height: -8 * s); shadow.set()
        NSColor.white.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    path.addClip()
    src.draw(in: target, from: inset, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return canvas.representation(using: .png, properties: [:])!
}
let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
var images: [[String: String]] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! render(pt * scale).write(to: out.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
try! render(1024).write(to: out.appendingPathComponent("preview-1024.png"))
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: out.appendingPathComponent("Contents.json"))
