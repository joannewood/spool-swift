#!/usr/bin/env swift
// One-off generator for Spool's app icon + menu bar icon — not part of the app build,
// run manually (`swift Tools/IconGenerator/generate_icon.swift`) whenever the icon
// design changes, producing every PNG size + Contents.json macOS's AppIcon.appiconset
// (and the MenuBarIcon template imageset) expect directly into
// SpoolApp/Resources/Assets.xcassets. Draws with plain AppKit/Core Graphics rather than
// SwiftUI's ImageRenderer so it runs as a bare command-line script with no app run loop
// needed.
//
// Both previously shipped genuinely 2x-oversized (see `renderPixelExact`'s doc comment
// below for the actual root cause and how it's fixed now) — an earlier menu bar attempt
// using this same generated-asset approach was abandoned for that reason, in favor of a
// plain SF Symbol. Now that the real bug is fixed, back to the custom mark.
//
// Design: a "spool" mandala — an outer ring, a concentric double-ring hub at the
// center (the spool's core, viewed end-on), and 8 S-curl "hooks" radiating outward at
// 45° increments, each echoing a loop of wound filament — rendered in white on the
// existing blue-to-indigo gradient squircle for the app icon. The menu bar icon is the
// same hub alone, black, as a template image (macOS recolors template images
// automatically for light/dark menu bars) — no S-curls, too fine-grained at that scale.

import AppKit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Tools/IconGenerator
    .deletingLastPathComponent() // Tools
    .deletingLastPathComponent() // repo root
let assetsDir = repoRoot.appendingPathComponent("SpoolApp/Resources/Assets.xcassets")
let appIconDir = assetsDir.appendingPathComponent("AppIcon.appiconset")
let menuBarIconDir = assetsDir.appendingPathComponent("MenuBarIcon.imageset")

try? FileManager.default.createDirectory(at: appIconDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: menuBarIconDir, withIntermediateDirectories: true)

// MARK: - The mandala glyph, shared by both icons

/// One literal "S" — a typographic S letterform (two cubic-bezier "C" curves joined at
/// the waist, open terminals rather than curled into a full loop), standing for
/// "Spool", built in local coordinates with its spine along the y-axis so placing/
/// rotating it radially is a single affine transform. An earlier two-semicircle
/// "sigmoid tile" version read as a generic spiral/hook rather than a legible S.
func sShapePath(width w: CGFloat, height h: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: w * 0.5, y: h))
    path.addCurve(
        to: CGPoint(x: -w * 0.15, y: h * 0.12),
        control1: CGPoint(x: -w * 0.65, y: h),
        control2: CGPoint(x: -w * 0.65, y: h * 0.45)
    )
    path.addCurve(
        to: CGPoint(x: w * 0.15, y: -h * 0.12),
        control1: CGPoint(x: w * 0.35, y: -h * 0.15),
        control2: CGPoint(x: -w * 0.35, y: h * 0.15)
    )
    path.addCurve(
        to: CGPoint(x: -w * 0.5, y: -h),
        control1: CGPoint(x: w * 0.65, y: -h * 0.45),
        control2: CGPoint(x: w * 0.65, y: -h)
    )
    return path
}

