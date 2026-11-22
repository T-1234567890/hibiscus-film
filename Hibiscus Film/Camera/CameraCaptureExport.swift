import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum CameraExportVariant: String, CaseIterable, Identifiable, Sendable {
    case photo, filmFrame
    var id: Self { self }

    func title(livePhoto: Bool) -> LocalizedStringKey {
        switch self {
        case .photo: "Photo Only"
        case .filmFrame: livePhoto ? "With Film Frame (Still)" : "With Film Frame"
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

    private static let context = CIContext(options: [.cacheIntermediates: false])

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
            guard let image = FilmFrame.compose(photo, stock: stock, isHPan: isHPan, recipeAccent: recipeAccent) else {
                throw CocoaError(.coderInvalidValue)
            }
            try Self.context.writeJPEGRepresentation(of: image, to: file.url,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
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
