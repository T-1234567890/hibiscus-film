import CoreImage
import Foundation

nonisolated enum ChromaticDrift {
    private static let kernel = Result {
        guard let library = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try CIColorKernel(functionName: "filmChromaticDrift", fromMetalLibraryData: Data(contentsOf: library, options: .mappedIfSafe))
    }

    static func render(_ image: CIImage, strength: Double) throws -> CIImage {
        let bounds = image.extent
        let displacement = max(bounds.width, bounds.height) * strength * 0.010
        let extended = image.clampedToExtent()
        let red = extended.transformed(by: .init(translationX: -displacement, y: -0.28 * displacement))
        let blue = extended.transformed(by: .init(translationX: 0.82 * displacement, y: 0.21 * displacement))
        guard let result = try kernel.get().apply(extent: bounds, arguments: [image, red, blue]) else {
            throw CocoaError(.coderInvalidValue)
        }
        return result
    }
}
