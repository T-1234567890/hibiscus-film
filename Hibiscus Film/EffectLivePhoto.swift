import CoreImage
import Photos
import SwiftUI

nonisolated struct EffectLivePhoto: Sendable {
    let file: PhotoExportFile
    let motionURL: URL
    let preview: PHLivePhoto

    static func load(_ livePhoto: PHLivePhoto) async throws -> EffectPhoto {
        let resources = PHAssetResource.assetResources(for: livePhoto)
        let editedStill = resources.first { $0.type == .fullSizePhoto }
        let editedMotion = resources.first { $0.type == .fullSizePairedVideo }
        let editedPair = editedStill.flatMap { still in editedMotion.map { (still, $0) } }
        let originalPair = resources.first { $0.type == .photo }.flatMap { still in
            resources.first { $0.type == .pairedVideo }.map { (still, $0) }
        }
        guard let (still, motion) = editedPair ?? originalPair else { throw CocoaError(.fileReadCorruptFile) }
        let store = try PhotoExportFile.temporary(filename: "Source.mov")
        let stillURL = store.url.deletingLastPathComponent().appendingPathComponent("Source.still")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let manager = PHAssetResourceManager.default()
        try await manager.writeData(for: still, toFile: stillURL, options: options)
        try Task.checkCancellation()
        try await manager.writeData(for: motion, toFile: store.url, options: options)
        try Task.checkCancellation()
        let data = try Data(contentsOf: stillURL, options: .mappedIfSafe)
        let bitmap = try EffectPhoto.decode(data, maxDimension: 1600)
        return EffectPhoto(data: data, preview: UIImage(cgImage: bitmap), motion: store)
    }

    static func render(_ source: EffectPhoto, engine: HibiscusPrintEngine, effect: PrintEffect,
                       palette: PrintPalette, intensity: Double) async throws -> Self {
        guard let motion = source.motion else { throw CocoaError(.fileReadCorruptFile) }
        let file = try PhotoExportFile.temporary(filename: "Hibiscus-\(effect.rawValue).heic")
        let movie = file.url.deletingPathExtension().appendingPathExtension("mov")
        let pairID = UUID().uuidString
        let image = try await engine.renderFullSize(source.data, effect: effect, inks: palette, intensity: intensity)
        try Task.checkCancellation()
        guard LivePhotoProcessor.writePairedStill(image, original: source.data, identifier: pairID, to: file.url),
              await LivePhotoProcessor.renderMotion(motion.url, to: movie, context: engine.context, filter: { image in
                  try engine.renderFrame(image, effect: effect, inks: palette, intensity: intensity)
              }),
              let paired = await LivePhotoProcessor.pairedVideo(motionURL: movie, sourceURL: motion.url, identifier: pairID)
        else { throw CocoaError(.coderInvalidValue) }
        try Task.checkCancellation()
        let resources = ProcessedLivePhoto(directoryURL: file.url.deletingLastPathComponent(), stillURL: file.url,
                                           motionURL: paired, location: nil)
        guard let preview = await LivePhotoPreviewFactory.make(from: resources, placeholder: UIImage(cgImage: image),
                                                                targetSize: .zero) else {
            throw CocoaError(.coderInvalidValue)
        }
        return Self(file: file, motionURL: paired, preview: preview)
    }
}
