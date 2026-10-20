// Draws the PocketMac icon (iOS 1024 px + macOS .iconset). Run: swift tools/make-icons.swift
import AppKit

func draw(size: CGFloat, macStyle: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let full = NSRect(x: 0, y: 0, width: size, height: size)
    // macOS icons sit inside a margin with rounded corners; iOS icons are full-bleed squares.
    let rect = macStyle ? full.insetBy(dx: size * 0.098, dy: size * 0.098) : full
    let path = macStyle ? NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
                        : NSBezierPath(rect: rect)
    if macStyle {
        let sh = NSShadow(); sh.shadowBlurRadius = size * 0.02; sh.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.set()
    }
    let grad = NSGradient(colors: [NSColor(red: 0.10, green: 0.12, blue: 0.32, alpha: 1),
                                   NSColor(red: 0.20, green: 0.33, blue: 0.85, alpha: 1),
                                   NSColor(red: 0.12, green: 0.72, blue: 0.86, alpha: 1)])!
    path.addClip()
    grad.draw(in: rect, angle: 60)
    // soft glow
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.25), NSColor.white.withAlphaComponent(0)])!
    glow.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: -rect.width * 0.2, dy: rect.height * 0.25).offsetBy(dx: 0, dy: rect.height * 0.35)),
              relativeCenterPosition: NSPoint(x: 0, y: 0))
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "macbook.and.iphone", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        let r = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 - rect.height * 0.02, width: s.width, height: s.height)
        sym.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let root = FileManager.default.currentDirectoryPath
let iosDir = root + "/iOS/PocketMac/Assets.xcassets/AppIcon.appiconset"
try! FileManager.default.createDirectory(atPath: iosDir, withIntermediateDirectories: true)
// iOS: opaque (no alpha channel) 1024 icon
let ios = draw(size: 1024, macStyle: false).cgImage!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(ios, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
save(NSBitmapImageRep(cgImage: ctx.makeImage()!), iosDir + "/icon-1024.png")

let iconset = root + "/build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    save(draw(size: CGFloat(base), macStyle: true), "\(iconset)/icon_\(base)x\(base).png")
    save(draw(size: CGFloat(base * 2), macStyle: true), "\(iconset)/icon_\(base)x\(base)@2x.png")
}
print("icons written")
