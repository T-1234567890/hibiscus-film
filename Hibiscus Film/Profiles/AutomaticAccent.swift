import CoreImage

nonisolated enum AutomaticAccent {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let kernel = Result {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let library = try Data(contentsOf: url, options: .mappedIfSafe)
        return try CIColorKernel(functionName: "filmAutomaticAccent", fromMetalLibraryData: library)
    }

    static func protectNeutralColors(in image: CIImage, tinted: CIImage) throws -> CIImage {
        let kernel = try kernel.get()
        // Measure chroma in the same space regardless of the rendering context.
        guard let guide = image.matchedFromWorkingSpace(to: sRGB),
              let result = kernel.apply(extent: image.extent, arguments: [image, tinted, guide]) else {
            throw CocoaError(.coderInvalidValue)
        }
        return result
    }
}
