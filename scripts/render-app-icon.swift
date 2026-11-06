// Renders the Air Agents app icon (design page "Spatial Agents logo") at 1024 px.
// Usage: swift scripts/render-app-icon.swift iOS/App/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func render(background: CGColor?, ink: CGColor, cut: CGColor, to path: String) {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    if let background {
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    // Design: a 160 pt tile holds a 108 pt glyph (viewBox 100), nudged (-3, +3).
    let unit = 1024.0 / 160.0
    let glyph = 108.0 * unit
    let origin = (1024.0 - glyph) / 2
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)                     // SVG coordinates: y down
    ctx.translateBy(x: origin - 3 * unit, y: origin + 3 * unit)
    ctx.scaleBy(x: glyph / 100, y: glyph / 100)

    // Head
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 44 - 30, y: 56 - 30, width: 60, height: 60))
    // Eyes, tilted 10°
    ctx.setFillColor(cut)
    for cx in [35.0, 53.0] {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: 52)
        ctx.rotate(by: -10 * .pi / 180)
        ctx.fillEllipse(in: CGRect(x: -4.6, y: -7.5, width: 9.2, height: 15))
        ctx.restoreGState()
    }
    // Two arcs, centred on the head, from -70° to -20°
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(6.5)
    ctx.setLineCap(.round)
    for r in [40.0, 52.0] {
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: 44, y: 56), radius: r,
                   startAngle: -70 * .pi / 180, endAngle: -20 * .pi / 180, clockwise: false)
        ctx.strokePath()
    }

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments[1]
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
render(background: white, ink: black, cut: white, to: out + "/AppIcon-Light.png")
render(background: black, ink: white, cut: black, to: out + "/AppIcon-Dark.png")
// Tinted: iOS recolours a greyscale glyph; white on black.
render(background: black, ink: white, cut: black, to: out + "/AppIcon-Tinted.png")
