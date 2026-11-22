import CoreImage

nonisolated enum HighlightDiffusion {
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private struct Kernels {
        let seed: CIColorKernel
        let composite: CIColorKernel

        init() throws {
            guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let library = try Data(contentsOf: url, options: .mappedIfSafe)
            seed = try CIColorKernel(functionName: "filmHighlightSeed", fromMetalLibraryData: library)
            composite = try CIColorKernel(functionName: "filmHighlightComposite", fromMetalLibraryData: library)
        }
    }

    private static let kernels = Result { try Kernels() }

    static func apply(to image: CIImage, tone: CGFloat) throws -> CIImage {
        guard tone > 0 else { return image }
        let t = min(tone, 1)
        let gain = 0.14 * t * t * (3 - 2 * t)
        let kernels = try kernels.get()
        let bounds = image.extent
        guard let linear = image.matchedFromWorkingSpace(to: linearSpace),
              let seed = kernels.seed.apply(extent: bounds, arguments: [linear]) else {
            throw CocoaError(.coderInvalidValue)
        }
        let sigma = min(bounds.width, bounds.height) * 0.008
        let scatter = seed.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: bounds)
        guard let composite = kernels.composite.apply(extent: bounds, arguments: [linear, scatter, gain]),
              let output = composite.matchedToWorkingSpace(from: linearSpace) else {
            throw CocoaError(.coderInvalidValue)
        }
        return output
    }
}
