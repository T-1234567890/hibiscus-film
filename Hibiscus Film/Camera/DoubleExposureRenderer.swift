import CoreImage

nonisolated enum DoubleExposureRenderer {
    private static let linearLight = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// Give each frame half the exposure in linear light. The second frame
    /// sets the final crop and dimensions, including when the phone was rotated.
    static func combine(_ first: CIImage, with second: CIImage) -> CIImage? {
        let bounds = second.extent
        guard bounds.width > 0, bounds.height > 0, first.extent.width > 0, first.extent.height > 0 else { return nil }

        let source = first.extent
        let scale = max(bounds.width / source.width, bounds.height / source.height)
        let aligned = first.clampedToExtent()
            .transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                              tx: bounds.midX - source.midX * scale,
                                              ty: bounds.midY - source.midY * scale))
            .cropped(to: bounds)
        guard let base = second.matchedFromWorkingSpace(to: linearLight),
              let overlay = aligned.matchedFromWorkingSpace(to: linearLight) else { return nil }
        return base.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: overlay, kCIInputTimeKey: 0.5
        ]).matchedToWorkingSpace(from: linearLight)?.cropped(to: bounds)
    }
}
