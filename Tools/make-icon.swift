import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png:
//   swiftc -O Tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// Mainstream icon: a stream of data — three flowing bands that turn into a column of
// pixels, on a deep blue-to-teal field.
let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let W = CGFloat(S)
// background
let bg = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.04, green: 0.07, blue: 0.22, alpha: 1),
                                               CGColor(red: 0.02, green: 0.42, blue: 0.55, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: W), end: CGPoint(x: W, y: 0), options: [])
// soft glow
let glow = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.3, green: 0.9, blue: 1, alpha: 0.28), CGColor(red: 0.3, green: 0.9, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.62, y: W * 0.5), startRadius: 0, endCenter: CGPoint(x: W * 0.62, y: W * 0.5), endRadius: W * 0.5, options: [])
// three waves flowing left → right, converging
let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.55, 0.95, 1.0), (1, 1, 1), (0.45, 0.75, 1.0)]
for (n, c) in colors.enumerated() {
    let off = CGFloat(n - 1)
    let path = CGMutablePath()
    let x0 = W * 0.14, x1 = W * 0.60
    for i in 0...200 {
        let t = CGFloat(i) / 200
        let x = x0 + (x1 - x0) * t
        let amp = W * 0.085 * (1 - t * 0.85)
        let y = W * 0.5 + off * W * 0.115 * (1 - 0.8 * t) + amp * sin(t * .pi * 2.2)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: n == 1 ? 1 : 0.85))
    ctx.setLineWidth(W * 0.045)
    ctx.setLineCap(.round)
    ctx.strokePath()
}
// the stream resolves into pixels on the right
var rng: UInt64 = 0x5EED
func rnd() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(rng >> 40) / CGFloat(1 << 24) }
let cell = W * 0.052, gap = W * 0.012
for col in 0..<4 {
    for row in -3...3 {
        let fade = 1 - CGFloat(abs(row)) / 4.2
        guard rnd() < 0.55 + 0.4 * fade - CGFloat(col) * 0.08 else { continue }
        let x = W * 0.64 + CGFloat(col) * (cell + gap)
        let y = W * 0.5 - cell / 2 + CGFloat(row) * (cell + gap)
        let a = (0.55 + 0.45 * fade) * (1 - CGFloat(col) * 0.15)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: a))
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: cell, height: cell), cornerWidth: cell * 0.22, cornerHeight: cell * 0.22, transform: nil))
        ctx.fillPath()
    }
}
let img = ctx.makeImage()!
// opaque output (App Store icons have no alpha)
let out = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
out.draw(img, in: CGRect(x: 0, y: 0, width: S, height: S))
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out.makeImage()!, nil)
CGImageDestinationFinalize(dest)
