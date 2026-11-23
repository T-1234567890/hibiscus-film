import Accelerate
import CoreImage
import FotufilmCore
import FotufilmMetal

/// The only application component that knows Fotufilm's API or working color spaces.
nonisolated final class FotufilmRenderer: @unchecked Sendable {
    static let shared = FotufilmRenderer()
    enum Failure: Error { case profile, backend, image }
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let scene = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private let display = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private let stockLock = NSLock()
    private var stocks: [String: FotufilmCore.FilmStock] = [:]

    private static var options: FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.paper = .screen
        options.digitalReference = .referenceExposure
        return options
    }

    static func definition(_ id: String) throws -> FilmStockDefinition {
        if let url = KitchenRecipe.url(id) { return try KitchenRecipe.read(url).definition }
        guard FilmProfileExchange.shared.contains(where: { $0.stock.recipe.fotufilmID == id }) else { throw Failure.profile }
        let folder = id.hasPrefix("hibiscus-") ? FilmProfileFiles.hibiscus : FilmProfileFiles.pack.appendingPathComponent("Originals")
        let definition = try JSONDecoder().decode(FilmStockDefinition.self, from: Data(contentsOf: folder.appendingPathComponent(id + ".json")))
        try definition.validate()
        return definition
    }

    private func loadStock(_ id: String) throws -> FotufilmCore.FilmStock {
        if let cached = stockLock.withLock({ stocks[id] }) { return cached }
        let definition = try Self.definition(id)
        let stock = definition.stock
        stockLock.withLock { stocks[id] = stock }
        return stock
    }

    // Use the engine's normal invocation to populate its shared, bounded spectral cache.
    // This does not submit GPU work or hold the camera's render lock.
    @concurrent func prepare(_ id: String) async {
        guard !Task.isCancelled, let stock = try? loadStock(id), !Task.isCancelled else { return }
        _ = try? FilmEngineInvocation(validating: stock, options: Self.options, width: 480, height: 360)
    }

    func process(_ source: CIImage, development: FilmDevelopment, realtime: Bool) throws -> CIImage {
        try process(source, stock: loadStock(development.profileID), expiredYears: development.expiredYears, realtime: realtime)
    }

    func process(_ source: CIImage, stock: FotufilmCore.FilmStock, expiredYears: Int = 0, realtime: Bool) throws -> CIImage {
        lock.lock()
        defer { lock.unlock() }
        guard let renderer = HalideMetalFilmRenderer.shared else { throw Failure.backend }
        let bounds = source.extent.integral
        guard !bounds.isInfinite, !bounds.isEmpty, bounds.width <= 65536, bounds.height <= 65536 else { throw Failure.image }
        let width = Int(bounds.width), height = Int(bounds.height)
        var options = Self.options
        // Fotufilm applies its native stock expiration while building the invocation.
        options.expiredYears = Float(expiredYears)
        var transform: FilmOutputTransform?
        var buffer = Data(count: width * height * 8)
        let ok = buffer.withUnsafeMutableBytes { output in
            renderer.developStreaming(width: width, height: height, stock: stock, options: options,
                outputTransform: &transform, realtime: realtime, readTile: { rows, columns, tile in
                    let rect = CGRect(x: bounds.minX + CGFloat(columns.lowerBound), y: bounds.maxY - CGFloat(rows.upperBound),
                                      width: CGFloat(columns.count), height: CGFloat(rows.count))
                    self.context.render(source, toBitmap: tile.baseAddress!, rowBytes: columns.count * 16,
                                        bounds: rect, format: .RGBAf, colorSpace: self.scene)
                }, writeTile: { rows, columns, tile in
                    var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: tile.baseAddress!),
                        height: vImagePixelCount(rows.count), width: vImagePixelCount(columns.count * 4), rowBytes: columns.count * 16)
                    var target = vImage_Buffer(data: output.baseAddress!.advanced(by: (rows.lowerBound * width + columns.lowerBound) * 8),
                        height: input.height, width: input.width, rowBytes: width * 8)
                    vImageConvert_PlanarFtoPlanar16F(&input, &target, 0)
                })
        }
        guard ok else { throw Failure.backend }
        return CIImage(bitmapData: buffer, bytesPerRow: width * 8, size: bounds.size, format: .RGBAh, colorSpace: display)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY)).cropped(to: source.extent)
    }
}
