// Draws the app icon and writes dist/AppIcon.iconset plus assets/AppIcon.icns.
//
//   swift scripts/make-app-icon.swift
//
// Everything is vector, drawn once per size rather than scaled from one bitmap, so the small sizes
// stay sharp. The design: a blue squircle in the app's accent colour, a white display, and a
// pointer on it, which is what remote control looks like at 16 points.
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")

// The whole drawing is described on a 1024 grid and scaled from there.
let grid: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Apple's icon outline is a superellipse, not a rounded rectangle: the corners flow into the sides
/// instead of meeting an arc. An exponent of 5 matches it closely.
func squircle(center: CGPoint, radius: CGFloat, exponent: CGFloat = 5, steps: Int = 1440) -> CGPath {
    let path = CGMutablePath()
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(x: center.x + radius * copysign(pow(abs(c), 2 / exponent), c),
                            y: center.y + radius * copysign(pow(abs(s), 2 / exponent), s))
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

/// A rounded rectangle given in "y grows upward" coordinates.
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

/// The pointer, described tip-first in a box 72 wide and 100 tall with y downward, then placed.
func pointer(tip: CGPoint, height: CGFloat) -> CGPath {
    let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 88), CGPoint(x: 24, y: 66),
        CGPoint(x: 41, y: 100), CGPoint(x: 60, y: 91), CGPoint(x: 43, y: 59),
        CGPoint(x: 73, y: 57),
    ]
    let scale = height / 100
    let path = CGMutablePath()
    for (index, point) in outline.enumerated() {
        let placed = CGPoint(x: tip.x + point.x * scale, y: tip.y - point.y * scale)
        index == 0 ? path.move(to: placed) : path.addLine(to: placed)
    }
    path.closeSubpath()
    return path
}

func draw(into ctx: CGContext, pixels: CGFloat) {
    ctx.scaleBy(x: pixels / grid, y: pixels / grid)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    // The body sits inside the grid the way macOS expects, leaving room for its shadow.
    let body = squircle(center: CGPoint(x: 512, y: 522), radius: 412)

    // Shadow first, cast by a flat fill that the gradient then covers.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x000000, 0.32))
    ctx.addPath(body)
    ctx.setFillColor(color(0x2F6BE0))
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient: the app's accent blue, lit from the top.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(0x74AEFF), color(0x4D8EF7), color(0x1F4FD8)] as CFArray,
                              locations: [0, 0.52, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: 934),
                           end: CGPoint(x: 512, y: 110),
                           options: [])
    // A soft light near the top, so the face is not flat.
    let glow = CGGradient(colorsSpace: space,
                          colors: [color(0xFFFFFF, 0.30), color(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 620,
                           options: [])
    // The lit edge along the top rim.
    ctx.addPath(body)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(8)
    ctx.strokePath()
    ctx.restoreGState()

    // The display: white, filled, so it survives being drawn at sixteen points. Its own shadow
    // lifts it off the blue rather than letting it look like a hole.
    let screen = rounded(264, 410, 496, 320, 40)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x0C2E7A, 0.38))
    ctx.addPath(screen)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    // Neck and base, which is what makes it read as a display rather than a card.
    ctx.addPath(rounded(472, 356, 80, 58, 10))
    ctx.setFillColor(color(0xE4EDFF))
    ctx.fillPath()
    ctx.addPath(rounded(372, 314, 280, 48, 24))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // The face carries a slight tint downward, so a large icon does not read as a flat cut-out.
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    let face = CGGradient(colorsSpace: space,
                          colors: [color(0xFFFFFF), color(0xDCE7FB)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(face,
                           start: CGPoint(x: 512, y: 730),
                           end: CGPoint(x: 512, y: 410),
                           options: [])
    ctx.restoreGState()

    // The pointer, cut out of the display in the body colour.
    ctx.addPath(pointer(tip: CGPoint(x: 440, y: 676), height: 176))
    ctx.setFillColor(color(0x2A5FD0))
    ctx.fillPath()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(into: ctx, pixels: CGFloat(pixels))
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = root.appendingPathComponent("dist/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// iconutil packs the sizes into the single file a bundle carries.
let icns = root.appendingPathComponent("assets/AppIcon.icns")
try FileManager.default.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(icns.path)")
