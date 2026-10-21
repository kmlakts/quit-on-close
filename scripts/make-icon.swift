// Draws the app icon: the red window-close button on a black rounded square.
// Usage: swift scripts/make-icon.swift <output.png>   (1024×1024)
// To regenerate Resources/AppIcon.icns, render the PNG, resize it into an AppIcon.iconset
// (16–512 pt at 1x and 2x, via `sips -z`), then run `iconutil -c icns AppIcon.iconset`.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // Background: macOS icon grid — an 824 pt rounded square centred on the 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x000000).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0x2A2A2C), ending: color(0x050505))?.draw(in: tilePath, angle: -90)
    color(0xFFFFFF, alpha: 0.08).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rim.lineWidth = 4
    rim.stroke()

    // Close button: red circle with a darker rim and a soft top highlight, like the real traffic light.
    let diameter: CGFloat = 460
    let button = NSRect(x: (size - diameter) / 2, y: (size - diameter) / 2, width: diameter, height: diameter)

    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xFF3B30, alpha: 0.35)
    glow.shadowBlurRadius = 40
    glow.set()
    color(0xE0443E).setFill()
    NSBezierPath(ovalIn: button).fill()
    NSGraphicsContext.restoreGraphicsState()

    let face = NSBezierPath(ovalIn: button.insetBy(dx: 10, dy: 10))
    NSGradient(starting: color(0xFF7A72), ending: color(0xFF4A40))?.draw(in: face, angle: -90)

    // The ✕ glyph.
    let glyph = NSBezierPath()
    let arm: CGFloat = diameter * 0.2
    let center = NSPoint(x: size / 2, y: size / 2)
    glyph.move(to: NSPoint(x: center.x - arm, y: center.y - arm))
    glyph.line(to: NSPoint(x: center.x + arm, y: center.y + arm))
    glyph.move(to: NSPoint(x: center.x - arm, y: center.y + arm))
    glyph.line(to: NSPoint(x: center.x + arm, y: center.y - arm))
    glyph.lineWidth = 46
    glyph.lineCapStyle = .round
    color(0x5A0A06).setStroke()
    glyph.stroke()
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
