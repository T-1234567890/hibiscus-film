import CoreImage
import Foundation
import ImageIO
import Metal

nonisolated enum PrintEffect: String, CaseIterable, Identifiable {
    case newsprint = "Newsprint"
    case magazine = "Magazine"
    case photocopy = "Photocopy"
    case risograph = "Risograph"
    case duotone = "Duotone"
    case fiber = "Fiber Print"
    case warm = "Warm Print"
    case ascii = "ASCII"
    case cyanotype = "Cyanotype"
    case engraving = "Engraving"
    case solarized = "Solarization"
    case archive = "Archive"
    case fade = "Fade"
    case chromaticDrift = "Chromatic Drift"
    case halftone = "Halftone"

    var id: Self { self }

    var palettes: [PrintPalette] {
        switch self {
        case .ascii: [.photoColors, .carbonIvory, .phosphor, .indigoGold, .blueApricot, .oxbloodRose, .violetMint, .bluePink]
        case .risograph: [.bluePink, .violetMint, .indigoGold, .blueApricot, .oxbloodRose]
        case .duotone: [.blueApricot, .violetMint, .oxbloodRose, .indigoGold, .bluePink, .phosphor, .carbonIvory]
        case .newsprint, .engraving: [.carbonIvory, .navyPaper, .sepia, .oxbloodRose]
        case .photocopy: [.toner, .navyPaper, .sepia, .phosphor]
        case .fiber: [.silverPaper, .navyPaper, .sepia, .carbonIvory]
        case .warm: [.sepia, .oxbloodRose, .blueApricot, .indigoGold]
        case .cyanotype: [.navyPaper, .indigoGold, .violetMint, .blueApricot]
        case .archive, .fade, .chromaticDrift, .halftone, .magazine, .solarized: []
        }
    }

    var defaultPalette: PrintPalette { palettes.first ?? .photoColors }
    var usesSpatialIntensity: Bool { self == .ascii || self == .chromaticDrift }
}

nonisolated enum PrintPalette: String, CaseIterable {
    case photoColors = "Photo Colors"
    case carbonIvory = "Carbon / ivory"
    case toner = "Black toner / white"
    case navyPaper = "Prussian blue / chalk"
    case silverPaper = "Silver / pearl"
    case sepia = "Sepia / honey"
    case phosphor = "Pine / phosphor"
    case bluePink = "Cobalt / pink"
    case blueApricot = "Prussian blue / apricot"
    case violetMint = "Violet / mint"
    case oxbloodRose = "Oxblood / rose"
    case indigoGold = "Indigo / gold"

    var colors: (dark: CIColor, light: CIColor) {
        switch self {
        case .photoColors: (.black, .white)
        case .carbonIvory: (.init(red: 0.12, green: 0.13, blue: 0.13), .init(red: 0.96, green: 0.93, blue: 0.82))
        case .toner: (.init(red: 0.025, green: 0.025, blue: 0.025), .white)
        case .navyPaper: (.init(red: 0.015, green: 0.09, blue: 0.31), .init(red: 0.94, green: 0.97, blue: 0.93))
        case .silverPaper: (.init(red: 0.10, green: 0.11, blue: 0.13), .init(red: 0.96, green: 0.95, blue: 0.90))
        case .sepia: (.init(red: 0.24, green: 0.12, blue: 0.10), .init(red: 1, green: 0.86, blue: 0.62))
        case .phosphor: (.init(red: 0.02, green: 0.12, blue: 0.08), .init(red: 0.54, green: 1, blue: 0.64))
        case .bluePink: (.init(red: 0.06, green: 0.27, blue: 0.83), .init(red: 1, green: 0.16, blue: 0.40))
        case .blueApricot: (.init(red: 0.035, green: 0.12, blue: 0.30), .init(red: 1, green: 0.69, blue: 0.43))
        case .violetMint: (.init(red: 0.23, green: 0.06, blue: 0.33), .init(red: 0.68, green: 0.98, blue: 0.78))
        case .oxbloodRose: (.init(red: 0.22, green: 0.025, blue: 0.07), .init(red: 1, green: 0.73, blue: 0.78))
        case .indigoGold: (.init(red: 0.08, green: 0.08, blue: 0.25), .init(red: 1, green: 0.86, blue: 0.25))
        }
    }
}

