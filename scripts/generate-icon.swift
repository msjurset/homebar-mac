#!/usr/bin/env swift

import AppKit
import CoreGraphics

/// Draws the HomeBar app icon: a blue house silhouette on a deep-blue gradient
/// rounded square, matching the menu bar glyph and accent theme.
func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        return image
    }

    let inset = size * 0.05
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = size * 0.22
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Background: deep blue gradient, top lighter to bottom darker
    context.saveGState()
    let bgPath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.addPath(bgPath)
    context.clip()
    let bgColors = [
        CGColor(red: 0.09, green: 0.13, blue: 0.24, alpha: 1.0),
        CGColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1.0),
    ]
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: size),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
    }
    context.restoreGState()

    // House silhouette
    let cx = size / 2
    let cy = size / 2
    let houseWidth = size * 0.46
    let houseHeight = size * 0.48
    let houseLeft = cx - houseWidth / 2
    let houseBottom = cy - houseHeight / 2
    let houseTop = cy + houseHeight / 2
    let bodyHeight = houseHeight * 0.55
    let roofLine = houseBottom + bodyHeight

    let housePath = CGMutablePath()
    housePath.move(to: CGPoint(x: houseLeft, y: houseBottom))
    housePath.addLine(to: CGPoint(x: houseLeft + houseWidth, y: houseBottom))
    housePath.addLine(to: CGPoint(x: houseLeft + houseWidth, y: roofLine))
    housePath.addLine(to: CGPoint(x: cx, y: houseTop))
    housePath.addLine(to: CGPoint(x: houseLeft, y: roofLine))
    housePath.closeSubpath()

    // Fill with accent blue vertical gradient
    context.saveGState()
    context.addPath(housePath)
    context.clip()
    let houseColors = [
        CGColor(red: 0.36, green: 0.60, blue: 0.98, alpha: 1.0),
        CGColor(red: 0.18, green: 0.42, blue: 0.88, alpha: 1.0),
    ]
    if let grad = CGGradient(colorsSpace: colorSpace, colors: houseColors as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: houseTop),
                                   end: CGPoint(x: 0, y: houseBottom),
                                   options: [])
    }
    context.restoreGState()

    // Subtle outline to crispen edges at small sizes
    context.addPath(housePath)
    context.setStrokeColor(CGColor(red: 0.12, green: 0.22, blue: 0.50, alpha: 0.45))
    context.setLineWidth(max(0.6, size * 0.006))
    context.strokePath()

    // Door: rounded rectangle carved out near the base
    let doorWidth = houseWidth * 0.24
    let doorHeight = bodyHeight * 0.60
    let doorRect = CGRect(
        x: cx - doorWidth / 2,
        y: houseBottom,
        width: doorWidth,
        height: doorHeight
    )
    let doorCorner = doorWidth * 0.18
    let doorPath = CGPath(roundedRect: doorRect, cornerWidth: doorCorner, cornerHeight: doorCorner, transform: nil)
    context.addPath(doorPath)
    context.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 0.95))
    context.fillPath()

    return image
}

// Required macOS icon sizes
let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let iconsetPath = "AppIcon.iconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = renderIcon(size: size)
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to render \(name)")
        continue
    }
    let path = "\(iconsetPath)/\(name).png"
    try! pngData.write(to: URL(fileURLWithPath: path))
    print("Generated \(path) (\(Int(size))x\(Int(size)))")
}

print("\nConverting to .icns...")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Created AppIcon.icns")
} else {
    print("iconutil failed")
    exit(1)
}

try? fm.removeItem(atPath: iconsetPath)
