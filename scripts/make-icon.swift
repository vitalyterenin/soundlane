import AppKit
let output = CommandLine.arguments[1]
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.23, alpha: 1),
           ending: NSColor(calibratedRed: 0.15, green: 0.12, blue: 0.27, alpha: 1))!.draw(in: background, angle: -60)
for (lane, center, color) in [(0, 650.0, NSColor.systemTeal), (1, 370.0, NSColor.systemPurple)] {
    for i in 0..<9 {
        let wave = [70.0, 110, 170, 240, 290, 240, 170, 110, 70]
        let h = wave[(i + lane * 2) % 9] * 0.75
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 224 + Double(i) * 65, y: center-h/2, width: 35, height: h), xRadius: 17.5, yRadius: 17.5).fill()
    }
}
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
