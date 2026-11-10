import AppKit

/// A made-up Mac desktop that the test host streams when `POCKETMAC_TEST_PATTERN=desktop`.
/// Used for screenshots and demos, so they never show anybody's real screen.
enum DemoDesktop {
    /// The still part of the picture (everything except the pointer), drawn once.
    static func background(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        // All sizes are for a 1920 × 1200 picture; scale for anything else.
        ctx.scaleBy(x: CGFloat(width) / 1920, y: CGFloat(height) / 1200)
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// The pointer, with its tip at `tip` (y grows upwards, like the rest of the picture).
    static func drawPointer(_ ctx: CGContext, tip: CGPoint, scale: CGFloat) {
        let shape: [CGPoint] = [(0, 0), (0, -36), (9, -27), (16, -42), (22, -39), (15, -25), (27, -25)]
            .map { CGPoint(x: tip.x + $0.0 * scale, y: tip.y + $0.1 * scale) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 6 * scale, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addLines(between: shape); ctx.closePath()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(3 * scale); ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    // MARK: Drawing (1920 × 1200, origin bottom-left)

    private static func draw(_ ctx: CGContext) {
        let W: CGFloat = 1920, H: CGFloat = 1200

        // Wallpaper: a soft diagonal gradient with two glows.
        let wall = gradient([0x1E1B4B, 0x5B21B6, 0xC026D3, 0xF59E0B], [0, 0.45, 0.78, 1])
        ctx.drawLinearGradient(wall, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
        for (c, r, color) in [(CGPoint(x: 1500, y: 950), 520.0, 0x22D3EE), (CGPoint(x: 300, y: 150), 480.0, 0xF472B6)] {
            let g = CGGradient(colorsSpace: nil, colors: [rgb(color, 0.35), rgb(color, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }

        // Menu bar
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.2))
        ctx.fill(CGRect(x: 0, y: H - 50, width: W, height: 50))
        var x: CGFloat = 30
        x += text("PocketMac", 26, .bold, .white, at: CGPoint(x: x, y: H - 37)) + 40
        for item in ["File", "Edit", "View", "Go", "Window", "Help"] {
            x += text(item, 26, .regular, .white, at: CGPoint(x: x, y: H - 37)) + 34
        }
        text("82 %     Wed 9:41", 26, .medium, .white, at: CGPoint(x: W - 30, y: H - 37), alignRight: true)

        // Main window: "Welcome to PocketMac"
        let win = CGRect(x: 160, y: 250, width: 1020, height: 720)
        roundedCard(ctx, win, radius: 22, fill: CGColor(gray: 0.985, alpha: 1), shadow: 0.45)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: win, cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.clip()
        ctx.setFillColor(CGColor(gray: 0.925, alpha: 1))
        ctx.fill(CGRect(x: win.minX, y: win.maxY - 64, width: win.width, height: 64))
        ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
        ctx.fill(CGRect(x: win.minX, y: win.maxY - 65, width: win.width, height: 1))
        ctx.restoreGState()
        for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(rgb(color))
            ctx.fillEllipse(in: CGRect(x: win.minX + 22 + CGFloat(i) * 34, y: win.maxY - 44, width: 24, height: 24))
        }
        text("Welcome to PocketMac", 24, .semibold, NSColor(white: 0.25, alpha: 1),
             at: CGPoint(x: win.midX, y: win.maxY - 42), center: true)

        let left = win.minX + 60
        text("Hi! This Mac is in your pocket.", 48, .bold, NSColor(white: 0.08, alpha: 1), at: CGPoint(x: left, y: win.maxY - 150))
        text("Everything here is live on your phone.", 29, .regular, NSColor(white: 0.4, alpha: 1), at: CGPoint(x: left, y: win.maxY - 200))
        let rows: [(String, Int, String)] = [
            ("☝️", 0x3B82F6, "Slide one finger to move the pointer, tap to click"),
            ("✌️", 0x10B981, "Two fingers to scroll, pinch to zoom in"),
            ("⌨️", 0xF59E0B, "Three-finger tap opens the keyboard"),
            ("🔒", 0x8B5CF6, "Encrypted from your phone straight to this Mac"),
            ("💻", 0xEC4899, "Keeps working with the lid closed"),
        ]
        for (i, row) in rows.enumerated() {
            let y = win.maxY - 300 - CGFloat(i) * 82
            ctx.setFillColor(rgb(row.1, 0.16))
            ctx.fillEllipse(in: CGRect(x: left, y: y - 12, width: 58, height: 58))
            text(row.0, 34, .regular, .black, at: CGPoint(x: left + 29, y: y - 1), center: true)
            text(row.2, 30, .regular, NSColor(white: 0.15, alpha: 1), at: CGPoint(x: left + 84, y: y + 4))
        }

        // Widgets on the right: Mac battery and a clock.
        let bat = CGRect(x: 1250, y: 600, width: 500, height: 370)
        roundedCard(ctx, bat, radius: 30, fill: CGColor(gray: 0.05, alpha: 0.42), shadow: 0.25)
        text("MacBook Air", 30, .semibold, .white, at: CGPoint(x: bat.minX + 40, y: bat.maxY - 70))
        text("82%", 110, .bold, .white, at: CGPoint(x: bat.minX + 34, y: bat.maxY - 205))
        text("Battery · charging", 27, .regular, NSColor(white: 1, alpha: 0.75), at: CGPoint(x: bat.minX + 40, y: bat.maxY - 252))
        let bar = CGRect(x: bat.minX + 40, y: bat.minY + 70, width: bat.width - 80, height: 18)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.2))
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.fillPath()
        ctx.setFillColor(rgb(0x34D399))
        ctx.addPath(CGPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * 0.82, height: bar.height),
                           cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.fillPath()
        ctx.setFillColor(rgb(0x34D399))
        ctx.fillEllipse(in: CGRect(x: bat.minX + 40, y: bat.minY + 28, width: 14, height: 14))
        text("Phone connected", 24, .medium, NSColor(white: 1, alpha: 0.85), at: CGPoint(x: bat.minX + 64, y: bat.minY + 25))

        let clock = CGRect(x: 1250, y: 250, width: 500, height: 310)
        roundedCard(ctx, clock, radius: 30, fill: CGColor(gray: 1, alpha: 0.16), shadow: 0.2)
        text("9:41", 150, .light, .white, at: CGPoint(x: clock.midX, y: clock.minY + 110), center: true)
        text("Wednesday", 30, .medium, NSColor(white: 1, alpha: 0.85), at: CGPoint(x: clock.midX, y: clock.minY + 55), center: true)

        // Dock
        let icons: [(String, Int, Int)] = [
            ("🧭", 0x38BDF8, 0x2563EB), ("📁", 0x93C5FD, 0x3B82F6), ("✉️", 0x7DD3FC, 0x0284C7),
            ("🗒️", 0xFDE68A, 0xF59E0B), ("🎵", 0xFDA4AF, 0xE11D48), ("📷", 0xD1D5DB, 0x6B7280),
            ("🗓️", 0xFFFFFF, 0xE5E7EB), ("💬", 0x86EFAC, 0x16A34A), ("⚙️", 0xCBD5E1, 0x64748B),
        ]
        let size: CGFloat = 92, gap: CGFloat = 20
        let dockW = CGFloat(icons.count) * (size + gap) + gap
        let dock = CGRect(x: (W - dockW) / 2, y: 16, width: dockW, height: size + 2 * gap)
        roundedCard(ctx, dock, radius: 34, fill: CGColor(gray: 1, alpha: 0.24), shadow: 0.2)
        for (i, icon) in icons.enumerated() {
            let r = CGRect(x: dock.minX + gap + CGFloat(i) * (size + gap), y: dock.minY + gap, width: size, height: size)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.clip()
            ctx.drawLinearGradient(gradient([icon.1, icon.2], [0, 1]), start: CGPoint(x: r.midX, y: r.maxY),
                                   end: CGPoint(x: r.midX, y: r.minY), options: [])
            ctx.restoreGState()
            text(icon.0, 52, .regular, .black, at: CGPoint(x: r.midX, y: r.midY - 20), center: true)
        }
    }

    // MARK: Helpers

    private static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func gradient(_ hexes: [Int], _ stops: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: hexes.map { rgb($0) } as CFArray, locations: stops)!
    }

    private static func roundedCard(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, fill: CGColor, shadow: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: CGColor(gray: 0, alpha: shadow))
        ctx.setFillColor(fill)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Draws one line of text with its baseline at `at`; returns its width.
    @discardableResult
    private static func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: CGPoint,
                             center: Bool = false, alignRight: Bool = false) -> CGFloat {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                             .foregroundColor: color])
        let w = str.size().width
        let x = center ? p.x - w / 2 : alignRight ? p.x - w : p.x
        str.draw(at: CGPoint(x: x, y: p.y))
        return w
    }
}
