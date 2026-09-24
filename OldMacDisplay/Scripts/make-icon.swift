// Draws the OldMacDisplay app icon and writes an .iconset next to it.
//
// The icon is generated rather than committed as binary blobs so it can be
// tweaked in one place and re-rendered at every size. Run via Scripts/icon.sh.
//
// Subject: the 2013 iMac this app exists to revive — the silhouette with the
// chin and the wedge foot is instantly recognisable — with a desktop sliding in
// from the left, which is what "extended display" actually looks like.

import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

/// Every size macOS asks for, in points, with the scales each is needed at.
let variants: [(points: Int, scales: [Int])] = [
    (16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])
]

func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// Rounded rectangle with the corner curvature macOS app icons use.
func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(size: CGFloat, into context: CGContext) {
    let s = { (fraction: CGFloat) in fraction * size }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // MARK: Background plate
    //
    // Full bleed, with the Big Sur corner ratio. macOS 26 masks every app icon
    // into a rounded square of its own: an inset plate would then sit inside a
    // second system plate and read as a frame around a frame. Filling the
    // canvas makes the two shapes coincide, and on Catalina — which applies no
    // mask — the same drawing stands on its own.
    let plate = CGRect(x: 0, y: 0, width: size, height: size)
    let plateRadius = size * 0.2237

    context.saveGState()
    context.addPath(roundedRect(plate, radius: plateRadius))
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let backdrop = CGGradient(colorsSpace: space,
                              colors: [color(88, 126, 255), color(23, 40, 122)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(backdrop,
                               start: CGPoint(x: plate.midX, y: plate.maxY),
                               end: CGPoint(x: plate.midX, y: plate.minY),
                               options: [])

    // A soft highlight across the top third keeps the plate from looking flat.
    let sheen = CGGradient(colorsSpace: space,
                           colors: [color(255, 255, 255, 0.22),
                                    color(255, 255, 255, 0)] as CFArray,
                           locations: [0, 1])!
    context.drawLinearGradient(sheen,
                               start: CGPoint(x: plate.midX, y: plate.maxY),
                               end: CGPoint(x: plate.midX, y: plate.midY),
                               options: [])
    context.restoreGState()

    // MARK: iMac
    //
    // Proportions follow the real machine: a 16:9 screen, a shallow chin, a
    // narrow neck and a wedge foot.
    let bodyWidth = s(0.66)
    let bodyHeight = bodyWidth * 0.66
    let body = CGRect(x: (size - bodyWidth) / 2, y: s(0.32), width: bodyWidth, height: bodyHeight)
    let bodyRadius = s(0.022)

    // Drop the whole machine onto the plate with a soft shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s(0.012)),
                      blur: s(0.05),
                      color: color(8, 16, 54, 0.45))

    context.addPath(roundedRect(body, radius: bodyRadius))
    context.setFillColor(color(244, 246, 252))
    context.fillPath()

    // Neck and foot.
    let neck = CGRect(x: size / 2 - s(0.050), y: s(0.215), width: s(0.10), height: s(0.11))
    context.addPath(roundedRect(neck, radius: s(0.012)))
    context.setFillColor(color(226, 230, 241))
    context.fillPath()

    let foot = CGRect(x: size / 2 - s(0.160), y: s(0.180), width: s(0.32), height: s(0.046))
    context.addPath(roundedRect(foot, radius: s(0.021)))
    context.setFillColor(color(236, 239, 247))
    context.fillPath()
    context.restoreGState()

    // MARK: Screen
    let bezel = s(0.018)
    let chin = bodyHeight * 0.17
    let screen = CGRect(x: body.minX + bezel,
                        y: body.minY + chin,
                        width: body.width - bezel * 2,
                        height: body.height - chin - bezel)

    context.saveGState()
    context.addPath(roundedRect(screen, radius: s(0.010)))
    context.clip()

    context.setFillColor(color(12, 20, 56))
    context.fill(screen)

    // The desktop arriving from the MacBook: a bright panel entering from the
    // left. Its leading edge is slanted rather than vertical, so the shape
    // reads as motion into the screen instead of a screen that is half lit.
    let lead = screen.minX + screen.width * 0.66
    let slant = screen.width * 0.09
    let incoming = CGMutablePath()
    incoming.move(to: CGPoint(x: screen.minX, y: screen.minY))
    incoming.addLine(to: CGPoint(x: lead, y: screen.minY))
    incoming.addLine(to: CGPoint(x: lead - slant, y: screen.maxY))
    incoming.addLine(to: CGPoint(x: screen.minX, y: screen.maxY))
    incoming.closeSubpath()

    context.saveGState()
    context.addPath(incoming)
    context.clip()
    let stream = CGGradient(colorsSpace: space,
                            colors: [color(122, 226, 255), color(48, 120, 255)] as CFArray,
                            locations: [0, 1])!
    context.drawLinearGradient(stream,
                               start: CGPoint(x: screen.minX, y: screen.maxY),
                               end: CGPoint(x: lead, y: screen.minY),
                               options: [])
    context.restoreGState()

    // Glow spilling off the leading edge onto the dark desktop, so the two
    // halves belong to the same screen rather than looking like a seam.
    context.saveGState()
    context.addPath(incoming)
    context.setStrokeColor(color(198, 243, 255, 0.95))
    context.setLineWidth(s(0.009))
    context.setShadow(offset: .zero, blur: s(0.035), color: color(140, 220, 255, 0.9))
    context.strokePath()
    context.restoreGState()

    context.restoreGState()

    // MARK: Chin and the Apple-style dimple
    let dimple = CGRect(x: size / 2 - s(0.015),
                        y: body.minY + chin / 2 - s(0.015),
                        width: s(0.030), height: s(0.030))
    context.setFillColor(color(198, 205, 223))
    context.fillEllipse(in: dimple)
}

func render(pixels: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil,
                                  width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create a \(pixels)px bitmap context")
    }
    draw(size: CGFloat(pixels), into: context)

    guard let image = context.makeImage() else { fatalError("Could not render \(pixels)px") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(pixels)px as PNG")
    }
    return data
}

let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    for scale in variant.scales {
        let suffix = scale == 1 ? "" : "@\(scale)x"
        let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
        let data = render(pixels: variant.points * scale)
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

print("Wrote \(iconset.path)")