/// Draws the full mandala (outer ring + hub + radiating S-curls) into `ctx`, centered
/// in a `size`×`size` square (relative to the context's *current* origin — callers
/// wanting it centered in a larger canvas should translate first), stroked in `color`.
/// `hookCount`/`simplifiedHub` exist because the full 8-S, double-ring-hub design turns
/// to mud at small icon sizes (confirmed live at 32px) — Apple's own HIG guidance is to
/// simplify detail at smaller renditions rather than just scale the same artwork down,
/// so the 16/32pt renditions use fewer, larger S's and a single hub ring instead.
func drawMandala(
    ctx: CGContext, size: CGFloat, color: NSColor, hookCount: Int = 8, simplifiedHub: Bool = false,
    strokeWidthFactor: CGFloat? = nil
) {
    let cx = size / 2
    let cy = size / 2

    let outerRingRadius = size * 0.44
    let hubOuterRadius = size * 0.115
    let hubInnerRadius = size * 0.068
    // The S curve's control points extend to ±0.65×width, past its ±0.5×width
    // endpoints — its actual visual footprint is close to 1.3×`sWidth`, not `sWidth`
    // (confirmed live: using `sWidth` directly packed 8 of them tightly enough to
    // overlap into a solid pinwheel instead of 8 distinct, gapped S's).
    let sWidth = size * (hookCount <= 4 ? 0.135 : 0.075)
    let sHeight = size * (hookCount <= 4 ? 0.155 : 0.095)
    let sDistanceFromCenter = size * 0.29
    // `strokeWidthFactor` lets a caller (the app icon, specifically — see
    // `drawAppIcon`) bolden its line weight without also thickening the menu bar
    // bullseye, which shares this same function and was already confirmed working.
    let strokeWidth = max(1.5, size * (strokeWidthFactor ?? (hookCount <= 4 ? 0.045 : 0.028)))

    color.setStroke()
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Outer ring.
    ctx.addEllipse(in: CGRect(x: cx - outerRingRadius, y: cy - outerRingRadius, width: outerRingRadius * 2, height: outerRingRadius * 2))
    ctx.strokePath()

    // Hub: echoes the spool's own core viewed end-on — two concentric rings normally,
    // simplified to one when there's no room for two to read as distinct rings.
    ctx.addEllipse(in: CGRect(x: cx - hubOuterRadius, y: cy - hubOuterRadius, width: hubOuterRadius * 2, height: hubOuterRadius * 2))
    ctx.strokePath()
    if !simplifiedHub {
        ctx.addEllipse(in: CGRect(x: cx - hubInnerRadius, y: cy - hubInnerRadius, width: hubInnerRadius * 2, height: hubInnerRadius * 2))
        ctx.strokePath()
    }

    // Radiating S-curls (each a literal "S", for Spool), evenly spaced, each rotated so
    // its spine points outward.
    for i in 0..<hookCount {
        let angle = CGFloat(i) * (2 * .pi / CGFloat(hookCount))
        var transform = CGAffineTransform(translationX: cx, y: cy)
        transform = transform.rotated(by: angle)
        transform = transform.translatedBy(x: 0, y: sDistanceFromCenter)
        let s = sShapePath(width: sWidth, height: sHeight)
        ctx.addPath(s.copy(using: &transform)!)
        ctx.strokePath()
    }
}

// MARK: - App icon (squircle gradient background + white mandala)

struct IconSpec { let points: Int; let scale: Int; let filename: String }

let appIconSpecs: [IconSpec] = [
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

/// Renders directly into an `NSBitmapImageRep` sized exactly `pixelSize`×`pixelSize` —
/// NOT `NSImage(size:).lockFocus()`, which was the actual root cause of every icon
/// this script produced coming out exactly 2x too large (confirmed live via actool's
/// own build warnings, e.g. "icon_512x512@2x.png is 2048x2048 but should be 1024x1024",
/// for every single size). `lockFocus()` bakes in the *host Mac's own* Retina backing
/// scale factor into the exported pixels regardless of the requested `NSSize` — a
/// classic AppKit gotcha, and exactly why actool considered every image invalid for
/// its declared (idiom, size, scale) slot and silently skipped generating
/// `CFBundleIconName` entirely, which is why the Dock never showed a custom icon at
/// all, independent of any icon *cache* (there was nothing valid to cache in the first
/// place). Drawing into an explicitly-sized bitmap rep instead is unaffected by the
/// current display's scale factor.
func renderPixelExact(pixelSize: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fatalError("failed to create a \(pixelSize)x\(pixelSize) bitmap")
    }
    bitmap.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext, CGFloat(pixelSize))
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode a \(pixelSize)x\(pixelSize) PNG")
    }
    return png
}

