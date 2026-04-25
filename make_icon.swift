#!/usr/bin/swift
// make_icon.swift — watermelon × video player fusion icon
import AppKit
import CoreGraphics

// MARK: - colour helpers

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [r/255, g/255, b/255, a])!
}
func hex(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    rgba(CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF), a)
}

// MARK: - drawing (CGContext, y=0 at bottom)

func drawIcon(ctx: CGContext, s: CGFloat) {

    let full   = CGRect(x: 0, y: 0, width: s, height: s)
    let corner = s * 0.22

    // ── 1. Background: dark green (watermelon exterior) ───────────────────
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: full, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.clip()

    let bgGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [hex(0x1A5E28), hex(0x2E8B42)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bgGrad,
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: s, y: s), options: [])

    // Diagonal dark stripes (watermelon skin texture, larger icons only)
    if s >= 64 {
        ctx.saveGState()
        ctx.setStrokeColor(hex(0x135020, 0.28))
        ctx.setLineWidth(s * 0.055)
        let step = s * 0.26
        var t: CGFloat = -s
        while t < s * 2 {
            ctx.move(to:    CGPoint(x: t,     y: 0))
            ctx.addLine(to: CGPoint(x: t + s, y: s))
            t += step
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // ── 2. Watermelon slice (dome, flat edge down, curve up) ──────────────
    //
    // In CGContext y-up coords:
    //   sliceY  = y of the flat-cut diameter (near lower-center of icon)
    //   apex    = sliceY + outerR  (top of rounded rind, upper part of icon)
    //
    // Arc from angle 0 → π counter-clockwise (clockwise:false) = through π/2 (TOP).
    // This produces a dome with the flat edge at sliceY and the curve going UP.

    let cx     = s * 0.50
    let sliceY = s * 0.35
    let outerR = s * 0.42
    let whiteR = outerR * 0.90
    let redR   = outerR * 0.81

    func domePath(_ r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx + r, y: sliceY))
        p.addArc(center: CGPoint(x: cx, y: sliceY),
                 radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
        p.closeSubpath()
        return p
    }

    // 2a. Drop shadow under the slice
    if s >= 56 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                      blur: s * 0.055,
                      color: rgba(0, 0, 0, 0.35))
        ctx.setFillColor(hex(0x1B5C27))
        ctx.addPath(domePath(outerR)); ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.setFillColor(hex(0x1B5C27))
        ctx.addPath(domePath(outerR)); ctx.fillPath()
    }

    // 2b. White rind strip
    ctx.setFillColor(rgba(248, 248, 248, 0.96))
    ctx.addPath(domePath(whiteR)); ctx.fillPath()

    // 2c. Red flesh with radial gradient
    ctx.saveGState()
    ctx.addPath(domePath(redR)); ctx.clip()
    let redGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [hex(0xFF7070), hex(0xE80F0F)] as CFArray,
        locations: [0, 1]
    )!
    let gradCenter = CGPoint(x: cx, y: sliceY + redR * 0.38)
    ctx.drawRadialGradient(redGrad,
        startCenter: gradCenter, startRadius: 0,
        endCenter: gradCenter,   endRadius: redR,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // 2d. Seeds (scattered in red flesh)
    if s >= 48 {
        // (dx, dy) as fraction of redR; dy>0 = above flat edge (inside dome)
        let seeds: [(CGFloat, CGFloat)] = [
            ( 0.14, 0.30), (-0.36, 0.35), ( 0.50, 0.38),
            (-0.10, 0.64), ( 0.36, 0.70), (-0.52, 0.58),
        ]
        let seedW = max(s * 0.026, 2)
        let seedH = seedW * 1.75
        ctx.setFillColor(rgba(12, 12, 12, 0.76))
        for (dx, dy) in seeds {
            let sx = cx + dx * redR
            let sy = sliceY + dy * redR
            ctx.saveGState()
            ctx.translateBy(x: sx, y: sy)
            ctx.rotate(by: dx * 0.55)
            ctx.fillEllipse(in: CGRect(x: -seedW/2, y: -seedH/2, width: seedW, height: seedH))
            ctx.restoreGState()
        }
    }

    // 2e. Play triangle (white, centered in dome)
    let pCY = sliceY + redR * 0.45
    let pH  = redR * 0.54
    let tp  = CGMutablePath()
    tp.move(to:    CGPoint(x: cx - pH*0.44, y: pCY - pH*0.50))
    tp.addLine(to: CGPoint(x: cx - pH*0.44, y: pCY + pH*0.50))
    tp.addLine(to: CGPoint(x: cx + pH*0.56, y: pCY))
    tp.closeSubpath()
    // Soft shadow behind triangle
    if s >= 56 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008),
                      blur: s * 0.03, color: rgba(0, 0, 0, 0.30))
        ctx.setFillColor(rgba(255, 255, 255, 0.94))
        ctx.addPath(tp); ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.setFillColor(rgba(255, 255, 255, 0.94))
        ctx.addPath(tp); ctx.fillPath()
    }

    // ── 3. Subtitle bars (below flat edge, on green background) ───────────
    if s >= 28 {
        let bH  = max(s * 0.042, 2.0)
        let bR  = bH * 0.5
        let gap = s * 0.048

        let bar1W = s * 0.52
        let bar1Y = sliceY - gap * 1.8 - bH
        ctx.setFillColor(rgba(255, 255, 255, 0.88))
        ctx.addPath(CGPath(roundedRect: CGRect(x: (s - bar1W) / 2, y: bar1Y, width: bar1W, height: bH),
                           cornerWidth: bR, cornerHeight: bR, transform: nil))
        ctx.fillPath()

        if s >= 56 {
            let bar2W = s * 0.36
            let bar2Y = bar1Y - gap - bH
            ctx.setFillColor(rgba(255, 255, 255, 0.60))
            ctx.addPath(CGPath(roundedRect: CGRect(x: (s - bar2W) / 2, y: bar2Y, width: bar2W, height: bH),
                               cornerWidth: bR, cornerHeight: bR, transform: nil))
            ctx.fillPath()
        }
    }
}

// MARK: - Generate iconset

let iconsetDir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16",        16),
    ("icon_16x16@2x",     32),
    ("icon_32x32",        32),
    ("icon_32x32@2x",     64),
    ("icon_128x128",     128),
    ("icon_128x128@2x",  256),
    ("icon_256x256",     256),
    ("icon_256x256@2x",  512),
    ("icon_512x512",     512),
    ("icon_512x512@2x", 1024),
]

for (name, px) in specs {
    guard let ctx = CGContext(
        data: nil, width: px, height: px,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { print("⚠️  CGContext failed \(px)"); continue }

    drawIcon(ctx: ctx, s: CGFloat(px))

    guard let cgImg = ctx.makeImage() else { continue }
    let ns = NSImage(cgImage: cgImg, size: NSSize(width: px, height: px))
    guard let tiff   = ns.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png    = bitmap.representation(using: .png, properties: [:])
    else { continue }

    try? png.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name).png"))
    print("  ✓  \(name).png (\(px)px)")
}
print("✅  AppIcon.iconset done")
