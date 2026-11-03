import AppKit
// Renders a full-bleed, opaque 1024 px square from the source picture for an Icon Composer layer:
// the artwork fills the square, and its rounded corners are back-filled with the background gradient
// sampled inside the artwork's background area, row by row, then smoothed.
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let left = 98, top = 92, right = 1147, bottom = 1161      // outline of the rounded square in the source
let inset = 6                                              // drop the thin outline itself
let srcRect = NSRect(x: left + inset, y: rep.pixelsHigh - bottom + inset,
                     width: right - left - 2 * inset, height: bottom - top - 2 * inset)
let size = 1024
let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: canvas)!
ctx.imageInterpolation = .high
NSGraphicsContext.current = ctx
// Background: per source row, sample background pixels that avoid the corners and the central disc
// (side strips in the middle rows, x = 450 / 800 above the disc, x = 450 below it), then smooth.
let cornerSpan = 340
var rows: [(CGFloat, CGFloat, CGFloat)] = []
for sy in (top + inset)..<(bottom - inset) {
    let xs: [Int]
    if sy < top + cornerSpan { xs = [450, 800] }
    else if sy > bottom - cornerSpan { xs = [450] }
    else { xs = [left + 22, right - 22] }
    let cs = xs.map { rep.colorAt(x: $0, y: sy)!.usingColorSpace(.deviceRGB)! }
    let n = CGFloat(cs.count)
    rows.append((cs.map(\.redComponent).reduce(0, +) / n, cs.map(\.greenComponent).reduce(0, +) / n,
                 cs.map(\.blueComponent).reduce(0, +) / n))
}
let window = 60
func smoothed(_ i: Int) -> NSColor {
    let lo = max(0, i - window), hi = min(rows.count - 1, i + window)
    let slice = rows[lo...hi]; let n = CGFloat(slice.count)
    return NSColor(red: slice.map(\.0).reduce(0, +) / n, green: slice.map(\.1).reduce(0, +) / n,
                   blue: slice.map(\.2).reduce(0, +) / n, alpha: 1)
}
for row in 0..<size {
    let i = Int(CGFloat(row) / CGFloat(size - 1) * CGFloat(rows.count - 1))   // 0 = top
    smoothed(i).setFill()
    NSRect(x: 0, y: size - 1 - row, width: size, height: 1).fill()
}
// Artwork, enlarged by `bleed` px on every side so its own rounded corners fall outside the system's
// icon mask (only plain background is trimmed), then clipped to those corners so the source's white
// background can never show; the gradient above covers anything the mask still reveals.
let bleed: CGFloat = 60
let dest = NSRect(x: -bleed, y: -bleed, width: CGFloat(size) + 2 * bleed, height: CGFloat(size) + 2 * bleed)
let radius: CGFloat = 334 * dest.width / CGFloat(right - left) - 4
NSBezierPath(roundedRect: dest, xRadius: radius, yRadius: radius).addClip()
let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)); img.addRepresentation(rep)
img.draw(in: dest, from: srcRect, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! canvas.representation(using: .png, properties: [:])!.write(to: out)