// Input is an already-rendered photograph. Screen pitch, grain and registration
// are expressed relative to the page so the same composition scales to export.
actor HibiscusPrintEngine {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    nonisolated let context: CIContext
    private let grain: CIImage

    init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: space, .cacheIntermediates: false]
        if let gpu = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: gpu, options: options)
        } else {
            context = CIContext(options: options)
        }
        // A fixed noise field keeps previews, repeat exports and Core Image tiles in register.
        let n = 192
        var seed: UInt32 = 0x48494249
        var pixels = [UInt8](repeating: 255, count: n * n * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 1664525 &+ 1013904223
            let v = UInt8(truncatingIfNeeded: seed >> 24)
            pixels[i] = v
            pixels[i + 1] = v
            pixels[i + 2] = v
        }
        grain = CIImage(bitmapData: Data(pixels), bytesPerRow: n * 4, size: CGSize(width: n, height: n),
                        format: .RGBA8, colorSpace: space).applyingFilter("CIAffineTile")
    }

    // Scale after screening so both overview sizes carry the same ink separations.
    func preview(_ source: CGImage, effect: PrintEffect, inks: PrintPalette, intensity: Double = 1, maxDimension: CGFloat? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let input = opaque(CIImage(cgImage: source))
        var output = try impression(input, effect: effect, inks: inks, intensity: intensity)
        if let maxDimension {
            let scale = min(1, maxDimension / max(input.extent.width, input.extent.height))
            output = output.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        }
        guard let bitmap = context.createCGImage(output, from: output.extent.integral, format: .RGBA8, colorSpace: space)
        else { throw CocoaError(.coderInvalidValue) }
        return bitmap
    }

    func export(_ data: Data, effect: PrintEffect, inks: PrintPalette, intensity: Double, to url: URL) throws {
        try Task.checkCancellation()
        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = try renderFrame(decoded, effect: effect, inks: inks, intensity: intensity)
        try Task.checkCancellation()
        // Lossless RGB preserves the edges of individual ink dots and the shifted color plates.
        try context.writePNGRepresentation(of: output, to: url, format: .RGBA8, colorSpace: space)
    }

    func renderFullSize(_ data: Data, effect: PrintEffect, inks: PrintPalette, intensity: Double) throws -> CGImage {
        try Task.checkCancellation()
        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rendered = try renderFrame(decoded, effect: effect, inks: inks, intensity: intensity)
        guard let image = context.createCGImage(rendered, from: rendered.extent, format: .RGBA8, colorSpace: space) else {
            throw CocoaError(.coderInvalidValue)
        }
        return image
    }

    nonisolated func renderFrame(_ input: CIImage, effect: PrintEffect, inks: PrintPalette, intensity: Double) throws -> CIImage {
        let positioned = input.transformed(by: .init(translationX: -input.extent.minX, y: -input.extent.minY))
        return try impression(opaque(positioned), effect: effect, inks: inks, intensity: intensity)
    }

    nonisolated private func opaque(_ image: CIImage) -> CIImage {
        image.composited(over: CIImage(color: .white).cropped(to: image.extent))
    }

    nonisolated private func mix(_ original: CIImage, _ target: CIImage, _ amount: Double) -> CIImage {
        if amount == 1 { return target }
        return original.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: target, kCIInputTimeKey: amount])
    }

    nonisolated private func tone(_ image: CIImage, saturation: Double = 0, contrast: Double = 1, brightness: Double = 0) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation,
            kCIInputContrastKey: contrast, kCIInputBrightnessKey: brightness])
    }

    nonisolated private func ink(_ density: CIImage, _ shadow: CIColor, _ highlight: CIColor) -> CIImage {
        density.applyingFilter("CIFalseColor", parameters: ["inputColor0": shadow, "inputColor1": highlight])
    }

    nonisolated private func screen(_ image: CIImage, width: CGFloat, angle: Double, lines: Bool = false) -> CIImage {
        image.applyingFilter(lines ? "CILineScreen" : "CIDotScreen", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputWidthKey: width, kCIInputAngleKey: angle,
            kCIInputSharpnessKey: 0.80])
    }

    nonisolated private func multiply(_ first: CIImage, _ second: CIImage) -> CIImage {
        first.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: second])
    }

    nonisolated private func impression(_ image: CIImage, effect: PrintEffect, inks: PrintPalette, intensity: Double) throws -> CIImage {
        let strength = min(1, max(0, intensity))
        guard strength > 0 else { return image }
        let pair = inks.colors
        let bounds = image.extent
        let unit = max(bounds.width, bounds.height) / 1200
        let stock = grain.transformed(by: .init(scaleX: unit * 1.2, y: unit * 1.2)).cropped(to: bounds)
        let output: CIImage
        switch effect {
        case .archive:
            let muted = tone(image, saturation: 0.44, contrast: 0.85)
            let aged = ink(tone(image, contrast: 0.94), CIColor(red: 0.075, green: 0.054, blue: 0.042),
                           CIColor(red: 0.96, green: 0.91, blue: 0.80))
            let print = mix(muted, aged, 0.63)
            output = mix(print, multiply(print, stock), 0.095)
        case .fade:
            let muted = tone(image, saturation: 0.70)
            output = muted.applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": CIVector(x: 0.13, y: 0.93, z: -0.16, w: 0),
                "inputGreenCoefficients": CIVector(x: 0.13, y: 0.93, z: -0.16, w: 0),
                "inputBlueCoefficients": CIVector(x: 0.14, y: 0.93, z: -0.16, w: 0)
            ])
        case .chromaticDrift:
            return try ChromaticDrift.render(image, strength: strength)
        case .halftone:
            let luma = tone(image, contrast: 1.12)
            let dots = screen(luma, width: 10 * unit, angle: .pi / 4)
            let color = tone(image, saturation: 1.06)
            let coloredInk = mix(color, multiply(color, color), 0.42)
            output = coloredInk.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: bounds),
                kCIInputMaskImageKey: dots.applyingFilter("CIColorInvert").cropped(to: bounds)
            ])
        case .ascii:
            return try ASCIIPrint.render(image, palette: inks, fill: strength)
        case .cyanotype:
            let blue = ink(tone(image, contrast: 1.35), pair.dark, pair.light)
            output = mix(blue, multiply(blue, stock), 0.09)
        case .engraving:
            let gray = tone(image, contrast: 1.18)
            let first = screen(gray, width: 5.4 * unit, angle: 0.53, lines: true)
            let second = screen(tone(gray, brightness: 0.28), width: 6.3 * unit, angle: -0.75, lines: true)
            output = ink(multiply(first, second), pair.dark, pair.light)
        case .solarized:
            let pivot = CIImage(color: CIColor(red: 0.50, green: 0.47, blue: 0.41)).cropped(to: bounds)
            let reversed = image.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: pivot])
            output = tone(reversed.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.15]),
                          saturation: 1.35, contrast: 1.22)
        case .newsprint:
            let gray = tone(image, contrast: 1.17)
            let dots = screen(gray, width: 7.8 * unit, angle: .pi / 7)
                .clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: unit * 0.55])
            let page = ink(mix(gray, dots, 0.86), pair.dark, pair.light)
            output = mix(page, multiply(page, stock), 0.11)
        case .magazine:
            let color = tone(image, saturation: 1.25, contrast: 1.14)
            let plates = color.applyingFilter("CICMYKHalftone", parameters: [kCIInputWidthKey: 3.8 * unit,
                kCIInputAngleKey: Double.pi / 12, kCIInputCenterKey: CIVector(x: 0, y: 0),
                kCIInputSharpnessKey: 0.75, "inputGCR": 0.74, "inputUCR": 0.58])
            output = mix(color, plates, 0.38)
        case .photocopy:
            let grainy = mix(tone(image), stock, 0.20)
            let toner = tone(grainy, contrast: 4.6, brightness: 0.035)
                .clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 0.65 * unit])
            let feed = grain.transformed(by: .init(scaleX: unit * 100, y: unit * 1.8)).cropped(to: bounds)
            output = mix(ink(toner, pair.dark, pair.light), feed, 0.09)
        case .risograph:
            // Derive two different density plates, then multiply the transparent inks on paper.
            func plate(_ weights: CIVector) -> CIImage {
                image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": weights, "inputGVector": weights,
                                                                  "inputBVector": weights])
            }
            let cool = plate(CIVector(x: 0.75, y: 0.20, z: 0.05, w: 0))
            let hot = plate(CIVector(x: 0.05, y: 0.55, z: 0.40, w: 0)).clampedToExtent()
                .transformed(by: .init(translationX: 3.8 * unit, y: -2.2 * unit)).cropped(to: bounds)
            let blue = ink(mix(cool, screen(cool, width: 5 * unit, angle: -0.48, lines: true), 0.66),
                           pair.dark, .white)
            let pink = ink(mix(hot, screen(hot, width: 6 * unit, angle: 0.42), 0.70),
                           pair.light, .init(red: 1, green: 0.96, blue: 0.86))
            let page = multiply(blue, pink)
            output = mix(page, multiply(page, stock), 0.14)
        case .duotone:
            output = ink(tone(image, contrast: 1.18), pair.dark, pair.light)
        case .fiber:
            let silver = ink(tone(image, contrast: 0.93), pair.dark, pair.light)
            let fibers = grain.transformed(by: .init(scaleX: unit * 9, y: unit * 0.9))
                .transformed(by: .init(rotationAngle: 0.11)).cropped(to: bounds)
            output = mix(silver, multiply(silver, fibers), 0.17)
        case .warm:
            let faded = tone(image, saturation: 0.57, contrast: 0.87, brightness: 0.025)
            let amber = ink(tone(image), pair.dark, pair.light)
            let page = mix(faded, amber, 0.57)
            output = mix(page, multiply(page, stock), 0.09)
        }
        return mix(image, output.cropped(to: bounds).applyingFilter("CIColorClamp"), strength)
    }
}
