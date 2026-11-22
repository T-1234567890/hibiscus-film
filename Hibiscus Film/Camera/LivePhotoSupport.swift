// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus iOS camera.
@preconcurrency import AVFoundation
import CoreImage
import CoreLocation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ProcessedLivePhoto: @unchecked Sendable {
    let file: PhotoExportFile
    let motionURL: URL
    let location: CLLocation?

    var stillURL: URL { file.url }
}

nonisolated enum LivePhotoProcessor {
    static func processCameraCapture(
        photoData: Data,
        motionURL sourceMotionURL: URL,
        displayTime: CMTime?,
        character: OriginalStyle?,
        adjustment: Recipe,
        aspectRatio: CGFloat,
        targetMegapixels: Int,
        location: CLLocation?
    ) async -> ProcessedLivePhoto? {
        guard let file = try? PhotoExportFile.temporary(filename: "Hibiscus-Camera-Live.heic") else { return nil }
        let motionURL = file.url.deletingPathExtension().appendingPathExtension("mov")
        let pairID = UUID().uuidString
        guard renderCameraStill(
            photoData,
            to: file.url,
            identifier: pairID,
            character: character,
            adjustment: adjustment,
            aspectRatio: aspectRatio,
            targetMegapixels: targetMegapixels
        ) else { return nil }

        let renderedMotion = await renderCameraMotion(
            sourceMotionURL,
            to: motionURL,
            character: character,
            adjustment: adjustment,
            aspectRatio: aspectRatio
        )
        if renderedMotion, let video = await pairedVideo(motionURL: motionURL, sourceURL: sourceMotionURL,
                                                         identifier: pairID, fallbackTime: displayTime) {
            return ProcessedLivePhoto(file: file, motionURL: video, location: location)
        }
        return nil
    }

    static func pairedVideo(motionURL: URL, sourceURL: URL, identifier: String,
                            fallbackTime: CMTime? = nil) async -> URL? {
        let paired = motionURL.deletingPathExtension().appendingPathExtension("paired.mov")
        do {
            try await LivePhotoTiming.pair(source: sourceURL, rendered: motionURL, to: paired,
                                           identifier: identifier, fallbackTime: fallbackTime)
            try? FileManager.default.removeItem(at: motionURL)
            return paired
        } catch { return nil }
    }

    private static func renderCameraStill(
        _ data: Data,
        to destinationURL: URL,
        identifier: String,
        character: OriginalStyle?,
        adjustment: Recipe,
        aspectRatio: CGFloat,
        targetMegapixels: Int
    ) -> Bool {
        guard let image = UIImage(data: data),
              let rendered = CameraImageRenderer.cameraImage(
                  image, character: character, adjustment: adjustment,
                  aspectRatio: aspectRatio, targetMegapixels: targetMegapixels
              )?.cgImage else { return false }
        return writePairedStill(rendered, original: data, identifier: identifier, to: destinationURL)
    }

    static func writePairedStill(_ rendered: CGImage, original: Data, identifier: String, to destinationURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { return false }
        let mutable = (properties as NSDictionary).mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
        // The maker dictionary for this new still carries its pairing ID only.
        // Original framing, auxiliary-image and alignment tags refer to the source.
        mutable[kCGImagePropertyMakerAppleDictionary] = ["17": identifier]
        mutable[kCGImagePropertyOrientation] = 1
        mutable[kCGImagePropertyPixelWidth] = rendered.width
        mutable[kCGImagePropertyPixelHeight] = rendered.height
        if var exif = mutable[kCGImagePropertyExifDictionary] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifMakerNote as String)
            exif[kCGImagePropertyExifPixelXDimension as String] = rendered.width
            exif[kCGImagePropertyExifPixelYDimension as String] = rendered.height
            mutable[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = mutable[kCGImagePropertyTIFFDictionary] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            mutable[kCGImagePropertyTIFFDictionary] = tiff
        }
        mutable[kCGImageDestinationLossyCompressionQuality] = 0.98
        CGImageDestinationAddImage(destination, rendered, mutable)
        return CGImageDestinationFinalize(destination)
    }

    private static func renderCameraMotion(
        _ sourceURL: URL,
        to destinationURL: URL,
        character: OriginalStyle?,
        adjustment: Recipe,
        aspectRatio: CGFloat
    ) async -> Bool {
        await renderMotion(sourceURL, to: destinationURL, context: CameraImageRenderer.context,
                           portraitAspectRatio: aspectRatio) { image in
            try CameraImageRenderer.cameraMotionCIImage(image, character: character, adjustment: adjustment,
                                                       aspectRatio: aspectRatio, inputExposureEV: 0)
        }
    }

    static func renderFramedMotion(_ sourceURL: URL, to destinationURL: URL, context: CIContext,
                                   frame: FilmFrame.Composition) async -> Bool {
        let source = AVURLAsset(url: sourceURL)
        guard let track = try? await source.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return false }
        let oriented = naturalSize.applying(transform)
        let scale = min(abs(oriented.width) / frame.size.width, abs(oriented.height) / frame.size.height)
        guard scale.isFinite, scale > 0 else { return false }
        let size = LivePhotoFrameRenderer.encoderSize(CGSize(width: frame.size.width * scale, height: frame.size.height * scale))
        let motionFrame = frame.scaled(to: size)
        return await renderMotion(sourceURL, to: destinationURL, context: context, outputSize: size) { image in
            guard let result = motionFrame.render(image) else { throw CocoaError(.coderInvalidValue) }
            return result
        }
    }

    static func renderMotion(
        _ sourceURL: URL, to destinationURL: URL, context: CIContext,
        portraitAspectRatio: CGFloat? = nil, outputSize: CGSize? = nil,
        filter: @escaping @Sendable (CIImage) throws -> CIImage
    ) async -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }
        export.shouldOptimizeForNetworkUse = false
        export.metadata = []
        guard let composition = try? await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            do {
                let rendered = try filter(request.sourceImage)
                request.finish(with: LivePhotoFrameRenderer.output(rendered, renderSize: request.renderSize), context: context)
            } catch { request.finish(with: error) }
        }) else { return false }
        if let outputSize {
            composition.renderSize = outputSize
        } else if let portraitAspectRatio, let track = try? await asset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            composition.renderSize = renderSize(for: naturalSize.applying(transform), portraitAspectRatio: portraitAspectRatio)
        }
        composition.renderSize = LivePhotoFrameRenderer.encoderSize(composition.renderSize)
        export.videoComposition = composition
        do {
            try await export.export(to: destinationURL, as: .mov)
            return true
        } catch { return false }
    }

    private static func renderSize(for transformedSize: CGSize, portraitAspectRatio: CGFloat) -> CGSize {
        var width = abs(transformedSize.width)
        var height = abs(transformedSize.height)
        guard width > 0, height > 0 else { return CGSize(width: 1080, height: 1440) }
        let targetRatio = width > height ? 1 / portraitAspectRatio : portraitAspectRatio
        if width / height > targetRatio {
            width = height * targetRatio
        } else {
            height = width / targetRatio
        }
        return CGSize(
            width: max(2, floor(width / 2) * 2),
            height: max(2, floor(height / 2) * 2)
        )
    }
}

