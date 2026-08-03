#!/usr/bin/env swift
// One-off generator for Spool's app icon — not part of the app build, run manually
// (`swift Tools/IconGenerator/generate_icon.swift`) whenever the icon design changes,
// producing every PNG size + Contents.json macOS's AppIcon.appiconset expects directly
// into SpoolApp/Resources/Assets.xcassets. Draws with plain AppKit/Core Graphics rather
// than SwiftUI's ImageRenderer so it runs as a bare command-line script with no app
// run loop needed.
//
// Design: a bold white spool (thread-reel) silhouette — rounded-flange hourglass shape,
// echoing the app's own name — on a blue-to-indigo gradient squircle, matching the
// rounded-square + gradient + single bold glyph convention of modern macOS app icons.

import AppKit

let outputDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Tools/IconGenerator
    .deletingLastPathComponent() // Tools
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("SpoolApp/Resources/Assets.xcassets/AppIcon.appiconset")

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

struct IconSpec { let points: Int; let scale: Int; let filename: String }

let specs: [IconSpec] = [
    IconSpec(points: 16, scale: 1, filename: "icon_16x16.png"),
    IconSpec(points: 16, scale: 2, filename: "icon_16x16@2x.png"),
    IconSpec(points: 32, scale: 1, filename: "icon_32x32.png"),
    IconSpec(points: 32, scale: 2, filename: "icon_32x32@2x.png"),
    IconSpec(points: 128, scale: 1, filename: "icon_128x128.png"),
    IconSpec(points: 128, scale: 2, filename: "icon_128x128@2x.png"),
    IconSpec(points: 256, scale: 1, filename: "icon_256x256.png"),
    IconSpec(points: 256, scale: 2, filename: "icon_256x256@2x.png"),
    IconSpec(points: 512, scale: 1, filename: "icon_512x512.png"),
    IconSpec(points: 512, scale: 2, filename: "icon_512x512@2x.png"),
]

func drawIcon(pixelSize: Int) -> NSImage {
    let size = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Squircle background, matching macOS's ~22.37%-of-edge corner radius convention.
    let cornerRadius = size * 0.2237
    let backgroundPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: cornerRadius, yRadius: cornerRadius)
    ctx.saveGState()
    backgroundPath.addClip()
    let colors = [
        NSColor(calibratedRed: 0.29, green: 0.45, blue: 0.98, alpha: 1.0).cgColor, // top: blue
        NSColor(calibratedRed: 0.45, green: 0.29, blue: 0.90, alpha: 1.0).cgColor, // bottom: indigo/purple
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // Subtle top highlight for depth, like most modern macOS icons.
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(highlight, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: size * 0.55), options: [])
    ctx.restoreGState()

    // Spool (filament reel) glyph, viewed face-on: a ring with a center hole, plus a
    // short trailing line for the loose filament end — instantly reads as a spool
    // rather than a generic ring/record, and stays legible at 16x16.
    let cx = size / 2
    let cy = size / 2
    let outerRadius = size * 0.30
    let innerRadius = size * 0.125

    let ring = NSBezierPath()
    ring.windingRule = .evenOdd
    ring.appendOval(in: NSRect(x: cx - outerRadius, y: cy - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
    ring.appendOval(in: NSRect(x: cx - innerRadius, y: cy - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
    NSColor.white.setFill()
    ring.fill()

    // Loose filament end: a short capsule trailing off the ring at a jaunty angle.
    let angle = CGFloat.pi * 0.28
    let startR = outerRadius * 0.92
    let endR = outerRadius * 1.42
    let start = NSPoint(x: cx + cos(angle) * startR, y: cy + sin(angle) * startR)
    let end = NSPoint(x: cx + cos(angle) * endR, y: cy + sin(angle) * endR)
    let filamentLine = NSBezierPath()
    filamentLine.move(to: start)
    filamentLine.line(to: end)
    filamentLine.lineWidth = max(1.5, size * 0.028)
    filamentLine.lineCapStyle = .round
    NSColor.white.setStroke()
    filamentLine.stroke()

    image.unlockFocus()
    return image
}

for spec in specs {
    let pixelSize = spec.points * spec.scale
    let image = drawIcon(pixelSize: pixelSize)
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("failed to render \(spec.filename)")
    }
    let url = outputDir.appendingPathComponent(spec.filename)
    try! png.write(to: url)
    print("wrote \(spec.filename) (\(pixelSize)x\(pixelSize))")
}

let contentsJSON = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contentsJSON.write(to: outputDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
