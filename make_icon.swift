import AppKit
import CoreGraphics

// Programmatic icon generator for Vyora.
// Modern macOS-style: deep gradient squircle with a glowing luminous orb.
// Run: swift make_icon.swift && iconutil -c icns Vyora.iconset -o Vyora.icns

// MARK: - Drawing

func drawIcon(ctx: CGContext, size S: CGFloat) {
    ctx.saveGState()

    // Outer squircle background.
    let inset = S * 0.055
    let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let radius = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow under the squircle.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.014),
                  blur: S * 0.045,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(squircle)
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep navy → indigo → violet diagonal gradient.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let cs = CGColorSpaceCreateDeviceRGB()
    let bgColors: CFArray = [
        NSColor(srgbRed: 0.05, green: 0.07, blue: 0.18, alpha: 1).cgColor,
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.32, alpha: 1).cgColor,
        NSColor(srgbRed: 0.22, green: 0.13, blue: 0.42, alpha: 1).cgColor,
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end:   CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

    // Subtle radial vignette toward the corners.
    let vignette = CGGradient(colorsSpace: cs, colors: [
        NSColor.black.withAlphaComponent(0.0).cgColor,
        NSColor.black.withAlphaComponent(0.45).cgColor,
    ] as CFArray, locations: [0.55, 1.0])!
    ctx.drawRadialGradient(vignette,
                           startCenter: CGPoint(x: rect.midX, y: rect.midY),
                           startRadius: 0,
                           endCenter:   CGPoint(x: rect.midX, y: rect.midY),
                           endRadius:   rect.width * 0.75,
                           options: [])

    // Outer halo / glow around the orb.
    let center = CGPoint(x: rect.midX, y: rect.midY - S * 0.005)
    let haloR  = rect.width * 0.46
    let halo = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 1.00, green: 0.95, blue: 0.78, alpha: 0.55).cgColor,
        NSColor(srgbRed: 1.00, green: 0.85, blue: 0.55, alpha: 0.20).cgColor,
        NSColor(srgbRed: 0.90, green: 0.55, blue: 0.95, alpha: 0.00).cgColor,
    ] as CFArray, locations: [0.0, 0.45, 1.0])!
    ctx.drawRadialGradient(halo,
                           startCenter: center, startRadius: 0,
                           endCenter:   center, endRadius: haloR,
                           options: [])

    // Long thin light rays (subtle).
    ctx.saveGState()
    let rayLen = rect.width * 0.42
    let rayCount = 12
    for i in 0..<rayCount {
        let angle = CGFloat(i) * (.pi * 2 / CGFloat(rayCount))
        let x = center.x + cos(angle) * rayLen
        let y = center.y + sin(angle) * rayLen
        let g = CGGradient(colorsSpace: cs, colors: [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0.00).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g,
                               start: center,
                               end:   CGPoint(x: x, y: y),
                               options: [])
    }
    ctx.restoreGState()

    // The luminous orb itself: cream → warm white → bright core.
    let orbR = rect.width * 0.155
    let orbRect = CGRect(x: center.x - orbR, y: center.y - orbR,
                         width: orbR * 2, height: orbR * 2)

    ctx.saveGState()
    ctx.addEllipse(in: orbRect)
    ctx.clip()

    let orbGrad = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 1.00, green: 0.97, blue: 0.85, alpha: 1).cgColor,
        NSColor(srgbRed: 1.00, green: 0.85, blue: 0.55, alpha: 1).cgColor,
    ] as CFArray, locations: [0.0, 0.55, 1.0])!
    ctx.drawRadialGradient(orbGrad,
                           startCenter: CGPoint(x: center.x - orbR * 0.25,
                                                y: center.y + orbR * 0.25),
                           startRadius: 0,
                           endCenter: center,
                           endRadius: orbR,
                           options: [])
    ctx.restoreGState()

    // A thin bright outer ring around the orb (camera aperture vibe).
    ctx.saveGState()
    let ringRect = orbRect.insetBy(dx: -orbR * 0.18, dy: -orbR * 0.18)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(S * 0.005)
    ctx.strokeEllipse(in: ringRect)
    ctx.restoreGState()

    // Highlight specular dot on the orb.
    ctx.saveGState()
    let highlight = CGRect(x: center.x - orbR * 0.55,
                           y: center.y + orbR * 0.20,
                           width: orbR * 0.55,
                           height: orbR * 0.30)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.addEllipse(in: highlight)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState() // unclip squircle

    // Top inner highlight on the squircle (glassy edge).
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let topEdge = CGGradient(colorsSpace: cs, colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0.00).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(topEdge,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end:   CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.30),
                           options: [])
    ctx.restoreGState()

    // Hairline outline on the squircle for definition.
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(S * 0.0035)
    ctx.addPath(squircle)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
}

// MARK: - Output

func renderPNG(size: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil,
                        width: size, height: size,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(ctx: ctx, size: CGFloat(size))
    let cg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])!
}

let mapping: [(String, Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

let dir = "Vyora.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

for (name, px) in mapping {
    let data = renderPNG(size: px)
    try! data.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    print("wrote \(name) (\(px)px, \(data.count) bytes)")
}

// App Store Connect requires a 1024x1024 PNG with NO alpha channel.
func renderOpaqueIcon(size: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil,
                        width: size, height: size,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Fill with black first (opaque background behind the squircle shadow).
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    drawIcon(ctx: ctx, size: CGFloat(size))
    let cg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])!
}

let storeIcon = renderOpaqueIcon(size: 1024)
try! storeIcon.write(to: URL(fileURLWithPath: "AppStoreIcon.png"))
print("wrote AppStoreIcon.png (1024px, no alpha, \(storeIcon.count) bytes)")

print("Done. Now run: iconutil -c icns \(dir) -o Vyora.icns")
