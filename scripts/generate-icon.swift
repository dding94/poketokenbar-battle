// PokeTokenBattle app icon generator: two token halves split by a lightning bolt.
// Usage: swift scripts/generate-icon.swift <output.png> [size=1024]
// Geometry mirrors assets/icon.svg (1024 viewBox, y grows downward); keep the two in sync.
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "build/icon_1024.png"
let size = args.count > 2 ? (Int(args[2]) ?? 1024) : 1024

let S = CGFloat(size)
let f = S / 1024.0

func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * f, y: S - y * f) }
func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: P(pts[0].0, pts[0].1))
    for p in pts.dropFirst() { path.line(to: P(p.0, p.1)) }
    path.close()
    return path
}
func col(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.shouldAntialias = true

// Background squircle.
let bgRect = NSRect(x: 100 * f, y: 100 * f, width: 824 * f, height: 824 * f)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185 * f, yRadius: 185 * f)
NSGradient(starting: col(0x1b2133), ending: col(0x0b0e17))?.draw(in: bg, angle: 270)

// Coin halves, clipped to the coin circle.
let coinRect = NSRect(x: (512 - 330) * f, y: S - (512 + 330) * f, width: 660 * f, height: 660 * f)
let coin = NSBezierPath(ovalIn: coinRect)
NSGraphicsContext.saveGraphicsState()
coin.addClip()
let left = poly([(100, 150), (590, 150), (590, 230), (410, 545), (505, 545), (450, 880), (100, 880)])
NSGradient(starting: col(0x1668e0), ending: col(0x4fd8ff))?.draw(in: left, angle: 45)
let right = poly([(590, 150), (924, 150), (924, 880), (450, 880), (450, 800), (640, 455), (540, 455), (590, 230)])
NSGradient(starting: col(0xee3b5a), ending: col(0xffb347))?.draw(in: right, angle: 45)
NSGraphicsContext.restoreGraphicsState()

// Coin rim.
col(0xffffff, 0.18).setStroke()
let rim = NSBezierPath(ovalIn: coinRect)
rim.lineWidth = 14 * f
rim.stroke()

// Lightning bolt.
let bolt = poly([(590, 230), (410, 545), (505, 545), (450, 800), (640, 455), (540, 455)])
bolt.lineJoinStyle = .round
col(0xffffff).setFill(); bolt.fill()
col(0x0b0e17).setStroke(); bolt.lineWidth = 10 * f; bolt.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.createDirectory(
    atPath: (outPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("saved: \(outPath) (\(size)px)")
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
