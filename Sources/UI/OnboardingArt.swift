import AppKit

// MARK: - The mark

/// The logo's flower as a path (from Resources/Logos), drawn at any size and colour.
enum Mark {
    /// The flower in the logos' 325-point square.
    static let path: NSBezierPath = {
        let d = "M163 137.419C132.28 114.163 134.643 76.9535 163 63C191.357 76.9535 193.72 114.163 163 137.419C186.631 110.674 223.259 97.8837 244.527 110.674C272.884 125.791 265.794 156.023 242.164 174.628C230.348 185.093 212.625 187.419 194.902 185.093C217.351 195.558 226.803 217.651 217.351 233.93C201.991 245.558 185.449 230.442 180.723 215.326C183.086 242.07 174.815 256.023 163 263C151.185 256.023 142.914 242.07 145.277 215.326C140.551 230.442 124.009 245.558 108.649 233.93C99.1965 217.651 108.649 195.558 131.098 185.093C113.375 187.419 95.6519 185.093 83.8364 174.628C60.2055 156.023 53.1162 125.791 81.4733 110.674C102.741 97.8837 139.369 110.674 163 137.419Z"
        let path = NSBezierPath()
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,")
        var command = "M"
        func point() -> NSPoint? {
            guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { return nil }
            return NSPoint(x: x, y: 325 - y)
        }
        while !scanner.isAtEnd {
            if let letter = scanner.scanCharacters(from: CharacterSet(charactersIn: "MCZ")) { command = String(letter.last!) }
            switch command {
            case "M": if let p = point() { path.move(to: p) }
            case "C":
                guard let a = point(), let b = point(), let c = point() else { break }
                path.curve(to: c, controlPoint1: a, controlPoint2: b)
            default:
                path.close()
                _ = scanner.scanCharacters(from: CharacterSet(charactersIn: "Z"))
            }
        }
        return path
    }()

    /// The flower scaled to fill `rect` (keeping its own proportions inside the logo's square).
    static func path(in rect: NSRect) -> NSBezierPath {
        let copy = path.copy() as! NSBezierPath
        let bounds = copy.bounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var transform = AffineTransform(translationByX: rect.midX, byY: rect.midY)
        transform.scale(scale)
        transform.translate(x: -bounds.midX, y: -bounds.midY)
        copy.transform(using: transform)
        return copy
    }
}

// MARK: - The painting

/// The right half: an abstract painting in the step's colours, feathered into the black on its left, with the
/// step's motif on top.
final class ArtPanel: NSView {
    enum Scene: Equatable {
        case bloom, orbit, dock
        case source(BrowserSource)
        case preview(Space?)

        static func == (a: Scene, b: Scene) -> Bool {
            switch (a, b) {
            case (.bloom, .bloom), (.orbit, .orbit), (.dock, .dock): return true
            case let (.source(x), .source(y)): return x.id == y.id
            case (.preview, .preview): return true
            default: return false
            }
        }
    }

    private let canvas = CALayer()
    private let motif = MotifView()
    private var scene: Scene?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        canvas.contentsGravity = .resizeAspectFill
        canvas.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        canvas.frame = bounds
        layer?.addSublayer(canvas)
        let feather = CAGradientLayer()
        feather.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        feather.startPoint = CGPoint(x: 0, y: 0.5)
        feather.endPoint = CGPoint(x: 0.42, y: 0.5)
        feather.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        feather.frame = bounds
        layer?.addSublayer(feather)
        motif.frame = bounds
        motif.autoresizingMask = [.width, .height]
        addSubview(motif)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ next: Scene, animated: Bool) {
        let palette = Painting.palette(for: next)
        if scene == nil || Painting.palette(for: scene!) != palette {
            let image = Painting.image(palette: palette, size: bounds.size)
            if animated {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.6
                canvas.add(fade, forKey: "paint")
            }
            canvas.contents = image
        }
        scene = next
        motif.scene = next
        if animated {
            motif.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                motif.animator().alphaValue = 1
            }
        }
    }
}

/// Paintings made, not shipped: soft broad strokes in a few colours, blurred, then a dry-brush grain over them.
private enum Painting {
    struct Palette: Equatable {
        let ground: NSColor
        let strokes: [NSColor]
        let seed: UInt64
    }

