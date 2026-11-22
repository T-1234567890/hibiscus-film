import SwiftUI
import CoreImage
import ImageIO

nonisolated struct Recipe: Codable, Equatable {
    var fotufilmID: String?
    var point = CGPoint(x: 0.5, y: 0.5)
    var accentPoint = CGPoint(x: 0.5, y: 0.5)
    var strength = 78.0
    var accentStrength = 52.0
    static let defaultHue = 0.06
    var hue = Self.defaultHue
    // Optional for profiles written before scene sampling. Preserve a customized legacy hue.
    var automaticAccent: Bool?
    var usesSceneAccent: Bool { automaticAccent ?? (hue == Recipe.defaultHue) }
    // Populated only on the camera renderer’s copy of the recipe.
    var sceneColor: AccentRGB?
    var accentBase: AccentRGB {
        if let sceneColor { return sceneColor }
        if usesSceneAccent { return .neutralGray }
        let color = CIColor(color: UIColor(hue: hue, saturation: 0.72, brightness: 0.94, alpha: 1))
        return AccentRGB(red: color.red, green: color.green, blue: color.blue)
    }
    var contrast = 1.0
    var saturation = 1.0
}

nonisolated struct Stock: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var iso: Int?
    var swatch: UInt32?
    var family: String
    var notes: String
    var style: OriginalStyle
    var recipe = Recipe()
    var custom = false

    var archiveFile: String?
    var importedArchive: String?
    var permitsProfileExport: Bool?
    var manufacturer: String?
    var isHibiscusOriginal: Bool { id.hasPrefix("hibiscus-") }
    var canRender: Bool { recipe.fotufilmID != nil }
    static let collection = FilmProfileExchange.shared.map(\.stock)
    static let classicDefault = collection.first { $0.recipe.fotufilmID == "portra400" }
        ?? collection.first { !$0.isHibiscusOriginal && $0.canRender } ?? collection[0]
}

@Observable final class FilmSession {
    static let defaultStockPreferenceKey = "defaultStock"
    private let defaults = UserDefaults.standard
    var custom: [Stock] { didSet { defaults.set(try? JSONEncoder().encode(custom), forKey: "profiles") } }
    var favorites: Set<String> { didSet { defaults.set(Array(favorites), forKey: "favorites") } }
    var stocks: [Stock] { Stock.collection + custom }
    private(set) var active: Stock
    var recipe: Recipe {
        didSet {
            var local = recipe
            local.sceneColor = nil
            if let bytes = try? JSONEncoder().encode(local) {
                defaults.set(bytes, forKey: "film.adjustment." + active.id)
            }
        }
    }

    private static func localRecipe(_ stock: Stock, defaults: UserDefaults) -> Recipe {
        guard let data = defaults.data(forKey: "film.adjustment." + stock.id),
              var saved = try? JSONDecoder().decode(Recipe.self, from: data) else { return stock.recipe }
        saved.fotufilmID = stock.recipe.fotufilmID
        return saved
    }
    var lockFocus = false
    var ratio = CameraAspectRatio.standard
    private(set) var source: CameraImage?
    private(set) var revision = 0

    private(set) var isCapture = false

    func setSource(_ image: CameraImage, captured: Bool = true) {
        isCapture = captured
        if let url = source?.movie { try? FileManager.default.removeItem(at: url) }
        source = image
        revision += 1
    }

    var live: Bool

    init() {
        let prefs = UserDefaults.standard
        let saved = (try? JSONDecoder().decode([Stock].self, from: prefs.data(forKey: "profiles") ?? Data())) ?? []
        custom = saved
        favorites = Set(prefs.stringArray(forKey: "favorites") ?? [])
        let savedDefault = prefs.string(forKey: Self.defaultStockPreferenceKey)
        let initial = (Stock.collection + saved).first { $0.id == savedDefault && $0.canRender } ?? Stock.classicDefault
        if let savedDefault, savedDefault != initial.id {
            prefs.set(initial.id, forKey: Self.defaultStockPreferenceKey)
        }
        active = initial
        recipe = Self.localRecipe(initial, defaults: prefs)
        live = prefs.bool(forKey: "defaultLive")
    }

