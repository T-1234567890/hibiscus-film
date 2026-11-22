import CoreImage
import CoreText
import Foundation

nonisolated enum FilmFrame {
    struct StockMark: Sendable {
        let name: String
        let swatch: AccentRGB?
    }

    struct Layout {
        let photo: CGRect
        let canvas: CGRect
        let railHeight: CGFloat
        let labelBandHeight: CGFloat
        let gateGap: CGFloat
        let holeSize: CGSize
        let isHPan: Bool
        let perforations: Int

        init(width: Int, height: Int, isHPan: Bool) {
            let short = CGFloat(min(width, height))
            let aspect = CGFloat(width) / CGFloat(height)
            let halfFrame = !isHPan && aspect < 0.70
            let side = max(2, (short * (isHPan ? 0.017 : halfFrame ? 0.020 : 0.022)).rounded())
            let count = isHPan ? 14 : halfFrame ? 5 : aspect > 1.10 ? 8 : 6
            let pitch = CGFloat(width) / CGFloat(count)
            let holeWidth = min(pitch * 0.43, short * 0.086)
            let holeHeight = holeWidth * 1.40
            let gap = max(2, (short * 0.023).rounded())
            let rail = ceil(gap + holeHeight + max(8, holeHeight * 0.64))

            self.isHPan = isHPan
            perforations = count
            holeSize = CGSize(width: holeWidth, height: holeHeight)
            gateGap = gap
            railHeight = rail
            labelBandHeight = rail - gap - holeHeight
            photo = CGRect(x: side, y: rail, width: CGFloat(width), height: CGFloat(height))
            canvas = CGRect(x: 0, y: 0, width: photo.maxX + side, height: photo.maxY + rail)
        }

        func perforation(at index: Int, lower: Bool) -> CGRect {
            let pitch = photo.width / CGFloat(perforations)
            let x = photo.minX + (CGFloat(index) + 0.5) * pitch - holeSize.width / 2
            return CGRect(origin: CGPoint(x: x, y: lower ? labelBandHeight : gateGap), size: holeSize)
        }
    }

    private static let base = AccentRGB(red: 0.062, green: 0.061, blue: 0.070)
    private static let stockNeutral = AccentRGB(red: 0.69, green: 0.56, blue: 0.45)
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let fontResources = Bundle.main.url(forResource: "FilmFrameFonts", withExtension: "bundle")
    private static let typography = fontResources.flatMap(Typography.init)
    private static let symbolLigatures = CTFontDescriptorCreateWithAttributes([
        kCTFontFeatureSettingsAttribute as String: [
            [kCTFontOpenTypeFeatureTag as String: "calt", kCTFontOpenTypeFeatureValue as String: 1]
        ]
    ] as CFDictionary)

    private struct Typography {
        let stock: CGFont
        let mark: CGFont
        let decimal: CGFont
        let symbol: CGFont

        init?(folder: URL) {
            func load(_ name: String) -> CGFont? {
                let file = folder.appendingPathComponent(name).appendingPathExtension("ttf")
                guard let provider = CGDataProvider(url: file as CFURL) else { return nil }
                return CGFont(provider)
            }
            guard let stock = load("Inter-Bold"), let mark = load("Inter-Medium"),
                  let decimal = load("Inter-ThinItalic"), let symbol = load("JetBrainsMono-Regular") else { return nil }
            self.stock = stock
            self.mark = mark
            self.decimal = decimal
            self.symbol = symbol
        }
    }

    /// Keeps the photo at its original pixel size. The upper and lower rails
    /// are the only parts rasterized separately before Core Image composites them.
    static func compose(_ photo: CGImage, stock: StockMark, isHPan: Bool, recipeAccent: AccentRGB?) -> CIImage? {
        guard let typography else { return nil }
        let layout = Layout(width: photo.width, height: photo.height, isHPan: isHPan)
        let accent = palette(recipeAccent: recipeAccent, imageAccent: extractAccent(from: photo), stockAccent: stock.swatch)
        guard let upper = rail(width: layout.canvas.width, height: layout.railHeight, draw: {
            drawPerforations(in: $0, layout: layout, lower: false)
            drawUpperMarks(in: $0, layout: layout, accent: accent)
        }), let lower = rail(width: layout.canvas.width, height: layout.railHeight, draw: {
            drawPerforations(in: $0, layout: layout, lower: true)
            drawEdgePrint(in: $0, layout: layout, stockName: stock.name, accent: accent, typography: typography)
        }) else { return nil }

        let backing = solid(base, in: layout.canvas)
        let translatedUpper = CIImage(cgImage: upper)
            .transformed(by: CGAffineTransform(translationX: 0, y: layout.photo.maxY))
        let translatedPhoto = CIImage(cgImage: photo)
            .transformed(by: CGAffineTransform(translationX: layout.photo.minX, y: layout.photo.minY))
        return translatedPhoto.composited(over:
            translatedUpper.composited(over: CIImage(cgImage: lower).composited(over: backing))
        ).cropped(to: layout.canvas)
    }

    static func palette(recipeAccent: AccentRGB?, imageAccent: AccentRGB?, stockAccent: AccentRGB?) -> AccentRGB {
        let selected = [recipeAccent, imageAccent].compactMap { $0 }.first(where: acceptsAccent) ?? stockAccent ?? stockNeutral
        let hsv = AccentAnalyzer.rgbToHSB(red: selected.red, green: selected.green, blue: selected.blue)
        let hue = hsv.saturation > 0.015 ? hsv.hue : 0.10
        var saturation = min(0.52, max(0.23, hsv.saturation * 0.70))
        var value = min(0.95, max(0.80, hsv.brightness))
        var ink = rgb(hue: hue, saturation: saturation, value: value)
        // The same fill works as colored type against graphite and behind dark type in the HPan mark.
        while contrast(ink, base) < 5.5, saturation > 0.1 {
            saturation -= 0.03
            value = min(0.98, value + 0.03)
            ink = rgb(hue: hue, saturation: saturation, value: value)
        }
        return ink
    }

    static func acceptsAccent(_ rgb: AccentRGB) -> Bool {
        let hsv = AccentAnalyzer.rgbToHSB(red: rgb.red, green: rgb.green, blue: rgb.blue)
        return hsv.saturation >= 0.14 && hsv.brightness >= 0.26 && contrast(rgb, base) >= 1.6
    }

    static func contrast(_ a: AccentRGB, _ b: AccentRGB) -> Double {
        func luminance(_ rgb: AccentRGB) -> Double {
            func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
        }
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func extractAccent(from photo: CGImage) -> AccentRGB? {
        let scale = 80.0 / Double(max(photo.width, photo.height))
        let width = max(1, Int((Double(photo.width) * scale).rounded()))
        let height = max(1, Int((Double(photo.height) * scale).rounded()))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(photo, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return SceneAccentAnalyzer.dominantColor(data, width: width, height: height, faceRects: [])
    }

    private static func drawPerforations(in context: CGContext, layout: Layout, lower: Bool) {
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        for index in 0..<layout.perforations {
            let hole = layout.perforation(at: index, lower: lower)
            fill(hole, radius: hole.width * 0.26, color: white, in: context)
        }
    }

    private static func drawUpperMarks(in context: CGContext, layout: Layout, accent: AccentRGB) {
        let left = layout.perforation(at: 0, lower: false).minX
        let right = layout.perforation(at: layout.perforations - 1, lower: false).maxX
        let pitch = layout.photo.width / CGFloat(layout.perforations)
        let unit = min(pitch / 6, layout.labelBandHeight * 0.36)
        let height = layout.labelBandHeight * 0.28
        let y = layout.railHeight - (layout.labelBandHeight + height) / 2
        let marks = [
            CGRect(x: left, y: y, width: unit * 3, height: height),
            CGRect(x: left + unit * 4, y: y, width: unit, height: height),
            CGRect(x: left + unit * 6, y: y, width: unit, height: height)
        ]
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: left + right, ty: 0)
        context.setFillColor(cgColor(accent))
        context.fill(marks + marks.map { $0.applying(mirror) })
    }

    private static func drawEdgePrint(in context: CGContext, layout: Layout, stockName: String,
                                      accent: AccentRGB, typography: Typography) {
        let left = layout.perforation(at: 0, lower: true).minX
        let right = layout.canvas.width - left
        let height = layout.labelBandHeight
        let typeSize = min(height * 0.72, layout.photo.width / (layout.isHPan ? 30 : 22))
        let tabX = right - typeSize * 5.9
        let indexEnd = layout.isHPan ? tabX - typeSize * 0.65 : right
        let index = CGRect(x: indexEnd - typeSize * 2.15, y: 0, width: typeSize * 2.15, height: height)
        let ink = cgColor(accent)
        let stock = stockRun(stockName, typeSize: typeSize, ink: ink, typography: typography)
        draw([stock], x: left, y: height / 2, width: index.minX - typeSize * 0.6 - left, in: context)
        drawEdgeIndex(in: context, region: index, typeSize: typeSize * 0.59, ink: ink, typography: typography)

        if layout.isHPan {
            let tab = CGRect(x: tabX, y: 0, width: layout.canvas.maxX - tabX, height: height * 0.78)
            drawHPanTab(in: context, tab: tab, typeSize: typeSize, ink: ink, typography: typography)
        }
    }

    private static func stockRun(_ name: String, typeSize: CGFloat, ink: CGColor, typography: Typography) -> NSAttributedString {
        let uppercased = name.uppercased()
        let face = CTFontCreateWithGraphicsFont(typography.stock, typeSize, nil, nil)
        let symbol = CTFontCreateWithGraphicsFont(typography.symbol, typeSize, nil, nil)
        let attributed = NSMutableAttributedString(attributedString: run(uppercased, font: face, color: ink))
        for (offset, codeUnit) in uppercased.utf16.enumerated() where codeUnit == 0x002D {
            attributed.addAttribute(.init(kCTFontAttributeName as String), value: symbol,
                                    range: NSRange(location: offset, length: 1))
        }
        return attributed
    }

    private static func drawEdgeIndex(in context: CGContext, region: CGRect, typeSize: CGFloat,
                                      ink: CGColor, typography: Typography) {
        let barWidth = typeSize * 0.12
        let barHeight = region.height * 0.27
        let bar = CGRect(x: region.minX, y: region.midY - barHeight / 2, width: barWidth, height: barHeight)
        let barSpacing = barWidth * 2.4
        context.setFillColor(ink)
        context.fill([bar, bar.offsetBy(dx: barSpacing, dy: 0)])

        let labelX = bar.maxX + barSpacing + typeSize * 0.34
        let face = CTFontCreateWithGraphicsFont(typography.mark, typeSize, nil, nil)
        let symbol = CTFontCreateWithGraphicsFont(typography.symbol, typeSize, nil, symbolLigatures)
        draw([run("1A ", font: face, color: ink), run("->", font: symbol, color: ink)],
             x: labelX, y: region.midY, width: region.maxX - labelX, in: context)
    }

    private static func drawHPanTab(in context: CGContext, tab: CGRect, typeSize: CGFloat,
                                    ink: CGColor, typography: Typography) {
        let radius = tab.height * 0.16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: tab.minX, y: tab.minY))
        path.addLine(to: CGPoint(x: tab.minX, y: tab.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: tab.minX + radius, y: tab.maxY), control: CGPoint(x: tab.minX, y: tab.maxY))
        path.addLine(to: CGPoint(x: tab.maxX, y: tab.maxY))
        path.addLine(to: CGPoint(x: tab.maxX, y: tab.minY))
        path.closeSubpath()
        context.setFillColor(ink)
        context.addPath(path)
        context.fillPath()

        let face = CTFontCreateWithGraphicsFont(typography.mark, typeSize * 0.82, nil, nil)
        let decimal = CTFontCreateWithGraphicsFont(typography.decimal, typeSize * 0.82, nil, nil)
        let graphite = cgColor(base)
        draw([run("HPan ", font: face, color: graphite), run("0.5", font: decimal, color: graphite)],
             x: tab.minX + typeSize * 0.5, y: tab.midY, width: tab.width - typeSize, centered: true, in: context)
    }

    private static func rail(width: CGFloat, height: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(cgColor(base))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()
    }

    private static func run(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
    }

    private static func draw(_ runs: [NSAttributedString], x: CGFloat, y: CGFloat, width: CGFloat,
                             centered: Bool = false, in context: CGContext) {
        guard width > 0 else { return }
        let attributed = NSMutableAttributedString(string: "")
        runs.forEach(attributed.append)
        let line = CTLineCreateWithAttributedString(attributed)
        let measured = CTLineGetTypographicBounds(line, nil, nil, nil)
        let scale = min(1, width / max(1, measured))
        let floorScale = max(0.76, scale)
        let displayed: CTLine
        if scale < floorScale, let last = runs.last, last.length > 0,
           let shortened = CTLineCreateTruncatedLine(line, width / floorScale, .end,
             CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: last.attributes(at: 0, effectiveRange: nil)))) {
            displayed = shortened
        } else {
            displayed = line
        }
        let resolvedScale = displayed === line ? scale : floorScale
        let box = CTLineGetBoundsWithOptions(displayed, .useGlyphPathBounds)
        let offset = centered ? (width - CTLineGetTypographicBounds(displayed, nil, nil, nil) * resolvedScale) / 2 : 0
        context.saveGState()
        context.translateBy(x: x + offset, y: y - box.midY * resolvedScale)
        context.scaleBy(x: resolvedScale, y: resolvedScale)
        context.textPosition = .zero
        CTLineDraw(displayed, context)
        context.restoreGState()
    }

    private static func fill(_ rect: CGRect, radius: CGFloat, color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private static func solid(_ rgb: AccentRGB, in rect: CGRect) -> CIImage {
        CIImage(color: CIColor(cgColor: cgColor(rgb))).cropped(to: rect)
    }

    private static func cgColor(_ rgb: AccentRGB) -> CGColor {
        CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    private static func rgb(hue: Double, saturation: Double, value: Double) -> AccentRGB {
        func channel(_ offset: Double) -> Double {
            let k = (offset + hue * 6).truncatingRemainder(dividingBy: 6)
            return value * (1 - saturation * max(0, min(k, 4 - k, 1)))
        }
        return AccentRGB(red: channel(5), green: channel(3), blue: channel(1))
    }
}
