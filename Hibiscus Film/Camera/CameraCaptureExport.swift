import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum CameraExportVariant: String, CaseIterable, Identifiable, Sendable {
    case photo, filmFrame
    var id: Self { self }

    func title(livePhoto: Bool) -> LocalizedStringKey {
        switch self {
        case .photo: livePhoto ? "Without Film Frame" : "Photo Only"
        case .filmFrame: "With Film Frame"
        }
    }
}

nonisolated enum CameraAutoSaveFormat: String, CaseIterable, Identifiable {
    case photo, filmFrame, both

    static let preferenceKey = "cameraAutoSaveFormat"
    var id: Self { self }

    var variants: Set<CameraExportVariant> {
        switch self {
        case .photo: [.photo]
        case .filmFrame: [.filmFrame]
        case .both: [.photo, .filmFrame]
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .photo: "Save Photo Only"
        case .filmFrame: "Save With Film Frame"
        case .both: "Save Both Versions"
        }
    }
}

nonisolated struct CameraCaptureExport: Sendable {
    let photo: CGImage
    let stock: FilmFrame.StockMark
    let recipeAccent: AccentRGB?
    let isHPan: Bool
    let frameIndex: FilmFrame.FrameIndex
    let captureISO: Int?

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    @concurrent func framedLivePhoto(from source: ProcessedLivePhoto) async throws -> ProcessedLivePhoto {
        defer { withExtendedLifetime(source) {} }
        try Task.checkCancellation()
        let file = try PhotoExportFile.temporary(filename: "Hibiscus-Film-Frame.heic")
        let movie = file.url.deletingPathExtension().appendingPathExtension("mov")
        let original = try Data(contentsOf: source.stillURL, options: .mappedIfSafe)
        let identifier = UUID().uuidString
        guard let frame = FilmFrame.prepare(photo, stock: stock, isHPan: isHPan, recipeAccent: recipeAccent,
                                            frameIndex: frameIndex, captureISO: captureISO),
              let image = frame.render(CIImage(cgImage: photo)),
              let still = Self.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.colorSpace),
              LivePhotoProcessor.writePairedStill(still, original: original, identifier: identifier, to: file.url),
              await LivePhotoProcessor.renderFramedMotion(source.motionURL, to: movie, context: Self.context, frame: frame),
              let motion = await LivePhotoProcessor.pairedVideo(motionURL: movie, sourceURL: source.motionURL,
                                                                identifier: identifier) else {
            throw CocoaError(.coderInvalidValue)
        }
        try Task.checkCancellation()
        return ProcessedLivePhoto(file: file, motionURL: motion, location: source.location)
    }

    @concurrent func file(for variant: CameraExportVariant) async throws -> PhotoExportFile {
        try Task.checkCancellation()
        let prefix = isHPan ? "Hibiscus-HPan0.5" : "Hibiscus"
        let name = variant == .filmFrame ? "\(prefix)-Film-Frame.jpg" : "\(prefix)-Photo.jpg"
        let file = try PhotoExportFile.temporary(filename: name)
        let quality = 0.98
        switch variant {
        case .photo:
            guard let target = CGImageDestinationCreateWithURL(file.url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(target, photo, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(target) else { throw CocoaError(.fileWriteUnknown) }
        case .filmFrame:
            guard let image = FilmFrame.compose(photo, stock: stock, isHPan: isHPan,
                                                recipeAccent: recipeAccent, frameIndex: frameIndex, captureISO: captureISO) else {
                throw CocoaError(.coderInvalidValue)
            }
            try Self.context.writeJPEGRepresentation(of: image, to: file.url,
                colorSpace: Self.colorSpace,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
        }
        try Task.checkCancellation()
        return file
    }
}

extension Stock {
    var filmFrameMark: FilmFrame.StockMark {
        let brand = isHibiscusOriginal ? "Hibiscus" : manufacturer
        let label = brand.map { name.lowercased().hasPrefix($0.lowercased() + " ") ? name : "\($0) \(name)" } ?? name
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let rgb = UIColor(tint).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            ? AccentRGB(red: red, green: green, blue: blue) : nil
        return FilmFrame.StockMark(name: label, swatch: rgb)
    }
}