    static func palette(for scene: ArtPanel.Scene) -> Palette {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch scene {
        case .bloom: return Palette(ground: rgb(0x120A1C), strokes: [rgb(0x5B2A86), rgb(0xA62BFF), rgb(0x2A1B4A), rgb(0xE07AB8), rgb(0x1C2C55)], seed: 7)
        case .orbit, .source: return Palette(ground: rgb(0x0B1614), strokes: [rgb(0x1F4D45), rgb(0x3E7F6E), rgb(0x16302B), rgb(0x8FB8A6), rgb(0x24423C)], seed: 19)
        case .preview: return Palette(ground: rgb(0x1A120E), strokes: [rgb(0x8C4A32), rgb(0xC9775A), rgb(0x3A2420), rgb(0xE8B49A), rgb(0x5A3A2E)], seed: 31)
        case .dock: return Palette(ground: rgb(0x16130A), strokes: [rgb(0x8A6A1E), rgb(0xE0B640), rgb(0x3B3220), rgb(0xF2DFA0), rgb(0x5C4B22)], seed: 43)
        }
    }

    private struct Random {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 33) / CGFloat(1 << 31)
        }
    }

    static func image(palette: Palette, size: NSSize) -> CGImage? {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(palette.ground.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var random = Random(state: palette.seed)
        context.setLineCap(.round)
        for index in 0..<64 {
            let color = palette.strokes[index % palette.strokes.count]
            context.setStrokeColor(color.withAlphaComponent(0.18 + random.next() * 0.45).cgColor)
            context.setLineWidth((24 + random.next() * 120) * scale)
            let start = CGPoint(x: random.next() * CGFloat(width), y: random.next() * CGFloat(height))
            let angle = random.next() * .pi * 2
            let length = (120 + random.next() * 380) * scale
            let end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            let bend = CGPoint(x: (start.x + end.x) / 2 + (random.next() - 0.5) * length, y: (start.y + end.y) / 2 + (random.next() - 0.5) * length)
            context.move(to: start)
            context.addQuadCurve(to: end, control: bend)
            context.strokePath()
        }
        guard let strokes = context.makeImage() else { return nil }
        let base = CIImage(cgImage: strokes)
        let soft = base.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: base.extent)
        // Bristle marks: fine noise smeared a little along a slant, barely laid over the paint.
        let bristles = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 9, kCIInputAngleKey: 0.6 + Double(palette.seed % 5) * 0.5])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.3, kCIInputBrightnessKey: -0.1])
            .cropped(to: base.extent)
        let painted = bristles.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: soft])
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: soft, "inputTime": 0.72])
        // Canvas: a coarse, soft tooth under everything.
        let tooth = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 3, y: 3))
            .applyingGaussianBlur(sigma: 1.2)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputBrightnessKey: -0.35])
            .cropped(to: base.extent)
        let finished = tooth.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: painted])
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: painted, "inputTime": 0.8])
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.9, kCIInputRadiusKey: 2.2])
        return CIContext().createCGImage(finished, from: base.extent)
    }
}

