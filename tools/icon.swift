import AppKit

// Lilt's icon: two four-point stars joined by a thin link, on a deep night-blue rounded square.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: the tile is 824 pt inside the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(shape); ctx.clip()
let colors = [NSColor(srgbRed: 0.10, green: 0.09, blue: 0.22, alpha: 1).cgColor,
              NSColor(srgbRed: 0.02, green: 0.02, blue: 0.06, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// A few faint dust stars.
for (x, y, r) in [(250.0, 760.0, 5.0), (760, 300, 4), (330, 270, 3.5), (700, 800, 3), (820, 620, 4)] {
    ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

func star(_ c: CGPoint, _ r: CGFloat, _ color: NSColor) {
    let k = 0.34 * r
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x + r, y: c.y))
    p.addLine(to: CGPoint(x: c.x + k, y: c.y + k)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
    p.addLine(to: CGPoint(x: c.x - k, y: c.y + k)); p.addLine(to: CGPoint(x: c.x - r, y: c.y))
    p.addLine(to: CGPoint(x: c.x - k, y: c.y - k)); p.addLine(to: CGPoint(x: c.x, y: c.y - r))
    p.addLine(to: CGPoint(x: c.x + k, y: c.y - k)); p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(color.cgColor); ctx.fillPath()
}

let small = CGPoint(x: 360, y: 380), big = CGPoint(x: 640, y: 620)
let pink = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.75, alpha: 1)
ctx.setStrokeColor(pink.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(10); ctx.setLineCap(.round)
ctx.move(to: small); ctx.addLine(to: big); ctx.strokePath()
// Soft glow behind the big star.
ctx.setShadow(offset: .zero, blur: 60, color: pink.withAlphaComponent(0.8).cgColor)
star(big, 190, .white)
ctx.setShadow(offset: .zero, blur: 30, color: pink.withAlphaComponent(0.6).cgColor)
star(small, 95, NSColor(white: 1, alpha: 0.8))
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
