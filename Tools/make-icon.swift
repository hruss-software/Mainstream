// Renders the Mainstream mark: a finder-pattern frame (black, white, black) around a 3×3 grid
// of the code's colours.
//   swiftc -O Tools/make-icon.swift -o /tmp/make-icon
//   for v in light dark tinted; do /tmp/make-icon Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-$v.png $v; done
//   /tmp/make-icon Docs/mark-light.png mark-light 512   # README: black frame on transparent
//   /tmp/make-icon Docs/mark-dark.png mark-dark 512     # README: white frame on transparent
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let variant = args.count > 2 ? args[2] : "light"
let S = args.count > 3 ? Int(args[3])! : 1024
let W = CGFloat(S)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
let ink = rgb(0x0E0E10), paper = rgb(0xFFFFFF)
let magenta = rgb(0xE0369E), red = rgb(0xEE2B25), cyan = rgb(0x1BC5E6), green = rgb(0x17B85D), yellow = rgb(0xF6CA16)
let tinted = variant == "tinted"
func gray(_ c: CGColor) -> CGColor {
    guard tinted, let p = c.components else { return c }
    let l = 0.3 * p[0] + 0.59 * p[1] + 0.11 * p[2]
    return CGColor(gray: l, alpha: 1)
}

// Proportions of the mark, from the brand artwork (fractions of the mark's width): a ring
// 14.5% wide, then the interior, then a centred 3×3 grid starting at 28.9%.
let ringW: CGFloat = 0.145, gridAt: CGFloat = 0.289
let grid: [[CGColor]] = [[magenta, red, magenta], [paper, cyan, green], [green, yellow, paper]]

let opaque = !variant.hasPrefix("mark")
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: W); ctx.scaleBy(x: 1, y: -1)        // top-left origin, like the artwork

// Icons: the dark mark (white ring, black interior) on a black square, the mark spanning 75%.
// mark-light: black ring, white interior, black grid squares; mark-dark: white ring, black
// interior, white grid squares; both on transparent, filling the image.
let dark = variant != "mark-light"
let markRect = opaque ? CGRect(x: 0.125 * W, y: 0.125 * W, width: 0.75 * W, height: 0.75 * W) : CGRect(x: 0, y: 0, width: W, height: W)
if opaque { ctx.setFillColor(gray(ink)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: W)) }
let M = markRect.width
ctx.setFillColor(gray(dark ? paper : ink)); ctx.fill(markRect)
ctx.setFillColor(gray(dark ? ink : paper)); ctx.fill(markRect.insetBy(dx: ringW * M, dy: ringW * M))
let g0 = markRect.minX + gridAt * M, cell = (M - 2 * gridAt * M) / 3
for (r, row) in grid.enumerated() {
    for (c, color) in row.enumerated() {
        let col = color === paper ? (dark ? paper : ink) : color
        ctx.setFillColor(gray(col))
        ctx.fill(CGRect(x: g0 + CGFloat(c) * cell, y: markRect.minY + gridAt * M + CGFloat(r) * cell, width: cell + 0.5, height: cell + 0.5))
    }
}

let url = URL(fileURLWithPath: args[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
