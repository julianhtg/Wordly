#!/usr/bin/env swift
// Generates Resources/AppIcon.icns: white mic glyph on an indigo→purple
// rounded square. Run via `make icon` (or `swift scripts/make-icon.swift`).
// One-shot asset generator — not part of the app build.
import AppKit

let base = 1024.0

func render(_ size: Double) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / base

    // Rounded-square background with a diagonal gradient.
    let inset = 96.0 * scale
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect,
                            xRadius: 180 * scale, yRadius: 180 * scale)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.45, green: 0.36, blue: 0.93, alpha: 1),
        NSColor(calibratedRed: 0.67, green: 0.30, blue: 0.86, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -60)

    // White SF Symbol mic, centered.
    let glyphSize = size * 0.5
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: mic.size, flipped: false) { r in
            mic.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let g = tinted.size
        let origin = NSPoint(x: (size - g.width) / 2, y: (size - g.height) / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// name → pixel size for the standard iconset.
let variants: [(String, Double)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let data = render(px).representation(using: .png, properties: [:])!
    try! data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "Resources/AppIcon.iconset",
                  "-o", "Resources/AppIcon.icns"]
try! proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(proc.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
