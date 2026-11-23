// SPDX-License-Identifier: MPL-2.0
@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO

nonisolated enum HPan {
    static let landscapeRatio: CGFloat = 65.0 / 24.0
    static let portraitRatio = 1 / landscapeRatio

    enum Orientation: Int {
        case upright = 0
        case landscapeLeft = 90
        case landscapeRight = -90

        var isLandscape: Bool { self != .upright }

        init(captureAngle: CGFloat, portraitAngle: CGFloat) {
            switch HPan.quarterTurns(portraitAngle - captureAngle) {
            case 1: self = .landscapeLeft
            case 3: self = .landscapeRight
            default: self = .upright
            }
        }

        func captureAngle(relativeTo portraitAngle: CGFloat) -> CGFloat {
            CGFloat(HPan.quarterTurns(portraitAngle - CGFloat(rawValue)) * 90)
        }
    }

    // The app's fixed portrait coordinate system turns this tall frame into
    // a horizontal panoramic window when the photographer rotates the phone.
    static func finder(in area: CGRect) -> CGRect {
        let height = max(1, min(area.height, area.width / portraitRatio))
        let width = height * portraitRatio
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    static func orientationCorrection(desired: CGFloat, applied: CGFloat) -> CGImagePropertyOrientation {
        switch quarterTurns(desired - applied) {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
    }

    private static func quarterTurns(_ degrees: CGFloat) -> Int {
        guard degrees.isFinite else { return 0 }
        let turns = Int((degrees.truncatingRemainder(dividingBy: 360) / 90).rounded())
        return (turns + 4) % 4
    }

    static func pixels(_ size: CMVideoDimensions) -> Int64 {
        Int64(size.width) * Int64(size.height)
    }
}

// Called only on the session queue. Preserve the exact camera configuration,
// including a RAW or Live Photo setup, across a temporary panoramic session.
nonisolated struct HPanConfiguration {
    enum Failure: LocalizedError {
        case lens, format, connection
        var errorDescription: String? {
            switch self {
            case .lens: LanguageManager.text("HPan0.5 requires a rear Ultra Wide camera.")
            case .format: LanguageManager.text("A full-resolution Ultra Wide photo format is unavailable.")
            case .connection: LanguageManager.text("The camera could not switch shooting modes.")
            }
        }
    }

    let input: AVCaptureDeviceInput
    let format: AVCaptureDevice.Format
    let preset: AVCaptureSession.Preset
    let zoom: CGFloat
    let dimensions: CMVideoDimensions
    let live: Bool
    let liveTrimming: Bool
    let proRAW: Bool

    init(current input: AVCaptureDeviceInput, session: AVCaptureSession, output: AVCapturePhotoOutput) {
        self.input = input
        format = input.device.activeFormat
        preset = session.sessionPreset
        zoom = input.device.videoZoomFactor
        dimensions = output.maxPhotoDimensions
        live = output.isLivePhotoCaptureEnabled
        liveTrimming = output.isLivePhotoAutoTrimmingEnabled
        proRAW = output.isAppleProRAWEnabled
    }

    init(ultraWide device: AVCaptureDevice, existing: AVCaptureDeviceInput) throws {
        guard device.deviceType == .builtInUltraWideCamera && device.position == .back else { throw Failure.lens }
        input = device == existing.device ? existing : try AVCaptureDeviceInput(device: device)
        // Prefer the current format on an equal-resolution, equal-field-of-view tie.
        var best: (AVCaptureDevice.Format, CMVideoDimensions)?
        for candidate in [device.activeFormat] + device.formats {
            guard !candidate.unsupportedCaptureOutputClasses.contains(where: {
                $0 == AVCapturePhotoOutput.self || $0 == AVCaptureVideoDataOutput.self
            }), let largest = candidate.supportedMaxPhotoDimensions.max(by: { HPan.pixels($0) < HPan.pixels($1) }),
                HPan.pixels(largest) > 0 else { continue }
            if let best, HPan.pixels(largest) < HPan.pixels(best.1) ||
                (HPan.pixels(largest) == HPan.pixels(best.1) && candidate.videoFieldOfView <= best.0.videoFieldOfView) { continue }
            best = (candidate, largest)
        }
        guard let best else { throw Failure.format }
        format = best.0
        dimensions = best.1
        preset = .inputPriority
        zoom = 1
        live = false
        liveTrimming = false
        proRAW = false
    }

    func apply(in session: AVCaptureSession, output: AVCapturePhotoOutput) throws {
        let device = input.device
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        output.isLivePhotoAutoTrimmingEnabled = false
        if output.isLivePhotoCaptureEnabled { output.isLivePhotoCaptureEnabled = false }
        if output.isAppleProRAWEnabled { output.isAppleProRAWEnabled = false }
        if !session.inputs.contains(input) {
            for case let old as AVCaptureDeviceInput in session.inputs where old.device.hasMediaType(.video) {
                session.removeInput(old)
            }
            guard session.canAddInput(input) else { throw Failure.connection }
            session.addInput(input)
        }
        if device.activeFormat != format || (preset == .inputPriority && session.sessionPreset != preset) {
            device.activeFormat = format
        }
        if session.sessionPreset != preset {
            guard session.canSetSessionPreset(preset) else { throw Failure.format }
            session.sessionPreset = preset
        }
        guard device.activeFormat.supportedMaxPhotoDimensions.contains(where: {
            $0.width == dimensions.width && $0.height == dimensions.height
        }), device.minAvailableVideoZoomFactor <= zoom, zoom <= device.maxAvailableVideoZoomFactor else { throw Failure.format }
        device.videoZoomFactor = zoom
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if proRAW && output.isAppleProRAWSupported { output.isAppleProRAWEnabled = true }
        output.maxPhotoDimensions = dimensions
        if live && output.isLivePhotoCaptureSupported {
            output.isLivePhotoCaptureEnabled = true
            output.isLivePhotoAutoTrimmingEnabled = liveTrimming
        }
    }
}
