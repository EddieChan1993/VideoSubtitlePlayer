#!/usr/bin/swift
// make_icon.swift — draws a summer-themed icon and writes AppIcon.iconset/
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

    // ── 1. Background: sky-blue → mint-teal gradient ──────────────────────
    let corner = s * 0.22
    let full   = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.addPath(CGPath(roundedRect: full, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.clip()

    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [hex(0x35C2B8), hex(0x5BBDEE)] as CFArray,   // teal(bottom) → blue(top)
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(grad,
        start: CGPoint(x: s * 0.5, y: 0),
        end:   CGPoint(x: s * 0.5, y: s), options: [])

    // ── 2. Wave at bottom ─────────────────────────────────────────────────
    if s >= 64 {
        let wH = s * 0.20
        let wp = CGMutablePath()
        wp.move(to: CGPoint(x: 0, y: wH * 0.55))
        wp.addCurve(to:      CGPoint(x: s * 0.50, y: wH * 0.28),
                    control1: CGPoint(x: s * 0.22, y: wH * 0.85),
                    control2: CGPoint(x: s * 0.33, y: wH * 0.05))
        wp.addCurve(to:      CGPoint(x: s,         y: wH * 0.58),
                    control1: CGPoint(x: s * 0.67, y: wH * 0.50),
                    control2: CGPoint(x: s * 0.78, y: wH * 0.85))
        wp.addLine(to: CGPoint(x: s, y: 0))
        wp.addLine(to: CGPoint(x: 0, y: 0))
        wp.closeSubpath()
        ctx.setFillColor(rgba(255, 255, 255, 0.14))
        ctx.addPath(wp); ctx.fillPath()
    }
    ctx.resetClip()

    // ── 3. Sun (upper-right, behind the screen) ───────────────────────────
    if s >= 24 {
        let sR  = s * 0.115
        let sCX = s * 0.745
        let sCY = s * 0.745

        // glow halo
        ctx.setFillColor(rgba(255, 230, 60, 0.20))
        ctx.fillEllipse(in: CGRect(x: sCX-sR*2.1, y: sCY-sR*2.1, width: sR*4.2, height: sR*4.2))

        // body
        ctx.setFillColor(rgba(255, 215, 40, 0.95))
        ctx.fillEllipse(in: CGRect(x: sCX-sR, y: sCY-sR, width: sR*2, height: sR*2))

        // rays (≥ 56 px)
        if s >= 56 {
            ctx.saveGState()
            ctx.setStrokeColor(rgba(255, 215, 40, 0.88))
            ctx.setLineWidth(s * 0.023)
            ctx.setLineCap(.round)
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4 + .pi / 8
                let r0 = sR * 1.48, r1 = sR * 2.18
                ctx.move(to:    CGPoint(x: sCX + cos(a)*r0, y: sCY + sin(a)*r0))
                ctx.addLine(to: CGPoint(x: sCX + cos(a)*r1, y: sCY + sin(a)*r1))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // ── 4. Screen (white rounded rect, center-left of canvas) ────────────
    let scW = s * 0.60
    let scH = s * 0.40
    let scX = (s - scW) / 2
    let scY = s * 0.37
    let scR = scW * 0.09
    let scRect = CGRect(x: scX, y: scY, width: scW, height: scH)

    // soft drop shadow
    if s >= 56 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s*0.018),
                      blur:   s * 0.06,
                      color:  rgba(0, 50, 90, 0.28))
        ctx.setFillColor(rgba(255, 255, 255, 0.97))
        ctx.addPath(CGPath(roundedRect: scRect, cornerWidth: scR, cornerHeight: scR, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.setFillColor(rgba(255, 255, 255, 0.97))
        ctx.addPath(CGPath(roundedRect: scRect, cornerWidth: scR, cornerHeight: scR, transform: nil))
        ctx.fillPath()
    }

    // inner tint (sky-blue wash)
    let pad = s * 0.022
    ctx.setFillColor(rgba(195, 232, 255, 0.38))
    ctx.addPath(CGPath(roundedRect: scRect.insetBy(dx: pad, dy: pad),
                       cornerWidth: scR*0.75, cornerHeight: scR*0.75, transform: nil))
    ctx.fillPath()

    // ── 5. Play triangle ──────────────────────────────────────────────────
    let pH  = scH * 0.50
    let pCX = scX + scW * 0.52
    let pCY = scY + scH * 0.50

    let tp = CGMutablePath()
    tp.move(to:    CGPoint(x: pCX - pH*0.44, y: pCY - pH*0.50))
    tp.addLine(to: CGPoint(x: pCX - pH*0.44, y: pCY + pH*0.50))
    tp.addLine(to: CGPoint(x: pCX + pH*0.56, y: pCY))
    tp.closeSubpath()
    ctx.setFillColor(rgba(66, 182, 230, 0.88))
    ctx.addPath(tp); ctx.fillPath()

    // ── 6. Subtitle bars (below screen) ──────────────────────────────────
    if s >= 28 {
        let bH  = max(s * 0.043, 2)
        let bR  = bH * 0.5
        let gap = s * 0.056

        let bar1W = s * 0.52
        let bar1Y = scY - gap - bH
        ctx.setFillColor(rgba(255, 255, 255, 0.92))
        ctx.addPath(CGPath(roundedRect: CGRect(x:(s-bar1W)/2, y:bar1Y, width:bar1W, height:bH),
                           cornerWidth: bR, cornerHeight: bR, transform: nil))
        ctx.fillPath()

        if s >= 56 {
            let bar2W = s * 0.36
            let bar2Y = bar1Y - gap * 0.85 - bH
            ctx.setFillColor(rgba(255, 255, 255, 0.68))
            ctx.addPath(CGPath(roundedRect: CGRect(x:(s-bar2W)/2, y:bar2Y, width:bar2W, height:bH),
                               cornerWidth: bR, cornerHeight: bR, transform: nil))
            ctx.fillPath()
        }
    }
}

// MARK: - Generate iconset

let iconsetDir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x",1024),
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
