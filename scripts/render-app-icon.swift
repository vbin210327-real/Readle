// Renders Readle's app icon ("Ink and stroke") at 1024x1024.
// Usage: swift scripts/render-app-icon.swift <out.png> [light|dark]
import AppKit
import CoreText

// Readle icon "Ink and stroke": a Didot R on warm paper, underlined with one green brush stroke.
// Usage: render <out.png> <light|dark>
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1]); let dark = args.count > 2 && args[2] == "dark"
let size = 1024, s = CGFloat(size) / 120

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Work in top-left SVG-style coordinates.
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

// Paper: soft radial light from upper centre.
let paper = dark ? [rgb(0x23463B), rgb(0x0F231C)] : [rgb(0xFCFAF4), rgb(0xE6DDC9)]
let grad = CGGradient(colorsSpace: space, colors: paper as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 512, y: 410), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 410), endRadius: 820, options: [.drawsAfterEndLocation])

// Fine paper grain, barely visible.
var rng = SystemRandomNumberGenerator()
for _ in 0..<26000 {
    let x = CGFloat.random(in: 0..<1024, using: &rng), y = CGFloat.random(in: 0..<1024, using: &rng)
    let light = Bool.random(using: &rng)
    ctx.setFillColor(light ? rgb(0xFFFFFF, dark ? 0.035 : 0.10) : rgb(dark ? 0x000000 : 0x6B5A3A, dark ? 0.10 : 0.045))
    ctx.fill(CGRect(x: x, y: y, width: 1.6, height: 1.6))
}

// The R, optically centred on the brush stroke.
let ink = dark ? rgb(0xF4EEDF) : rgb(0x1E3F33)
let font = CTFontCreateWithName("Didot" as CFString, 690, nil)
let attr = NSAttributedString(string: "R", attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink)!])
let line = CTLineCreateWithAttributedString(attr)
let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let baseline: CGFloat = 690
ctx.saveGState()
ctx.translateBy(x: 0, y: baseline); ctx.scaleBy(x: 1, y: -1) // CoreText draws y-up
ctx.textPosition = CGPoint(x: 512 - glyphBounds.midX - 6, y: 0)
CTLineDraw(line, ctx)
ctx.restoreGState()

// Brush stroke: a tapered swash under the R, heavy where the brush lands and thinning to a point.
func bez(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                   y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y)
}
let a = CGPoint(x: 246, y: 818), b = CGPoint(x: 400, y: 772), c = CGPoint(x: 620, y: 750), d = CGPoint(x: 812, y: 758)
func width(_ t: CGFloat) -> CGFloat { 52 * pow(1 - t, 0.55) + 4 }
var left: [CGPoint] = [], right: [CGPoint] = []
let steps = 240
for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps)
    let p0 = bez(max(t - 0.002, 0), a, b, c, d), p1 = bez(min(t + 0.002, 1), a, b, c, d)
    let len = hypot(p1.x - p0.x, p1.y - p0.y)
    let n = CGPoint(x: -(p1.y - p0.y) / len, y: (p1.x - p0.x) / len)
    let p = bez(t, a, b, c, d), w = width(t) / 2
    left.append(CGPoint(x: p.x + n.x * w, y: p.y + n.y * w))
    right.append(CGPoint(x: p.x - n.x * w, y: p.y - n.y * w))
}
let body = CGMutablePath()
body.addLines(between: left + right.reversed()); body.closeSubpath()
let cap = CGPath(ellipseIn: CGRect(x: a.x - width(0) / 2, y: a.y - width(0) / 2, width: width(0), height: width(0)), transform: nil)
let brush = dark ? [rgb(0x6FB891), rgb(0xA6D3B6)] : [rgb(0x3B8560), rgb(0x74B592)]
let bg = CGGradient(colorsSpace: space, colors: brush as CFArray, locations: [0, 1])!
for shape in [body as CGPath, cap] {
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(bg, start: a, end: d, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
