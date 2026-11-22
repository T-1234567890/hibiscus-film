// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus iOS camera.
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

nonisolated enum CameraImageRenderer {
    static let gradeWorkingColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    static let gradeOutputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [
        .cacheIntermediates: true,
        .workingColorSpace: gradeWorkingColorSpace,
        .outputColorSpace: gradeOutputColorSpace
    ])

    static func cameraCIImage(
        _ image: CIImage,
        character: OriginalStyle?,
        adjustment: Recipe
    ) throws -> CIImage {
        guard let character else { return image }
        return try FilmColorPipeline.apply(character, recipe: adjustment, to: image).cropped(to: image.extent)
    }

    static func cameraMotionCIImage(
        _ image: CIImage,
        character: OriginalStyle?,
        adjustment: Recipe,
        aspectRatio: CGFloat,
        inputExposureEV: Double
    ) throws -> CIImage {
        var source = image
        if inputExposureEV != 0 { source = exposure(source, ev: inputExposureEV) }
        let orientedAspectRatio = source.extent.width > source.extent.height
            ? 1 / aspectRatio
            : aspectRatio
        let crop = source.cropped(to: cropBounds(source.extent, to: orientedAspectRatio))
        let rendered = try cameraCIImage(
            LivePhotoFrameRenderer.filterInput(crop),
            character: character,
            adjustment: adjustment
        ).cropped(to: crop.extent)
        return rendered.transformed(by: CGAffineTransform(
            translationX: -rendered.extent.minX,
            y: -rendered.extent.minY
        ))
    }

    static func cameraImage(
        _ image: UIImage,
        character: OriginalStyle?,
        adjustment: Recipe = Recipe(),
        aspectRatio: CGFloat,
        targetMegapixels: Int,
        inputExposureEV: Double = 0,
        firstExposure: UIImage? = nil
    ) -> UIImage? {
        guard var source = normalizedCIImage(image) else { return nil }
        if inputExposureEV != 0 {
            source = exposure(source, ev: inputExposureEV)
        }
        let orientedAspectRatio = source.extent.width > source.extent.height
            ? 1 / aspectRatio
            : aspectRatio
        var input = source.cropped(to: cropBounds(source.extent, to: orientedAspectRatio))
        let targetPixels = CGFloat(targetMegapixels) * 1_000_000
        let sourcePixels = input.extent.width * input.extent.height
        if targetPixels > 0, sourcePixels > targetPixels * 1.03 {
            let scale = sqrt(targetPixels / sourcePixels)
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        if let firstExposure {
            guard let first = normalizedCIImage(firstExposure),
                  let composite = DoubleExposureRenderer.combine(first, with: input) else { return nil }
            input = composite
        }
        guard let graded = try? cameraCIImage(input, character: character, adjustment: adjustment) else { return nil }
        return makeUIImage(from: graded, scale: image.scale)
    }

    static func panoramicImage(_ image: UIImage, character: OriginalStyle, adjustment: Recipe,
                               orientationCorrection: CGImagePropertyOrientation) -> UIImage? {
        guard let normalized = normalizedCIImage(image) else { return nil }
        let source = normalized.oriented(orientationCorrection)
        let crop = cropBounds(source.extent, to: HPan.landscapeRatio)
        // Keep complete sensor pixels along the long edge and avoid partial edge pixels in the JPEG.
        let pixels = CGRect(x: crop.minX.rounded(), y: crop.minY.rounded(),
                            width: crop.width.rounded(), height: crop.height.rounded())
        guard let graded = try? cameraCIImage(source.cropped(to: pixels), character: character, adjustment: adjustment) else { return nil }
        return makeUIImage(from: graded, scale: 1)
    }

    static func sourceCIImage(_ image: UIImage) -> CIImage? {
        normalizedCIImage(image)
    }

    private static func exposure(_ image: CIImage, ev: Double) -> CIImage {
        image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
    }

    static func cropBounds(_ extent: CGRect, to targetRatio: CGFloat) -> CGRect {
        guard extent.width > 0, extent.height > 0, targetRatio > 0 else { return extent }
        let sourceRatio = extent.width / extent.height
        var crop = extent
        if sourceRatio > targetRatio {
            crop.size.width = extent.height * targetRatio
            crop.origin.x = extent.midX - crop.width / 2
        } else {
            crop.size.height = extent.width / targetRatio
            crop.origin.y = extent.midY - crop.height / 2
        }
        return crop
    }

    private static func normalizedCIImage(_ image: UIImage) -> CIImage? {
        if let cgImage = image.cgImage {
            return CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(image.imageOrientation.exifOrientation.rawValue))
        }
        return image.ciImage
    }

    private static func makeUIImage(from image: CIImage, scale: CGFloat) -> UIImage? {
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

nonisolated private extension UIImage.Orientation {
    var exifOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