@MainActor
enum LivePhotoPreviewFactory {
    static func make(from output: ProcessedLivePhoto, placeholder: UIImage,
                     targetSize: CGSize = .zero) async -> PHLivePhoto? {
        defer { withExtendedLifetime(output) {} }
        return await withCheckedContinuation { continuation in
            var didFinish = false
            PHLivePhoto.request(
                withResourceFileURLs: [output.stillURL, output.motionURL],
                placeholderImage: placeholder,
                targetSize: targetSize,
                contentMode: .aspectFit
            ) { livePhoto, info in
                guard !didFinish else { return }
                let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue ?? false
                let error = info[PHLivePhotoInfoErrorKey] as? Error
                if error != nil || (!isDegraded && livePhoto == nil) {
                    didFinish = true
                    continuation.resume(returning: nil)
                } else if let livePhoto, !isDegraded {
                    didFinish = true
                    continuation.resume(returning: livePhoto)
                }
            }
        }
    }
}

struct HibiscusLivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let onPlaybackEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPlaybackEnded: onPlaybackEnded) }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView(frame: .zero)
        view.contentMode = UIView.ContentMode.scaleAspectFit
        view.clipsToBounds = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        let changedPhoto = view.livePhoto !== livePhoto
        guard changedPhoto else { return }
        view.livePhoto = livePhoto
        DispatchQueue.main.async {
            view.startPlayback(with: .full)
        }
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        view.delegate = nil
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var onPlaybackEnded: () -> Void

        init(onPlaybackEnded: @escaping () -> Void) {
            self.onPlaybackEnded = onPlaybackEnded
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            onPlaybackEnded()
        }
    }
}

nonisolated private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
