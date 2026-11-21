import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func drawIcon(_ pixels: Int) -> Data {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.24, blue: 0.63, alpha: 1),
               ending: NSColor(calibratedRed: 0.02, green: 0.77, blue: 0.73, alpha: 1))!.draw(in: background, angle: 55)
    let points = [NSPoint(x: 512, y: 700), NSPoint(x: 310, y: 355), NSPoint(x: 714, y: 355)]
    let lines = NSBezierPath()
    lines.lineWidth = 30
    lines.lineCapStyle = .round
    for index in 0..<3 {
        lines.move(to: points[index])
        lines.line(to: points[(index + 1) % 3])
    }
    NSColor.white.withAlphaComponent(0.65).setStroke()
    lines.stroke()
    for point in points {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 72, y: point.y - 72, width: 144, height: 144)).fill()
        NSColor(calibratedRed: 0.06, green: 0.42, blue: 0.65, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 34, y: point.y - 34, width: 68, height: 68)).fill()
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size).write(to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size * 2).write(to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
