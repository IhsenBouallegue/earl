// Renders Earl's app icon (Resources/AppIcon.icns): Earl himself, from his
// avatar's drawing. Run through tools/make-icon.sh.

import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
// macOS icon grid: the rounded square is 824 pt, centered, with room for the shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

/// Apple-style continuous corner rounded square (superellipse).
func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0, steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in y-down coordinates like Earl's avatar drawing.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    let shape = squircle(tile)

    // Tile shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x2B2118))
    ctx.fillPath()
    ctx.restoreGState()

    // Earl's face is the tile: brown ink, a little lighter at the top, with a
    // soft light from the top left like lamplight on leather.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(color(0x3D2E21), 0), (color(0x2B2118), 0.55), (color(0x1C150F), 1)]),
                           start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY),
                           options: [])
    ctx.drawRadialGradient(gradient([(color(0xFFE9C4, 0.16), 0), (color(0xFFE9C4, 0), 1)]),
                           startCenter: CGPoint(x: tile.minX + 200, y: tile.minY + 150), startRadius: 0,
                           endCenter: CGPoint(x: tile.minX + 200, y: tile.minY + 150), endRadius: 640, options: [])
    // A thin warm rim, so he holds his edge on a dark Dock.
    ctx.addPath(shape)
    ctx.setLineWidth(6)
    ctx.setStrokeColor(color(0xFFE9C4, 0.16))
    ctx.strokePath()
    ctx.restoreGState()

    // Earl's features, from his 40-unit avatar (EarlAvatar.swift), where the
    // squircle spans 1…39. Mapped so that squircle is the icon's tile.
    let u = tile.width / 38
    // The monocle and chain hang off his right; nudged left, the face sits
    // balanced on the tile.
    let shift: CGFloat = -1.6
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + (x - 1 + shift) * u, y: tile.minY + (y - 1) * u)
    }
    let cream = color(0xF7EEDD)

    // Features sit on the face with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x000000, 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Eyes; the right one behind the monocle.
    ctx.setFillColor(cream)
    for x in [13.5, 26.0] as [CGFloat] {
        ctx.fillEllipse(in: CGRect(origin: p(x - 2.5, 18 - 3.1), size: CGSize(width: 5 * u, height: 6.2 * u)))
    }

    // The smile.
    let smile = CGMutablePath()
    smile.move(to: p(11.5, 27.5))
    smile.addQuadCurve(to: p(20, 27.5), control: p(15.5, 25))
    smile.addQuadCurve(to: p(28.5, 27.5), control: p(24.5, 25))
    ctx.addPath(smile)
    ctx.setStrokeColor(cream)
    ctx.setLineWidth(2.5 * u)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // The lens: faintly warm glass over the eye.
    let lensRect = CGRect(origin: p(26 - 6.4, 18 - 6.4), size: CGSize(width: 12.8 * u, height: 12.8 * u))
    ctx.saveGState()
    ctx.addEllipse(in: lensRect)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(color(0xFFF4DC, 0.20), 0), (color(0xFFF4DC, 0.04), 1)]),
                           start: CGPoint(x: lensRect.minX, y: lensRect.minY),
                           end: CGPoint(x: lensRect.maxX, y: lensRect.maxY), options: [])
    ctx.restoreGState()

    // Gold: the rim and the chain, polished from the top.
    func gold(_ path: CGPath) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let b = path.boundingBox
        ctx.drawLinearGradient(gradient([(color(0xF7D27A), 0), (color(0xE0A93A), 0.5), (color(0xB57E1E), 1)]),
                               start: CGPoint(x: b.minX, y: b.minY), end: CGPoint(x: b.maxX, y: b.maxY), options: [])
        ctx.restoreGState()
    }
    let rim = CGPath(ellipseIn: lensRect, transform: nil)
        .copy(strokingWithWidth: 2.4 * u, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    let chainLine = CGMutablePath()
    chainLine.move(to: p(32.2, 20.5))
    chainLine.addQuadCurve(to: p(32, 34), control: p(35, 27))
    let chain = chainLine.copy(strokingWithWidth: 1.4 * u, lineCap: .round, lineJoin: .round, miterLimit: 10)
    gold(chain)
    gold(rim)

    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // The glint: light caught on the upper left of the lens.
    let glint = CGMutablePath()
    glint.addArc(center: p(26, 18), radius: 4.6 * u, startAngle: .pi * 1.08, endAngle: .pi * 1.42, clockwise: false)
    ctx.addPath(glint)
    ctx.setStrokeColor(color(0xFFFFFF, 0.7))
    ctx.setLineWidth(0.9 * u)
    ctx.setLineCap(.round)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let image = render()
for base in [16, 32, 128, 256, 512] {
    writePNG(image, size: base, to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(image, size: base * 2, to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
