// Extracts the cat silhouette from tools/icon-source.png as a template image set for the menu bar.
// usage: swift tools/make_menubar_icon.swift tools/icon-source.png GitCloudSync/Assets.xcassets/MenuBarCat.imageset
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: make_menubar_icon <icon-source.png> <imageset folder>")
}
let width = cg.width, height = cg.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let rgb = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

// The cat is the dark, unsaturated shape; everything else becomes transparent.
var mask = [UInt8](repeating: 0, count: width * height)
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let saturation = max(r, g, b) - min(r, g, b)
        guard saturation < 0.3 else { continue }
        let alpha = min(1, max(0, (0.45 - lum) / 0.2))
        guard alpha > 0 else { continue }
        mask[y * width + x] = UInt8(alpha * 255)
        if alpha > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
print("cat bounds", crop)

var out = [UInt8](repeating: 0, count: width * height * 4)
for p in 0..<(width * height) { out[p * 4 + 3] = mask[p] }   // black with the mask as alpha
let maskContext = CGContext(data: &out, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let catImage = maskContext.makeImage()!.cropping(to: crop)!

let folder = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [String] = []
for scale in [1, 2, 3] {
    let side = 18 * scale
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Fit the cat into the square, keeping its proportions.
    let fit = min(Double(side) / crop.width, Double(side) / crop.height)
    let w = crop.width * fit, h = crop.height * fit
    ctx.draw(catImage, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
    let name = "menubar-cat@\(scale)x.png"
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    images.append(#"{"filename":"\#(name)","idiom":"universal","scale":"\#(scale)x"}"#)
}
let contents = #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1},"properties":{"template-rendering-intent":"template"}}"#
try contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote", folder.path)
