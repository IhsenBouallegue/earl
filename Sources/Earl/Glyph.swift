import CoreGraphics
import Foundation

/// Earl's mark: a monocle that listens. A glass lens with a waveform inside
/// and a little bead chain. Coordinates are in a unit square with y pointing
/// down; every function maps them into `rect`.
///
/// Shared by the app (menu bar icon, SwiftUI shapes) and tools/make-icon.swift.
enum Glyph {
    static let lensCenter = CGPoint(x: 0.42, y: 0.42)
    static let lensRadius: CGFloat = 0.31
    static let rimWidth: CGFloat = 0.075
    static let barHeights: [CGFloat] = [0.11, 0.23, 0.34, 0.23, 0.11]
    static let barWidth: CGFloat = 0.05
    static let barSpacing: CGFloat = 0.088
    static let beadRadius: CGFloat = 0.021

    private static func map(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
    }

    private static func circle(_ c: CGPoint, _ radius: CGFloat, _ r: CGRect) -> CGRect {
        let center = map(c, r)
        let rad = radius * r.width
        return CGRect(x: center.x - rad, y: center.y - rad, width: rad * 2, height: rad * 2)
    }

    /// The glass inside the rim.
    static func lens(in r: CGRect) -> CGPath {
        CGPath(ellipseIn: circle(lensCenter, lensRadius - rimWidth / 2, r), transform: nil)
    }

    /// The monocle's rim, as a filled ring (use even-odd filling).
    static func rim(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: circle(lensCenter, lensRadius + rimWidth / 2, r))
        path.addEllipse(in: circle(lensCenter, lensRadius - rimWidth / 2, r))
        return path
    }

    static func waveform(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        let mid = (CGFloat(barHeights.count) - 1) / 2
        for (i, h) in barHeights.enumerated() {
            let x = lensCenter.x + (CGFloat(i) - mid) * barSpacing
            let origin = map(CGPoint(x: x - barWidth / 2, y: lensCenter.y - h / 2), r)
            let bar = CGRect(x: origin.x, y: origin.y, width: barWidth * r.width, height: h * r.height)
            let radius = bar.width / 2
            path.addRoundedRect(in: bar, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }

    /// Bead positions along the chain hanging from the rim.
    static var beads: [CGPoint] {
        // The chain hangs from the lower right of the rim, sags, and swings back
        // up, so it reads as a monocle chain rather than a magnifier handle.
        let angle = CGFloat.pi * 0.36
        let start = CGPoint(x: lensCenter.x + cos(angle) * (lensRadius + rimWidth / 2),
                            y: lensCenter.y + sin(angle) * (lensRadius + rimWidth / 2))
        let c1 = CGPoint(x: 0.56, y: 1.02)
        let c2 = CGPoint(x: 0.86, y: 1.00)
        let end = CGPoint(x: 0.93, y: 0.66)
        func bezier(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let x = u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
            let y = u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
            return CGPoint(x: x, y: y)
        }
        return stride(from: 0.02, through: 1.0, by: 0.0754).map { bezier(CGFloat($0)) }
    }

    static func chain(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        for (i, b) in beads.enumerated() {
            // The last bead is a touch bigger, like a clasp.
            let radius = i == beads.count - 1 ? beadRadius * 1.35 : beadRadius
            path.addEllipse(in: circle(b, radius, r))
        }
        return path
    }

    /// A small specular glint on the upper-left of the lens.
    static func glint(in r: CGRect) -> CGPath {
        let inner = lensRadius - rimWidth / 2
        let c = map(lensCenter, r)
        let rad = inner * 0.86 * r.width
        let path = CGMutablePath()
        path.addArc(center: c, radius: rad, startAngle: .pi * 1.13, endAngle: .pi * 1.37, clockwise: false)
        return path.copy(strokingWithWidth: r.width * 0.035, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }
}
