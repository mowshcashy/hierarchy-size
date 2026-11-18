import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let r = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let bg = NSBezierPath(roundedRect: r, xRadius: s*0.2, yRadius: s*0.2)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.20, blue: 0.42, alpha: 1), NSColor(red: 0.06, green: 0.09, blue: 0.20, alpha: 1)])!.draw(in: bg, angle: -90)
    // treemap tiles
    let colors: [NSColor] = [
        NSColor(red: 0.25, green: 0.60, blue: 0.95, alpha: 1), NSColor(red: 0.95, green: 0.55, blue: 0.25, alpha: 1),
        NSColor(red: 0.25, green: 0.75, blue: 0.60, alpha: 1), NSColor(red: 0.88, green: 0.30, blue: 0.40, alpha: 1),
        NSColor(red: 0.90, green: 0.75, blue: 0.25, alpha: 1), NSColor(red: 0.70, green: 0.40, blue: 0.85, alpha: 1)]
    let p = r.insetBy(dx: s*0.08, dy: s*0.08)
    let g = s*0.018
    let w = p.width, h = p.height
    let tiles: [NSRect] = [
        NSRect(x: p.minX, y: p.minY, width: w*0.58 - g, height: h),
        NSRect(x: p.minX + w*0.58, y: p.minY + h*0.45, width: w*0.42, height: h*0.55),
        NSRect(x: p.minX + w*0.58, y: p.minY, width: w*0.24 - g, height: h*0.45 - g),
        NSRect(x: p.minX + w*0.82, y: p.minY + h*0.2, width: w*0.18, height: h*0.25 - g),
        NSRect(x: p.minX + w*0.82, y: p.minY, width: w*0.18, height: h*0.2 - g),
    ]
    for (i, t) in tiles.enumerated() {
        let path = NSBezierPath(roundedRect: t, xRadius: s*0.03, yRadius: s*0.03)
        NSGradient(colors: [colors[i].highlight(withLevel: 0.25)!, colors[i]])!.draw(in: path, angle: -60)
    }
    // hierarchy lines on big tile
    NSColor.white.withAlphaComponent(0.9).setFill()
    let big = tiles[0]
    for (k, f) in [0.0, 1.0, 2.0, 1.0].enumerated() {
        let y = big.maxY - s*0.11 - CGFloat(k) * s*0.095
        let x = big.minX + s*0.05 + CGFloat(f) * s*0.06
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: big.maxX - x - s*0.05, height: s*0.045), xRadius: s*0.02, yRadius: s*0.02).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
