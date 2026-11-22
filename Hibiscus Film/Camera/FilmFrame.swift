import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

nonisolated enum FilmFrame {
    struct StockMark: Sendable {
        let name: String
        let swatch: AccentRGB?
    }

    struct FrameIndex: Sendable {
        let position: Int

        var label: String {
            let number = position % 36 + 1
            var roll = position / 36 + 1
            var letters: [UInt8] = []
            while roll > 0 {
                roll -= 1
                letters.append(65 + UInt8(roll % 26))
                roll /= 26
            }
            return "\(number)\(String(decoding: letters.reversed(), as: UTF8.self))"
        }
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

        func gapCenter(after index: Int) -> CGFloat {
            photo.minX + CGFloat(index + 1) * photo.width / CGFloat(perforations)
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
    static func compose(_ photo: CGImage, stock: StockMark, isHPan: Bool, recipeAccent: AccentRGB?,
                        frameIndex: FrameIndex, captureISO: Int?) -> CIImage? {
        guard let typography else { return nil }
        let layout = Layout(width: photo.width, height: photo.height, isHPan: isHPan)
        let accent = palette(recipeAccent: recipeAccent, imageAccent: extractAccent(from: photo), stockAccent: stock.swatch)
        let ink = cgColor(accent)
        guard let upper = rail(width: layout.canvas.width, height: layout.railHeight, draw: {
            drawPerforations(in: $0, layout: layout, lower: false)
            if layout.isHPan {
                if let captureISO {
                    let iso = isoRun(captureISO, typeSize: layout.labelBandHeight * 0.57, ink: ink, typography: typography)
                    draw([iso], x: layout.photo.minX, y: layout.railHeight - layout.labelBandHeight / 2,
                         width: layout.photo.width, alignment: .center, in: $0)
                }
            } else {
                drawStockAndISO(in: $0, layout: layout, stockName: stock.name, captureISO: captureISO,
                                ink: ink, typography: typography)
            }
        }), let lower = rail(width: layout.canvas.width, height: layout.railHeight, draw: {
            drawPerforations(in: $0, layout: layout, lower: true)
            if layout.isHPan {
                drawPanoramicEdgePrint(in: $0, layout: layout, stockName: stock.name, frameIndex: frameIndex,
                                       ink: ink, typography: typography)
            } else {
                drawStandardLowerEdge(in: $0, layout: layout, label: frameIndex.label, ink: ink, typography: typography)
            }
        }) else { return nil }

        let backing = solid(base, in: layout.canvas)
        let translatedUpper = CIImage(cgImage: upper)
            .transformed(by: CGAffineTransform(translationX: 0, y: layout.photo.maxY))
        let translatedPhoto = CIImage(cgImage: photo)
            .transformed(by: CGAffineTransform(translationX: layout.photo.minX, y: layout.photo.minY))
        let aperture = CIFilter.roundedRectangleGenerator()
        aperture.extent = layout.photo
        aperture.radius = Float(min(layout.gateGap, min(layout.photo.width, layout.photo.height) / 2))
        aperture.color = CIColor(red: 1, green: 1, blue: 1)
        guard let mask = aperture.outputImage else { return nil }
        let clipped = CIFilter.sourceInCompositing()
        clipped.inputImage = translatedPhoto
        clipped.backgroundImage = mask
        guard let roundedPhoto = clipped.outputImage else { return nil }
        return roundedPhoto.composited(over:
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

    private static func drawStockAndISO(in context: CGContext, layout: Layout, stockName: String, captureISO: Int?,
                                        ink: CGColor, typography: Typography) {
        let left = layout.perforation(at: 0, lower: false).minX
        let right = layout.perforation(at: layout.perforations - 1, lower: false).maxX
        let y = layout.railHeight - layout.labelBandHeight / 2
        let typeSize = min(layout.labelBandHeight * 0.74, layout.photo.width / 22)
        var nameEnd = right
        if let captureISO {
            let iso = isoRun(captureISO, typeSize: typeSize * 0.77, ink: ink, typography: typography)
            let center = layout.gapCenter(after: layout.perforations - 2)
            let width = min(ceil(advance(of: iso)), 2 * (right - center))
            let x = center - width / 2
            draw([iso], x: x, y: y, width: width, alignment: .center, in: context)
            nameEnd = x - typeSize * 0.88
        }
        let stock = stockRun(stockName, typeSize: typeSize, ink: ink, typography: typography)
        draw([stock], x: left, y: y, width: nameEnd - left, in: context)
    }

    private static func drawStandardLowerEdge(in context: CGContext, layout: Layout, label: String,
                                               ink: CGColor, typography: Typography) {
        let height = layout.labelBandHeight
        let numberSize = min(height * 0.94, layout.photo.width / 18)
        let left = layout.gapCenter(after: 0)
        let right = layout.gapCenter(after: layout.perforations - 2)
        let width = min(2 * (left - layout.photo.minX), right - left)
        let face = CTFontCreateWithGraphicsFont(typography.stock, numberSize, nil, nil)
        let symbol = CTFontCreateWithGraphicsFont(typography.symbol, numberSize * 0.88, nil, symbolLigatures)

        draw([run("==>", font: symbol, color: ink)], x: left - width / 2, y: height / 2, width: width,
             alignment: .center, in: context)
        draw([run(label, font: face, color: ink)], x: right - width / 2, y: height / 2, width: width,
             alignment: .center, in: context)
    }

    private static func drawPanoramicEdgePrint(in context: CGContext, layout: Layout, stockName: String,
                                               frameIndex: FrameIndex, ink: CGColor, typography: Typography) {
        let left = layout.perforation(at: 0, lower: true).minX
        let right = layout.canvas.width - left
        let height = layout.labelBandHeight
        let typeSize = min(height * 0.72, layout.photo.width / 30)
        let tabX = right - typeSize * 5.9
        let indexEnd = tabX - typeSize * 0.65
        let label = frameIndex.label
        let numberSize = min(height * 0.98, typeSize * 1.30)
        let face = CTFontCreateWithGraphicsFont(typography.stock, numberSize, nil, nil)
        let symbol = CTFontCreateWithGraphicsFont(typography.symbol, numberSize * 0.72, nil, symbolLigatures)
        let number = run(label + " ", font: face, color: ink)
        let arrow = run("==>", font: symbol, color: ink)
        let width = ceil(advance(of: number) + advance(of: arrow))
        let halfLabel = advance(of: run(label, font: face, color: ink)) / 2
        let latestCenter = indexEnd - width + halfLabel
        let center = (0..<(layout.perforations - 1)).map { layout.gapCenter(after: $0) }
            .last { $0 <= latestCenter } ?? latestCenter
        let indexStart = center - halfLabel
        let stock = stockRun(stockName, typeSize: typeSize, ink: ink, typography: typography)
        draw([stock], x: left, y: height / 2, width: indexStart - typeSize * 0.6 - left, in: context)
        draw([number, arrow], x: indexStart, y: height / 2, width: width, in: context)

        let tab = CGRect(x: tabX, y: 0, width: layout.canvas.maxX - tabX, height: height * 0.78)
        drawHPanTab(in: context, tab: tab, typeSize: typeSize, ink: ink, typography: typography)
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

    private static func isoRun(_ iso: Int, typeSize: CGFloat, ink: CGColor, typography: Typography) -> NSAttributedString {
        let face = CTFontCreateWithGraphicsFont(typography.mark, typeSize, nil, nil)
        return run("ISO \(iso)", font: face, color: ink)
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
             x: tab.minX + typeSize * 0.5, y: tab.midY, width: tab.width - typeSize, alignment: .center, in: context)
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

    private static func advance(of run: NSAttributedString) -> CGFloat {
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(run), nil, nil, nil)
    }

    private enum EdgeAlignment { case left, center }

    private static func draw(_ runs: [NSAttributedString], x: CGFloat, y: CGFloat, width: CGFloat,
                             alignment: EdgeAlignment = .left, in context: CGContext) {
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
        let offset = alignment == .center ? (width - CTLineGetTypographicBounds(displayed, nil, nil, nil) * resolvedScale) / 2 : 0
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
