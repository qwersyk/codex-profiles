import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconPath = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: false)

let fileManager = FileManager.default
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let size = variant.size
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        continue
    }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        NSGraphicsContext.restoreGraphicsState()
        continue
    }
    NSGraphicsContext.current = context

    let unit = CGFloat(size)
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)
    }
    func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius * unit, yRadius: radius * unit)
    }
    let shell = rounded(0.055, 0.055, 0.89, 0.89, radius: 0.205)
    NSGraphicsContext.saveGraphicsState()
    let dropShadow = NSShadow()
    dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    dropShadow.shadowBlurRadius = unit * 0.035
    dropShadow.shadowOffset = NSSize(width: 0, height: -unit * 0.014)
    dropShadow.set()
    NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.18, alpha: 1).setFill()
    shell.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.24, green: 0.30, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.16, alpha: 1)
    ])!.draw(in: shell, angle: -65)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    shell.lineWidth = max(0.5, unit * 0.002)
    shell.stroke()

    func accountCard(x: CGFloat, y: CGFloat, fill: NSColor, ink: NSColor) {
        let path = rounded(x, y, 0.36, 0.43, radius: 0.065)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.02, green: 0.06, blue: 0.07, alpha: 0.25)
        shadow.shadowBlurRadius = unit * 0.022
        shadow.shadowOffset = NSSize(width: 0, height: -unit * 0.012)
        shadow.set()
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        ink.setFill()
        NSBezierPath(ovalIn: rect(x + 0.126, y + 0.245, 0.108, 0.108)).fill()
        rounded(x + 0.074, y + 0.09, 0.212, 0.12, radius: 0.06).fill()
    }
    accountCard(x: 0.205, y: 0.3375,
                fill: NSColor(calibratedRed: 0.43, green: 0.68, blue: 0.65, alpha: 1),
                ink: NSColor(calibratedRed: 0.15, green: 0.37, blue: 0.36, alpha: 1))
    accountCard(x: 0.435, y: 0.2325,
                fill: NSColor(calibratedWhite: 0.96, alpha: 1),
                ink: NSColor(calibratedRed: 0.19, green: 0.48, blue: 0.45, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        continue
    }

    try pngData.write(to: outputDirectory.appendingPathComponent(variant.name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", outputDirectory.path, "-o", iconPath.path]
try task.run()
task.waitUntilExit()

guard task.terminationStatus == 0 else {
    throw NSError(domain: "iconutil", code: Int(task.terminationStatus))
}
