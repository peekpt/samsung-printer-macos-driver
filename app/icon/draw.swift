import AppKit

// Draw a 1024x1024 app icon (a printer) and write it as PNG.
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon.png"
let S: CGFloat = 1024

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// rounded background with gradient
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S), xRadius: 224, yRadius: 224)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.86, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.48, alpha: 1)
])!
grad.draw(in: bg, angle: -90)

// sheet of paper coming out of the top
NSColor.white.setFill()
let paper = NSBezierPath(roundedRect: NSRect(x: S*0.30, y: S*0.50, width: S*0.40, height: S*0.30), xRadius: 18, yRadius: 18)
paper.fill()
NSColor(calibratedWhite: 0.80, alpha: 1).setStroke()
paper.lineWidth = 8
paper.stroke()

// printer body
NSColor.white.setFill()
let body = NSBezierPath(roundedRect: NSRect(x: S*0.20, y: S*0.30, width: S*0.60, height: S*0.26), xRadius: 28, yRadius: 28)
body.fill()

// output slot
NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: S*0.30, y: S*0.47, width: S*0.40, height: S*0.035), xRadius: 6, yRadius: 6).fill()

// little status light
NSColor(calibratedRed: 0.35, green: 0.90, blue: 0.45, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: S*0.31, y: S*0.34, width: S*0.05, height: S*0.05)).fill()

// bottom paper tray
NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: S*0.26, y: S*0.18, width: S*0.48, height: S*0.10), xRadius: 16, yRadius: 16).fill()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try! png.write(to: URL(fileURLWithPath: outPath))
