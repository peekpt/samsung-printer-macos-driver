import AppKit

// Draw the DMG window background (540x380) with an arrow towards /Applications.
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/dmg-bg.png"
let W: CGFloat = 540, H: CGFloat = 380

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

// soft gradient background
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.88, green: 0.92, blue: 0.98, alpha: 1)
])!
grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// title text
let para = NSMutableParagraphStyle()
para.alignment = .center
let title = NSAttributedString(string: "Drag the app into Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1),
    .paragraphStyle: para
])
title.draw(in: NSRect(x: 0, y: H - 48, width: W, height: 24))

// arrow pointing right (from the app icon towards the Applications icon)
let arrow = NSBezierPath()
let ax: CGFloat = 232, ay: CGFloat = 118, len: CGFloat = 62
arrow.move(to: NSPoint(x: ax, y: ay + 12))
arrow.line(to: NSPoint(x: ax + len, y: ay + 12))
arrow.move(to: NSPoint(x: ax, y: ay))
arrow.line(to: NSPoint(x: ax + len, y: ay))
arrow.lineWidth = 9
arrow.lineCapStyle = .round
NSColor(calibratedRed: 0.60, green: 0.67, blue: 0.78, alpha: 0.9).setStroke()
arrow.stroke()

// arrow head
let head = NSBezierPath()
head.move(to: NSPoint(x: ax + len + 2, y: ay - 14))
head.line(to: NSPoint(x: ax + len + 24, y: ay + 6))
head.line(to: NSPoint(x: ax + len + 2, y: ay + 26))
head.close()
NSColor(calibratedRed: 0.60, green: 0.67, blue: 0.78, alpha: 0.9).setFill()
head.fill()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render dmg background")
}
try! png.write(to: URL(fileURLWithPath: outPath))
