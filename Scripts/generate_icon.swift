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
let background = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
let card = NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1.0)
let shadow = NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.22, alpha: 1.0)
let accent = NSColor(calibratedRed: 0.43, green: 0.58, blue: 0.87, alpha: 1.0)

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

    let frame = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = CGFloat(size) * 0.23
    let shell = NSBezierPath(roundedRect: frame, xRadius: corner, yRadius: corner)
    background.setFill()
    shell.fill()

    let backCard = NSBezierPath(
        roundedRect: NSRect(
            x: CGFloat(size) * 0.22,
            y: CGFloat(size) * 0.21,
            width: CGFloat(size) * 0.43,
            height: CGFloat(size) * 0.48
        ),
        xRadius: CGFloat(size) * 0.08,
        yRadius: CGFloat(size) * 0.08
    )
    shadow.setFill()
    backCard.fill()

    let frontCard = NSBezierPath(
        roundedRect: NSRect(
            x: CGFloat(size) * 0.35,
            y: CGFloat(size) * 0.31,
            width: CGFloat(size) * 0.43,
            height: CGFloat(size) * 0.48
        ),
        xRadius: CGFloat(size) * 0.08,
        yRadius: CGFloat(size) * 0.08
    )
    card.setFill()
    frontCard.fill()

    let avatar = NSBezierPath(
        ovalIn: NSRect(
            x: CGFloat(size) * 0.46,
            y: CGFloat(size) * 0.56,
            width: CGFloat(size) * 0.14,
            height: CGFloat(size) * 0.14
        )
    )
    background.setFill()
    avatar.fill()

    let line1 = NSBezierPath(
        roundedRect: NSRect(
            x: CGFloat(size) * 0.45,
            y: CGFloat(size) * 0.47,
            width: CGFloat(size) * 0.24,
            height: CGFloat(size) * 0.045
        ),
        xRadius: CGFloat(size) * 0.02,
        yRadius: CGFloat(size) * 0.02
    )
    let line2 = NSBezierPath(
        roundedRect: NSRect(
            x: CGFloat(size) * 0.45,
            y: CGFloat(size) * 0.40,
            width: CGFloat(size) * 0.18,
            height: CGFloat(size) * 0.045
        ),
        xRadius: CGFloat(size) * 0.02,
        yRadius: CGFloat(size) * 0.02
    )
    shadow.setFill()
    line1.fill()
    line2.fill()

    let dot = NSBezierPath(
        ovalIn: NSRect(
            x: CGFloat(size) * 0.66,
            y: CGFloat(size) * 0.18,
            width: CGFloat(size) * 0.12,
            height: CGFloat(size) * 0.12
        )
    )
    accent.setFill()
    dot.fill()

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
