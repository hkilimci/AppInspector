// Draws the App Inspector icon (1024×1024 master PNG) with CoreGraphics. No SF Symbols: Apple's license
// doesn't allow them in app icons. Regenerate the .icns with Tools/make-icon.sh.
//
// Motif: a grid of app tiles inspected through a magnifying glass, whose lens shows a privacy shield.
import AppKit

let size: CGFloat = 1024
guard CommandLine.arguments.count == 2 else { print("usage: make-icon.swift <out.png>"); exit(64) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Top-left origin, like a design tool.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func linear(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, in path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// macOS icon grid: 824×824 body centred in 1024, continuous-looking corner radius.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rounded(body, 185)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x1B2559)); ctx.fillPath()
ctx.restoreGState()

// Background: deep indigo to blue, with a soft top sheen.
linear([rgb(0x4C6EF5), rgb(0x2B3A9E), rgb(0x18205E)], CGPoint(x: 512, y: 100), CGPoint(x: 512, y: 924), in: bodyPath)
linear([rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)], CGPoint(x: 512, y: 100), CGPoint(x: 512, y: 470), in: bodyPath)
ctx.saveGState()
ctx.addPath(rounded(body.insetBy(dx: 1.5, dy: 1.5), 184)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

// App tiles: 3×3 grid, upper-left, partly under the lens.
let tileColors: [UInt32] = [0x51CF66, 0xFCC419, 0xFF6B6B, 0x22B8CF, 0x20C997, 0xCC5DE8, 0xFF922B, 0x94D82D, 0x748FFC]
let tile: CGFloat = 132, gap: CGFloat = 34, origin = CGPoint(x: 196, y: 196)
for i in 0..<9 {
    let r = CGRect(x: origin.x + CGFloat(i % 3) * (tile + gap), y: origin.y + CGFloat(i / 3) * (tile + gap), width: tile, height: tile)
    let p = rounded(r, 34)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 10, color: rgb(0x000000, 0.25))
    ctx.addPath(p); ctx.setFillColor(rgb(tileColors[i], 0.92)); ctx.fillPath()
    ctx.restoreGState()
    linear([rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0)], CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.midY), in: p)
}

// Magnifying glass over the lower-right tiles.
let lensCenter = CGPoint(x: 600, y: 590), lensRadius: CGFloat = 196, ring: CGFloat = 46
let angle = CGFloat.pi / 4
let handleStart = CGPoint(x: lensCenter.x + cos(angle) * (lensRadius + ring / 2 - 6), y: lensCenter.y + sin(angle) * (lensRadius + ring / 2 - 6))
let handleEnd = CGPoint(x: 830, y: 820)

// Handle (under the ring), with shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: rgb(0x000000, 0.4))
ctx.setLineCap(.round); ctx.setLineWidth(78); ctx.setStrokeColor(rgb(0xDEE2E6))
ctx.move(to: handleStart); ctx.addLine(to: handleEnd); ctx.strokePath()
ctx.restoreGState()
let handlePath = CGMutablePath()
handlePath.move(to: handleStart); handlePath.addLine(to: handleEnd)
let handleShape = handlePath.copy(strokingWithWidth: 78, lineCap: .round, lineJoin: .round, miterLimit: 10)
linear([rgb(0xFFFFFF), rgb(0xADB5BD)], CGPoint(x: 700, y: 660), CGPoint(x: 760, y: 900), in: handleShape)

// Lens glass: frosted, tinted, slightly magnifying feel.
let lensRect = CGRect(x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius, width: lensRadius * 2, height: lensRadius * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: rgb(0x000000, 0.45))
ctx.addEllipse(in: lensRect.insetBy(dx: -ring / 2, dy: -ring / 2)); ctx.setFillColor(rgb(0x1B2559)); ctx.fillPath()
ctx.restoreGState()
let lensPath = CGPath(ellipseIn: lensRect, transform: nil)
linear([rgb(0xE7F5FF, 0.97), rgb(0xA5D8FF, 0.95)], CGPoint(x: lensRect.minX, y: lensRect.minY), CGPoint(x: lensRect.maxX, y: lensRect.maxY), in: lensPath)

// Shield inside the lens: privacy & security.
let s: CGFloat = 1.0
let sc = CGPoint(x: lensCenter.x, y: lensCenter.y + 6)
let shield = CGMutablePath()
shield.move(to: CGPoint(x: sc.x, y: sc.y - 128 * s))
shield.addCurve(to: CGPoint(x: sc.x + 112 * s, y: sc.y - 84 * s), control1: CGPoint(x: sc.x + 40 * s, y: sc.y - 104 * s), control2: CGPoint(x: sc.x + 80 * s, y: sc.y - 92 * s))
shield.addCurve(to: CGPoint(x: sc.x, y: sc.y + 132 * s), control1: CGPoint(x: sc.x + 118 * s, y: sc.y + 10 * s), control2: CGPoint(x: sc.x + 84 * s, y: sc.y + 96 * s))
shield.addCurve(to: CGPoint(x: sc.x - 112 * s, y: sc.y - 84 * s), control1: CGPoint(x: sc.x - 84 * s, y: sc.y + 96 * s), control2: CGPoint(x: sc.x - 118 * s, y: sc.y + 10 * s))
shield.addCurve(to: CGPoint(x: sc.x, y: sc.y - 128 * s), control1: CGPoint(x: sc.x - 80 * s, y: sc.y - 92 * s), control2: CGPoint(x: sc.x - 40 * s, y: sc.y - 104 * s))
shield.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: rgb(0x1B2559, 0.35))
ctx.addPath(shield); ctx.setFillColor(rgb(0x364FC7)); ctx.fillPath()
ctx.restoreGState()
linear([rgb(0x5C7CFA), rgb(0x3B5BDB), rgb(0x2B3A9E)], CGPoint(x: sc.x, y: sc.y - 128), CGPoint(x: sc.x, y: sc.y + 132), in: shield)

// Check mark on the shield.
ctx.saveGState()
ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(30); ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.move(to: CGPoint(x: sc.x - 50, y: sc.y + 4))
ctx.addLine(to: CGPoint(x: sc.x - 12, y: sc.y + 42))
ctx.addLine(to: CGPoint(x: sc.x + 56, y: sc.y - 40))
ctx.strokePath()
ctx.restoreGState()

// Glass glare.
ctx.saveGState()
ctx.addPath(lensPath); ctx.clip()
let glare = CGMutablePath()
glare.addEllipse(in: CGRect(x: lensRect.minX + 30, y: lensRect.minY + 18, width: 210, height: 120), transform: CGAffineTransform(rotationAngle: 0))
linear([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)], CGPoint(x: lensRect.minX + 80, y: lensRect.minY + 20), CGPoint(x: lensRect.minX + 160, y: lensRect.minY + 140), in: glare)
ctx.restoreGState()

// Lens ring: brushed-metal gradient.
let ringPath = CGPath(ellipseIn: lensRect, transform: nil).copy(strokingWithWidth: ring, lineCap: .round, lineJoin: .round, miterLimit: 10)
linear([rgb(0xFFFFFF), rgb(0xCED4DA), rgb(0x868E96)], CGPoint(x: lensRect.minX, y: lensRect.minY), CGPoint(x: lensRect.maxX, y: lensRect.maxY), in: ringPath)
ctx.saveGState()
ctx.addEllipse(in: lensRect.insetBy(dx: -ring / 2, dy: -ring / 2)); ctx.setStrokeColor(rgb(0x000000, 0.18)); ctx.setLineWidth(2); ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
