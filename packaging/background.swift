import AppKit
import Foundation

let image = NSImage(size: NSSize(width: 760, height: 480))
image.lockFocus()
NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.99, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 760, height: 480).fill()
func text(_ value: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let width = (value as NSString).size(withAttributes: attributes).width
    (value as NSString).draw(at: NSPoint(x: (760 - width) / 2, y: y), withAttributes: attributes)
}
text("校园网登录", y: 385, font: .systemFont(ofSize: 30, weight: .semibold), color: .labelColor)
text("拖入应用程序以安装", y: 346, font: .systemFont(ofSize: 17), color: .secondaryLabelColor)
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 337, y: 230))
arrow.line(to: NSPoint(x: 423, y: 230))
arrow.move(to: NSPoint(x: 405, y: 248))
arrow.line(to: NSPoint(x: 423, y: 230))
arrow.line(to: NSPoint(x: 405, y: 212))
NSColor(calibratedRed: 0.15, green: 0.52, blue: 0.65, alpha: 1).setStroke()
arrow.stroke()
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
