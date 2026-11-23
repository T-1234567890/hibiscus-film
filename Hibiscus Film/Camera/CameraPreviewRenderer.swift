// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus iOS camera.
import CoreImage
@preconcurrency import Metal
@preconcurrency import MetalKit
@preconcurrency import QuartzCore
import SwiftUI

nonisolated final class CameraPreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "film.preview.develop", qos: .userInteractive)
    private let device: MTLDevice
    private let context: CIContext
    private let commandQueue: MTLCommandQueue
    private let colorSpace = CameraImageRenderer.gradeWorkingColorSpace
    private var latestImage: CIImage?
    private var latestCharacter: OriginalStyle?
    private var latestAdjustment = Recipe()
    private var frameVersion: UInt64 = 0
    private var submittedVersion: UInt64 = 0
    var onProfileResult: (@Sendable (FilmDevelopment, Bool) -> Void)?
    private var awaitedProfile: FilmDevelopment?

    func awaitFirstFrame(for profile: FilmDevelopment) {
        lock.lock()
        invalidateProof()
        awaitedProfile = profile
        lock.unlock()
    }

    func isAwaitingFirstFrame(for profile: FilmDevelopment) -> Bool {
        lock.withLock { awaitedProfile == profile }
    }

    // Development and display have independent back pressure. A pad edit can use
    // the last developed frame even while the next camera buffer is in Fotufilm.
    private struct Proof {
        let source: CIImage
        let negative: CIImage?
        let profile: FilmDevelopment?
        let version: UInt64
        let target: CGSize
        let scale: CGFloat
    }
    private let displayQueue = DispatchQueue(label: "film.preview.display", qos: .userInteractive)
    private var proof: Proof?
    private var generation: UInt64 = 0
    private var presentedVersion: UInt64?
    private var presentedAdjustment: Recipe?
    private var isPresenting = false
    private var proofDimension: CGFloat = 640

    private func invalidateProof() {
        generation &+= 1
        proof = nil
        presentedVersion = nil
    }

    func updateAdjustment(_ recipe: Recipe) {
        lock.withLock {
            if latestAdjustment.development != recipe.development { frameVersion &+= 1 }
            latestAdjustment = recipe
        }
    }

    private var reportedDevelopmentFailure = false
    private var isDeveloping = false
    private var isFrozen = false
    private var freezesAfterNextRender = false
    private var pendingReveal: (@Sendable () -> Void)?

    init?(device: MTLDevice?) {
        guard let device,
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.context = CIContext(mtlDevice: device, options: [.cacheIntermediates: true, .workingColorSpace: CameraImageRenderer.gradeWorkingColorSpace])
        self.commandQueue = commandQueue
        super.init()
    }

    @MainActor
    func configure(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        (view.layer as? CAMetalLayer)?.colorspace = colorSpace
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
    }

    func submit(
        _ image: CIImage,
        character: OriginalStyle?,
        adjustment: Recipe
    ) {
        lock.lock()
        guard !isFrozen else {
            lock.unlock()
            return
        }
        latestImage = image
        latestCharacter = character
        latestAdjustment = adjustment
        frameVersion &+= 1
        lock.unlock()
    }

    /// Atomically replaces the frozen switch frame and resumes rendering. The
    /// completion runs only after Metal presents the first correctly configured
    /// frame from the new camera.
    func reveal(
        _ image: CIImage,
        character: OriginalStyle?,
        adjustment: Recipe,
        completion: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        invalidateProof()
        latestImage = image
        latestCharacter = character
        latestAdjustment = adjustment
        frameVersion &+= 1
        pendingReveal = completion
        isFrozen = false
        freezesAfterNextRender = false
        lock.unlock()
    }

    /// Seeds a newly created preview view with a known correctly oriented still
    /// and then holds it until a validated camera frame is revealed.
    func hold(_ image: CIImage) {
        lock.lock()
        invalidateProof()
        latestImage = image
        latestCharacter = nil
        latestAdjustment = Recipe()
        frameVersion &+= 1
        pendingReveal = nil
        isFrozen = false
        freezesAfterNextRender = true
        lock.unlock()
    }

    func freeze() {
        lock.lock()
        invalidateProof()
        isFrozen = true
        lock.unlock()
    }

    func resume() {
        lock.lock()
        isFrozen = false
        freezesAfterNextRender = false
        lock.unlock()
    }

    func clear() {
        lock.lock()
        invalidateProof()
        latestImage = nil
        frameVersion &+= 1
        lock.unlock()
    }

    func draw(in view: MTKView) {
        let target = view.drawableSize
        guard target.width > 0, target.height > 0 else { return }

        lock.lock()
        guard !isFrozen, let image = latestImage else { lock.unlock(); return }
        let profile = latestCharacter == nil ? nil : latestAdjustment.development
        guard latestCharacter == nil || awaitedProfile == nil || awaitedProfile == profile else { lock.unlock(); return }
        let epoch = generation
        if !isDeveloping && (submittedVersion != frameVersion || (proof != nil && proof?.target != target)) {
            let version = frameVersion
            let dimension = awaitedProfile == nil ? proofDimension : 480
            isDeveloping = true
            submittedVersion = version
            renderQueue.async { [self] in
                develop(image, profile: profile, version: version, target: target, dimension: dimension, epoch: epoch)
            }
        }
        let adjustment = latestAdjustment
        guard !isPresenting, let proof, proof.profile == profile, proof.target == target,
              presentedVersion != proof.version || presentedAdjustment != adjustment else { lock.unlock(); return }
        isPresenting = true
        lock.unlock()

        guard let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else {
            lock.withLock { isPresenting = false }
            return
        }
        displayQueue.async { [self] in
            do {
                let graded = try proof.negative.map {
                    try FilmColorPipeline.adjust(negative: $0, source: proof.source, recipe: adjustment)
                } ?? proof.source
                let output = graded.transformed(by: CGAffineTransform(scaleX: 1 / proof.scale, y: 1 / proof.scale))
                context.render(output, to: drawable.texture, commandBuffer: commandBuffer,
                               bounds: CGRect(origin: .zero, size: target), colorSpace: colorSpace)
                guard lock.withLock({ generation == epoch }) else {
                    lock.withLock { isPresenting = false }
                    return
                }
                commandBuffer.present(drawable)
                commandBuffer.addCompletedHandler { [self] completed in
                    let success = completed.status == .completed
                    let reveal = lock.withLock { () -> (@Sendable () -> Void)? in
                        isPresenting = false
                        guard generation == epoch, success else { return nil }
                        presentedVersion = proof.version
                        presentedAdjustment = adjustment
                        if freezesAfterNextRender { isFrozen = true; freezesAfterNextRender = false }
                        defer { pendingReveal = nil }
                        return pendingReveal
                    }
                    finishProfile(profile, generation: epoch, success: success)
                    reveal?()
                }
                commandBuffer.commit()
            } catch {
                lock.withLock { isPresenting = false }
                finishProfile(profile, generation: epoch, success: false)
            }
        }
    }

    private func develop(_ image: CIImage, profile: FilmDevelopment?, version: UInt64, target: CGSize,
                         dimension: CGFloat, epoch: UInt64) {
        let started = CACurrentMediaTime()
        let scale = profile == nil ? 1 : min(1, dimension / max(target.width, target.height))
        let source = aspectFill(image, into: CGRect(x: 0, y: 0, width: target.width * scale, height: target.height * scale))
        do {
            let negative = try profile.map { try FotufilmRenderer.shared.process(source, development: $0, realtime: true) }
            lock.withLock {
                isDeveloping = false
                guard generation == epoch else { return }
                proof = Proof(source: source, negative: negative, profile: profile, version: version, target: target, scale: scale)
                // Adapt only the live proof. Bound changes to avoid oscillating after a slow frame.
                if profile != nil, awaitedProfile == nil {
                    let elapsed = CACurrentMediaTime() - started
                    if elapsed > 0.06 { proofDimension = max(384, dimension * 0.85) }
                    else if elapsed < 0.025 { proofDimension = min(960, dimension * 1.08) }
                }
            }
        } catch {
            lock.withLock { isDeveloping = false }
            finishProfile(profile, generation: epoch, success: false)
        }
    }

    private func finishProfile(_ profile: FilmDevelopment?, generation epoch: UInt64, success: Bool) {
        guard let profile else { return }
        let notify = lock.withLock {
            guard generation == epoch else { return false }
            let waiting = awaitedProfile == profile
            let report = waiting || (!success && !reportedDevelopmentFailure)
            if waiting { awaitedProfile = nil }
            reportedDevelopmentFailure = !success
            return report
        }
        if notify { onProfileResult?(profile, success) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func aspectFill(_ image: CIImage, into target: CGRect) -> CIImage {
        let crop = CameraImageRenderer.cropBounds(image.extent, to: target.width / target.height)
        let cropped = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        return cropped.transformed(by: CGAffineTransform(
            scaleX: target.width / crop.width,
            y: target.height / crop.height
        ))
    }
}

struct CameraMetalPreview: UIViewRepresentable {
    let renderer: CameraPreviewRenderer
    let isActive: Bool
    let onPreviewLayerReady: (CALayer) -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        renderer.configure(view)
        onPreviewLayerReady(view.layer)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.isPaused = !isActive
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        uiView.isPaused = true
        uiView.delegate = nil
    }
}