func drawAppIcon(pixelSize: Int) -> Data {
    renderPixelExact(pixelSize: pixelSize) { ctx, size in

    // Squircle background, matching macOS's ~22.37%-of-edge corner radius convention.
    let cornerRadius = size * 0.2237
    let backgroundPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: cornerRadius, yRadius: cornerRadius)
    ctx.saveGState()
    backgroundPath.addClip()
    // Darkened from the original (0.29, 0.45, 0.98)→(0.45, 0.29, 0.90) — the white
    // glyph's outline was still hard to see against that lighter blue/purple.
    let colors = [
        NSColor(calibratedRed: 0.13, green: 0.24, blue: 0.68, alpha: 1.0).cgColor, // top: deep blue
        NSColor(calibratedRed: 0.28, green: 0.13, blue: 0.58, alpha: 1.0).cgColor, // bottom: deep indigo
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

    // The mandala glyph itself, inset so it stays clear of the squircle's corners.
    // 0.07 (86% fill) read as oversized/cramped against the squircle; 0.16 (68% fill)
    // pulled back too far the other way — standard macOS app icon glyphs usually sit
    // around 70-75%.
    let inset = size * 0.13
    let isSmall = pixelSize <= 40
    ctx.saveGState()
    ctx.translateBy(x: inset, y: inset)
    drawMandala(
        ctx: ctx, size: size - inset * 2, color: .white, hookCount: isSmall ? 4 : 8, simplifiedHub: isSmall,
        strokeWidthFactor: isSmall ? 0.095 : 0.07
    )
    ctx.restoreGState()
    }
}

for spec in appIconSpecs {
    let pixelSize = spec.points * spec.scale
    let png = drawAppIcon(pixelSize: pixelSize)
    let url = appIconDir.appendingPathComponent(spec.filename)
    try! png.write(to: url)
    print("wrote \(spec.filename) (\(pixelSize)x\(pixelSize))")
}

let appIconContentsJSON = """
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
try! appIconContentsJSON.write(to: appIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote AppIcon Contents.json")

// MARK: - Menu bar icon (hub alone, black, template image)

/// A plain bullseye (outer ring + double-ring hub, no S-curls) — at true menu-bar scale
/// (~18pt) the full mandala's S-curls are too fine-grained to read as anything but
/// noise. `hookCount: 0` skips them entirely, `simplifiedHub: false` keeps both hub
/// rings for a proper bullseye look.
func drawMenuBarIcon(pixelSize: Int) -> Data {
    renderPixelExact(pixelSize: pixelSize) { ctx, size in
        drawMandala(ctx: ctx, size: size, color: .black, hookCount: 0, simplifiedHub: false)
    }
}

let menuBarSpecs: [IconSpec] = [
    IconSpec(points: 18, scale: 1, filename: "menubar_18pt.png"),
    IconSpec(points: 18, scale: 2, filename: "menubar_18pt@2x.png"),
    IconSpec(points: 18, scale: 3, filename: "menubar_18pt@3x.png"),
]

for spec in menuBarSpecs {
    let pixelSize = spec.points * spec.scale
    let png = drawMenuBarIcon(pixelSize: pixelSize)
    let url = menuBarIconDir.appendingPathComponent(spec.filename)
    try! png.write(to: url)
    print("wrote \(spec.filename) (\(pixelSize)x\(pixelSize))")
}

let menuBarContentsJSON = """
{
  "images" : [
    { "filename" : "menubar_18pt.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menubar_18pt@2x.png", "idiom" : "mac", "scale" : "2x" },
    { "filename" : "menubar_18pt@3x.png", "idiom" : "mac", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
"""
try! menuBarContentsJSON.write(to: menuBarIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote MenuBarIcon Contents.json")