    func load(_ stock: Stock) {
        guard stock.canRender, active.id != stock.id else { return }
        active = stock
        recipe = Self.localRecipe(stock, defaults: defaults)
    }

    func refreshStock(_ stock: Stock) {
        guard active.id == stock.id else { return }
        active = stock
        recipe = Self.localRecipe(stock, defaults: defaults)
    }

}

actor GradeRenderer {
    private var cachedRevision: Int?
    private var cachedSource: CIImage?
    let context = CameraImageRenderer.context
    private func thumbnail(_ data: Data) -> CIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200
              ] as CFDictionary) else { return nil }
        return CIImage(cgImage: cg)
    }

    func render(source input: CameraImage, revision: Int, style: OriginalStyle?, recipe: Recipe) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if cachedRevision != revision {
            cachedSource = thumbnail(input.data).map { cropped($0, portraitRatio: input.portraitRatio) }
            cachedRevision = revision
        }
        guard let source = cachedSource else { return nil }
        let output: CIImage
        if let style {
            guard let rendered = try? FilmColorPipeline.apply(style, recipe: recipe, to: source) else { return nil }
            output = rendered
        } else { output = source }
        return context.createCGImage(output, from: source.extent)
    }

    private func cropped(_ image: CIImage, portraitRatio: CGFloat?) -> CIImage {
        var source = image
        if let portraitRatio {
            let ratio = source.extent.width > source.extent.height ? 1 / portraitRatio : portraitRatio
            let width = min(source.extent.width, source.extent.height * ratio)
            let height = width / ratio
            let bounds = CGRect(x: source.extent.midX - width / 2, y: source.extent.midY - height / 2, width: width, height: height)
            source = source.cropped(to: bounds)
        }
        return source
    }

    func export(source: CameraImage, style: OriginalStyle, recipe: Recipe) -> Data? {
        guard let image = CIImage(data: source.data, options: [.applyOrientationProperty: true]) else { return nil }
        guard let output = try? FilmColorPipeline.apply(style, recipe: recipe, to: cropped(image, portraitRatio: source.portraitRatio)) else { return nil }
        return context.jpegRepresentation(of: output, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

nonisolated enum FilmColorPipeline {
    static func apply(_ style: OriginalStyle, recipe: Recipe, to source: CIImage, realtime: Bool = false) throws -> CIImage {
        guard let id = recipe.fotufilmID else { throw FotufilmRenderer.Failure.profile }
        let negative = try FotufilmRenderer.shared.process(source, profile: id, realtime: realtime)
        return try adjust(negative: negative, source: source, recipe: recipe)
    }

    static func adjust(negative: CIImage, source: CIImage, recipe: Recipe) throws -> CIImage {
        let chroma = 2 * (recipe.point.x - 0.5)
        let tone = 2 * (0.5 - recipe.point.y)
        let styled = negative.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1 + chroma * 0.055, kCIInputContrastKey: 1 - tone * 0.018
        ])
        let diffused = try HighlightDiffusion.apply(to: styled, tone: tone)
        let mixed = source.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: diffused, kCIInputTimeKey: recipe.strength / 100])
        let accent = PadAccent(x: recipe.accentPoint.x, y: recipe.accentPoint.y, strength: recipe.accentStrength / 100)
        let tones = accent.tones(base: recipe.accentBase)
        func color(_ rgb: AccentRGB) -> CIColor { CIColor(red: rgb.red, green: rgb.green, blue: rgb.blue) }
        let accented = HibiscusOriginalStyles.splitTone(mixed, shadow: color(tones.shadow), highlight: color(tones.highlight), amount: accent.strength, placement: tones.pivot)
        let output = accented.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: recipe.contrast, kCIInputSaturationKey: recipe.saturation])
        return output
    }
}

nonisolated struct CameraImage: Sendable {
    var data: Data
    var movie: URL?
    var portraitRatio: CGFloat? = nil
}