/// What sits on the painting: the flower, the things an import brings, the browser in its new look, the Dock.
private final class MotifView: NSView {
    var scene: ArtPanel.Scene? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let scene else { return }
        let center = NSPoint(x: bounds.midX + 40, y: bounds.midY)
        switch scene {
        case .bloom:
            drawFlower(in: NSRect(x: center.x - 110, y: center.y - 110, width: 220, height: 220), color: .white, glow: 0.35)
        case .orbit:
            for radius: CGFloat in [96, 140, 186] {
                NSColor.white.withAlphaComponent(0.09).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                ring.lineWidth = 1
                ring.stroke()
            }
            drawFlower(in: NSRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124), color: .white, glow: 0.3)
            let badges: [(String, CGFloat, CGFloat, CGFloat)] = [("key.fill", 140, 128, 30), ("bookmark.fill", 186, 38, 38),
                                                                  ("clock.fill", 140, -12, 22), ("puzzlepiece.extension.fill", 186, 200, 28),
                                                                  ("folder.fill", 186, 285, 34)]
            for (symbol, radius, degrees, size) in badges {
                let angle = degrees * .pi / 180
                drawBadge(symbol, at: NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius), size: size)
            }
        case let .source(source):
            let image = source.iconPath.flatMap { NSImage(contentsOfFile: $0) } ?? source.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            for index in 0..<5 {
                NSColor.white.withAlphaComponent(0.2 + CGFloat(index) * 0.16).setFill()
                let size: CGFloat = 5 + CGFloat(index)
                NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y + 160 - CGFloat(index) * 28, width: size, height: size)).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            image?.draw(in: NSRect(x: center.x - 90, y: center.y - 150, width: 180, height: 180))
            NSGraphicsContext.restoreGraphicsState()
        case let .preview(space):
            drawBrowser(in: NSRect(x: center.x - 190, y: center.y - 120, width: 380, height: 240), space: space)
        case .dock:
            let strip = NSRect(x: center.x - 170, y: center.y - 70, width: 340, height: 120)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: strip, xRadius: 30, yRadius: 30).fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            NSBezierPath(roundedRect: strip.insetBy(dx: 0.5, dy: 0.5), xRadius: 30, yRadius: 30).stroke()
            for (index, x) in [-118, 118].enumerated() {
                NSColor.white.withAlphaComponent(0.1 + CGFloat(index) * 0.04).setFill()
                NSBezierPath(roundedRect: NSRect(x: center.x + CGFloat(x) - 40, y: center.y - 50, width: 80, height: 80), xRadius: 18, yRadius: 18).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            IconChoice.image(IconChoice.current)?.draw(in: NSRect(x: center.x - 74, y: center.y - 58, width: 148, height: 148))
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 66, width: 6, height: 6)).fill()
        }
    }

    private func drawFlower(in rect: NSRect, color: NSColor, glow: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(glow)
        shadow.shadowBlurRadius = 60
        shadow.set()
        color.withAlphaComponent(0.94).setFill()
        Mark.path(in: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBadge(_ symbol: String, at point: NSPoint, size: CGFloat) {
        let rect = NSRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.72, weight: .semibold).applying(.init(paletteColors: [NSColor(white: 0.75, alpha: 1)])))
        else { return }
        let glyph = image.size
        image.draw(in: NSRect(x: point.x - glyph.width / 2, y: point.y - glyph.height / 2, width: glyph.width, height: glyph.height))
    }

    private func drawBrowser(in rect: NSRect, space: Space?) {
        let dark: Bool = {
            switch space?.appearance ?? .system {
            case .dark: return true
            case .light: return false
            case .system: return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            }
        }()
        let tint = NSColor(hex: space?.colorHex ?? SpaceStyle.palette[0])
        let shape = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 34
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        tint.withAlphaComponent(0.3).setFill()
        rect.fill(using: .sourceOver)
        let ink: NSColor = dark ? .white : .black
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 14 + CGFloat(index) * 13, y: rect.maxY - 20, width: 8, height: 8)).fill()
        }
        for index in 0..<6 {
            let y = rect.maxY - 54 - CGFloat(index) * 24
            if index == 1 {
                (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.85)).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 8, y: y - 9, width: 100, height: 20), xRadius: 6, yRadius: 6).fill()
            }
            ink.withAlphaComponent(index == 1 ? 0.55 : 0.28).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 18, y: y - 2, width: [62, 48, 70, 40, 56, 50][index], height: 4), xRadius: 2, yRadius: 2).fill()
        }
        let page = NSRect(x: rect.minX + 118, y: rect.minY + 8, width: rect.width - 126, height: rect.height - 16)
        (dark ? NSColor(white: 0.09, alpha: 1) : .white).setFill()
        NSBezierPath(roundedRect: page, xRadius: 9, yRadius: 9).fill()
        ink.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + 18, y: page.maxY - 32, width: 110, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
        for (index, fraction) in [0.84, 0.7, 0.9, 0.6, 0.78].enumerated() {
            ink.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: page.minX + 18, y: page.maxY - 56 - CGFloat(index) * 16, width: (page.width - 36) * fraction, height: 5),
                         xRadius: 2.5, yRadius: 2.5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class Splash: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let mark = NSRect(x: bounds.midX - 36, y: bounds.midY + 40, width: 72, height: 72)
        NSColor(srgbRed: 0.65, green: 0.17, blue: 1, alpha: 1).setFill()
        Mark.path(in: mark).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: L("onboarding.splash"), attributes: [
            .font: NSFont.serif(44, .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: paragraph,
        ])
        let rect = text.boundingRect(with: NSSize(width: bounds.width - 160, height: 400), options: [.usesLineFragmentOrigin])
        text.draw(with: NSRect(x: 80, y: bounds.midY - 20 - rect.height, width: bounds.width - 160, height: rect.height), options: [.usesLineFragmentOrigin])
    }
}
