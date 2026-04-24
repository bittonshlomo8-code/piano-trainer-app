#!/usr/bin/env swift
/// Generates Resources/AppIcon.icns — run once from the repo root.
/// Usage: swift scripts/make-icon.swift
import AppKit
import CoreGraphics

func renderIcon(px: Int) -> NSImage {
    let s = CGFloat(px)
    return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        // Rounded-rect background
        let r = s * 0.22
        ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                           cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()

        // Piano key layout: 7 white keys
        let nWhite   = 7
        let margin   = s * 0.095
        let totalW   = s - 2 * margin
        let kW       = totalW / CGFloat(nWhite)
        let kH       = s * 0.58
        let kY       = (s - kH) / 2
        let kr       = s * 0.016

        // White keys
        ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        for i in 0 ..< nWhite {
            ctx.addPath(CGPath(roundedRect: CGRect(x: margin + CGFloat(i) * kW + 1.5,
                                                   y: kY,
                                                   width: kW - 3,
                                                   height: kH),
                               cornerWidth: kr, cornerHeight: kr, transform: nil))
            ctx.fillPath()
        }

        // Black keys: C# D# F# G# A# (positions 1,2,4,5,6 after white keys 0-6: C D E F G A B)
        let bW = kW * 0.60
        let bH = kH * 0.58
        let bY = kY + kH - bH
        ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 1))
        for pos in [1, 2, 4, 5, 6] {
            ctx.addPath(CGPath(roundedRect: CGRect(x: margin + CGFloat(pos) * kW - bW / 2,
                                                   y: bY,
                                                   width: bW,
                                                   height: bH),
                               cornerWidth: kr * 0.7, cornerHeight: kr * 0.7, transform: nil))
            ctx.fillPath()
        }

        // Blue accent bar below the keyboard
        ctx.setFillColor(CGColor(red: 0.18, green: 0.52, blue: 1.00, alpha: 0.90))
        ctx.fill(CGRect(x: margin, y: kY - s * 0.028, width: totalW, height: s * 0.018))

        // Small waveform dots above the keyboard
        let dotR  = s * 0.018
        let waveY = kY + kH + s * 0.055
        let wave: [(Double, Double)] = [
            (0.14, 0.00), (0.23, -0.04), (0.32, 0.04), (0.42, -0.03),
            (0.52, 0.03), (0.62, -0.04), (0.72, 0.04), (0.82,  0.00), (0.91, 0.00)
        ]
        ctx.setFillColor(CGColor(red: 0.18, green: 0.52, blue: 1.00, alpha: 0.55))
        for (xf, yf) in wave {
            ctx.fillEllipse(in: CGRect(x: s * xf - dotR,
                                       y: waveY + s * yf - dotR,
                                       width: dotR * 2, height: dotR * 2))
        }
        return true
    }
}

func writePNG(_ image: NSImage, to path: String) -> Bool {
    guard let tiff = image.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff),
          let png  = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

// Iconset spec: name → pixel size
let iconset = "Resources/AppIcon.iconset"
let specs: [(String, Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png",1024),
]

var ok = true
for (name, px) in specs {
    let path = "\(iconset)/\(name)"
    let result = writePNG(renderIcon(px: px), to: path)
    print(result ? "✓ \(name)" : "✗ \(name)")
    if !result { ok = false }
}

if ok {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", "--output", "Resources/AppIcon.icns", iconset]
    try? p.run(); p.waitUntilExit()
    print(p.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "✗ iconutil failed")
}
