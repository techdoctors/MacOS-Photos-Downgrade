// Renders the app icon: an original rainbow-petal flower with a down arrow.
// Usage: swift scripts/make-icon.swift <out.png>   (1024×1024)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt rounded square centred in 1024 with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Flower: 7 translucent elliptical petals fanned around the centre.
let center = CGPoint(x: size / 2, y: size / 2 + 10)
let petals: [NSColor] = [
    NSColor(red: 1.00, green: 0.27, blue: 0.33, alpha: 1), // red
    NSColor(red: 1.00, green: 0.58, blue: 0.10, alpha: 1), // orange
    NSColor(red: 1.00, green: 0.82, blue: 0.10, alpha: 1), // yellow
    NSColor(red: 0.35, green: 0.80, blue: 0.30, alpha: 1), // green
    NSColor(red: 0.15, green: 0.72, blue: 0.85, alpha: 1), // teal
    NSColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 1), // blue
    NSColor(red: 0.70, green: 0.35, blue: 0.90, alpha: 1), // purple
]
ctx.setBlendMode(.multiply)
for (i, color) in petals.enumerated() {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: -CGFloat(i) * 2 * .pi / CGFloat(petals.count) + .pi / 2)
    let petal = CGRect(x: 40, y: -95, width: 300, height: 190)
    ctx.addEllipse(in: petal)
    ctx.setFillColor(color.withAlphaComponent(0.82).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}
ctx.setBlendMode(.normal)

// Down arrow: white with a dark outline and shadow so it reads on every petal.
let arrow = CGMutablePath()
let shaftW: CGFloat = 116, headW: CGFloat = 330, top: CGFloat = 745, neck: CGFloat = 455, tip: CGFloat = 250
arrow.move(to: CGPoint(x: center.x - shaftW / 2, y: top))
arrow.addLine(to: CGPoint(x: center.x + shaftW / 2, y: top))
arrow.addLine(to: CGPoint(x: center.x + shaftW / 2, y: neck))
arrow.addLine(to: CGPoint(x: center.x + headW / 2, y: neck))
arrow.addLine(to: CGPoint(x: center.x, y: tip))
arrow.addLine(to: CGPoint(x: center.x - headW / 2, y: neck))
arrow.addLine(to: CGPoint(x: center.x - shaftW / 2, y: neck))
arrow.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(arrow)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(arrow)
ctx.setLineJoin(.round)
ctx.setLineWidth(15)
ctx.setStrokeColor(NSColor(red: 0.10, green: 0.14, blue: 0.24, alpha: 1).cgColor)
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
