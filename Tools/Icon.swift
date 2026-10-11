import AppKit
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 200, yRadius: 200)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.20); shadow.shadowBlurRadius = 32; shadow.shadowOffset = NSSize(width: 0, height: -15)
shadow.set()
NSGradient(colors: [NSColor(calibratedRed: 0.29, green: 0.65, blue: 1, alpha: 1), NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.84, alpha: 1)])!.draw(in: tile, angle: -55)
NSShadow().set()
let back = NSBezierPath(roundedRect: NSRect(x: 160, y: 390, width: 550, height: 390), xRadius: 105, yRadius: 105)
NSColor.white.withAlphaComponent(0.22).setFill(); back.fill()
NSColor.white.setFill()
let heights: [CGFloat] = [80, 135, 230, 165, 280, 180, 100]
for (index, height) in heights.enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 240 + CGFloat(index) * 54, y: 586 - height / 2, width: 26, height: height), xRadius: 13, yRadius: 13).fill()
}
let foreground = NSBezierPath(roundedRect: NSRect(x: 420, y: 220, width: 430, height: 360), xRadius: 98, yRadius: 98)
let pageShadow = NSShadow(); pageShadow.shadowColor = NSColor(calibratedRed: 0.07, green: 0.18, blue: 0.48, alpha: 0.28); pageShadow.shadowBlurRadius = 24; pageShadow.shadowOffset = NSSize(width: 0, height: -12); pageShadow.set()
NSGradient(colors: [.white, NSColor(calibratedRed: 0.90, green: 0.95, blue: 1, alpha: 1)])!.draw(in: foreground, angle: -90)
NSShadow().set()
let tail = NSBezierPath(); tail.move(to: NSPoint(x: 736, y: 244)); tail.line(to: NSPoint(x: 766, y: 178)); tail.line(to: NSPoint(x: 678, y: 230)); tail.close(); NSColor(calibratedRed: 0.91, green: 0.96, blue: 1, alpha: 1).setFill(); tail.fill()
let text = NSAttributedString(string: "中", attributes: [.font: NSFont.systemFont(ofSize: 206, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.14, green: 0.39, blue: 0.88, alpha: 1)])
text.draw(at: NSPoint(x: 635 - text.size().width / 2, y: 290))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
