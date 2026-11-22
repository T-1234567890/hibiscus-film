// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus iOS camera.
@preconcurrency import AVFoundation
import Combine
import CoreImage
import Metal
import Photos
import SwiftUI
import UIKit

enum CameraAuthorizationState {
    case unknown
    case authorized
    case denied
    case unavailable
}

nonisolated struct CameraLensOption: Identifiable, Equatable, Sendable {
    let factor: Double
    let label: String

    var id: String { label }
}

nonisolated private struct CameraLensTarget {
    let displayFactor: CGFloat
    let device: AVCaptureDevice
    let deviceZoomFactor: CGFloat
}

private nonisolated enum DoubleExposureCapture: Sendable {
    case off
    case first
    case second(Data)
}

@MainActor
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var hpanEnabled = false {
        didSet {
            if hpanEnabled { clearDoubleExposureMode() }
            else if hpanOrientation != .upright { hpanOrientation = .upright }
        }
    }
    @Published private(set) var changingMode = false
    @Published private(set) var hpanOrientation = HPan.Orientation.upright
    let hasUltraWide: Bool
    var shutterReady: Bool {
        sessionRequested && isRunning && !changingMode && !isSwitchingCamera && !isCapturing && !isConfiguringLivePhoto &&
            !isProcessingCapture && (hpanEnabled ? hpanOrientation.isLandscape : pendingCaptureFormat == nil)
    }
    // Saved and restored only on sessionQueue.
    nonisolated(unsafe) private var beforeHPan: HPanConfiguration?
    nonisolated(unsafe) private var captureIsHPan = false
    nonisolated(unsafe) private var captureHPanCorrection = CGImagePropertyOrientation.up
    nonisolated(unsafe) private var pendingHPanOriginal: Data?
    private var captureRotationObservation: NSKeyValueObservation?
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var capturedPreviewImage: UIImage?
    @Published private(set) var capturedHasMotion = false
    @Published private(set) var capturedLivePhoto: ProcessedLivePhoto?
    @Published private(set) var capturedDate: Date?
    @Published private(set) var authorizationState: CameraAuthorizationState = .unknown
    @Published private(set) var isRunning = false
    @Published private(set) var sceneAccent = AccentRGB.neutralGray
    nonisolated private let accentSampler: LiveAccentSampler
    // Written on the main actor inside videoQueue.sync, read only on those two contexts.
    nonisolated(unsafe) private var accentGeneration: UUID?
    @Published private(set) var flashAvailable = false
    @Published var flashMode: CaptureFlashMode = .off
    @Published private var displayZoom: CGFloat = 1
    var lensLabel: String { formatLens(displayZoom) }
    @Published private(set) var lensOptions = [CameraLensOption(factor: 1, label: "1×")]
    @Published private(set) var exposureRange = -2.0...2.0
    @Published private(set) var exposure: Double = 0
    @Published private(set) var isSwitchingCamera = false
    @Published private(set) var framingRatio = CameraAspectRatio.standard
    var selectedRatio: CameraAspectRatio { hpanEnabled ? .hpan : framingRatio }
    @Published private(set) var doubleExposureEnabled = false
    @Published private var firstExposure: Data?
    var awaitingSecondExposure: Bool { firstExposure != nil }
    var canUseDoubleExposure: Bool {
        !hpanEnabled && !changingMode && !isConfiguringLivePhoto && selectedMotion == .photo && selectedFormat == .processed
    }
    @Published var selectedMotion: CaptureMotionOption = .photo {
        didSet {
            requestsLivePhoto = selectedMotion == .livePhoto
            if requestsLivePhoto { clearDoubleExposureMode() }
        }
    }
    @Published private(set) var isLivePhotoAvailable = false
    @Published private(set) var isConfiguringLivePhoto = false
    @Published private(set) var availableMegapixels: [Int] = [12]
    @Published private(set) var availableRawMegapixels: [Int] = []
    @Published private(set) var selectedMegapixels = 12
    @Published var selectedFormat: CaptureFormatOption = .processed {
        didSet {
            captureFormat = selectedFormat
            if selectedFormat == .raw { clearDoubleExposureMode() }
        }
    }
    @Published private(set) var isRAWAvailable = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecordingLivePhoto = false
    @Published private(set) var isProcessingCapture = false
    static let defaultAutoSave = true
    static let autoSaveKey = "automaticallySaveCameraPhotos"
    private var autoSavePending: CameraAutoSaveFormat?
    @Published private(set) var savedVariants: Set<CameraExportVariant> = []
    private var originalSaved = false
    @Published private(set) var isSavingCapture = false
    @Published var statusMessage: String?
    @Published private(set) var loadingFilm = false
    private var requestedProfileID: String?

    nonisolated let previewRenderer: CameraPreviewRenderer
    nonisolated(unsafe) private let session: AVCaptureSession
    nonisolated(unsafe) private let photoOutput: AVCapturePhotoOutput
    nonisolated(unsafe) private let videoOutput: AVCaptureVideoDataOutput
    nonisolated private let sessionQueue = DispatchQueue(label: "dev.hibiscus.camera-session", qos: .userInitiated)
    nonisolated private let videoQueue = DispatchQueue(label: "dev.hibiscus.camera-preview", qos: .userInteractive)
    nonisolated private let photoProcessingQueue = DispatchQueue(label: "dev.hibiscus.camera-processing", qos: .userInitiated)
    nonisolated(unsafe) private var cameraInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var audioInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var renderCharacter: OriginalStyle? = nil
    nonisolated(unsafe) private var renderCharacterAdjustment = Recipe()
    nonisolated(unsafe) private var renderFrameStock = FilmFrame.StockMark(name: "Hibiscus", swatch: nil)
    nonisolated(unsafe) private var captureFormat: CaptureFormatOption = .processed
    nonisolated(unsafe) private var requestsLivePhoto = false
    nonisolated(unsafe) private var livePhotoResolutionLimited = false
    nonisolated private let resolutionLock = NSLock()
    nonisolated(unsafe) private var supportedPhotoDimensions: [CMVideoDimensions] = []
    nonisolated(unsafe) private var capturePhotoDimensions = CMVideoDimensions(width: 0, height: 0)
    nonisolated(unsafe) private var captureTargetMegapixels = 12
    nonisolated(unsafe) private var requestedPhotoMegapixels: Int?
    private var lastCaptureResolutionPreference: CaptureResolution?
    private var lastCaptureFormatPreference: CaptureFormatOption?
    @Published private var pendingCaptureFormat: CaptureFormatOption?
    nonisolated(unsafe) private var doubleExposureCapture = DoubleExposureCapture.off
    nonisolated(unsafe) private var pendingFirstExposure: Data?
    nonisolated(unsafe) private var pendingProcessedImage: UIImage?
    nonisolated(unsafe) private var pendingPreviewImage: UIImage?
    nonisolated(unsafe) private var pendingRawData: Data?
    nonisolated(unsafe) private var captureRequiresRAW = false
    nonisolated(unsafe) private var captureDeliveryComplete = false
    nonisolated(unsafe) private var pendingLivePhotoData: Data?
    nonisolated(unsafe) private var pendingLivePhotoMovieURL: URL?
    nonisolated(unsafe) private var pendingLivePhotoDisplayTime: CMTime?
    nonisolated(unsafe) private var captureUsesLivePhoto = false
    nonisolated(unsafe) private var captureCharacter: OriginalStyle? = nil
    nonisolated(unsafe) private var captureCharacterAdjustment = Recipe()
    private var captureFrameStock = FilmFrame.StockMark(name: "Hibiscus", swatch: nil)
    nonisolated(unsafe) private var captureLiveAspectRatio = CameraAspectRatio.standard.portraitRatio
    nonisolated(unsafe) private var captureLiveTargetMegapixels = 12
    nonisolated(unsafe) private var captureProcessingToken = UUID()
    nonisolated(unsafe) private var acceptsPreviewFrames = true
    nonisolated(unsafe) private var pendingCameraSwitchToken: UUID?
    nonisolated(unsafe) private var currentPreviewRotationAngle: CGFloat = 90
    private var previewLayer: CALayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var cameraSwitchRecoveryTask: Task<Void, Never>?
    private var sessionRequested = false
    private var wantsLivePhoto = false
    private var locksFocus = false
    private var shouldApplyDefaultMotionOnStart = false
    @concurrent static func prepare() async -> CameraService? {
        guard let renderer = CameraPreviewRenderer(device: MTLCreateSystemDefaultDevice()) else { return nil }
        let accentSampler = LiveAccentSampler()
        let session = AVCaptureSession()
        let photoOutput = AVCapturePhotoOutput()
        let videoOutput = AVCaptureVideoDataOutput()
        let hasUltraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        return await CameraService(renderer: renderer, accentSampler: accentSampler, session: session, photoOutput: photoOutput,
                                   videoOutput: videoOutput, hasUltraWide: hasUltraWide, authorization: authorization)
    }

    private init(renderer: CameraPreviewRenderer, accentSampler: LiveAccentSampler, session: AVCaptureSession, photoOutput: AVCapturePhotoOutput,
                 videoOutput: AVCaptureVideoDataOutput, hasUltraWide: Bool, authorization: AVAuthorizationStatus) {
        self.accentSampler = accentSampler
        self.previewRenderer = renderer
        self.session = session
        self.photoOutput = photoOutput
        self.videoOutput = videoOutput
        self.hasUltraWide = hasUltraWide
        super.init()
        previewRenderer.onProfileResult = { [weak self] id, success in
            guard let service = self else { return }
            Task { @MainActor in
                guard service.requestedProfileID == id else { return }
                service.loadingFilm = false
                if !success { service.statusMessage = LanguageManager.text("The selected film could not be developed for preview.") }
            }
        }
        switch authorization {
        case .authorized: authorizationState = .authorized
        case .denied, .restricted: authorizationState = .denied
        case .notDetermined: authorizationState = .unknown
        @unknown default: authorizationState = .denied
        }
    }

    func updateProfile(stock: Stock, recipe: Recipe) {
        if let id = recipe.fotufilmID, id != requestedProfileID {
            requestedProfileID = id
            loadingFilm = true
            previewRenderer.awaitFirstFrame(for: id)
        }
        let accent = recipe.usesSceneAccent ? sceneAccent : nil
        let mark = stock.filmFrameMark
        videoQueue.async { [self] in
            renderCharacter = stock.style
            renderFrameStock = mark
            renderCharacterAdjustment = recipe
            renderCharacterAdjustment.sceneColor = accent
            previewRenderer.updateAdjustment(renderCharacterAdjustment)
        }
    }

    func start(live: Bool, lockFocus: Bool) {
        startAccentSampling()
        sessionRequested = true
        wantsLivePhoto = live
        locksFocus = lockFocus
        previewRenderer.resume()
        shouldApplyDefaultMotionOnStart = true
        checkCapturePreferences()
        capturedHasMotion = false
        capturedImage = nil
        capturedPreviewImage = nil
        capturedLivePhoto?.cleanUp()
        capturedLivePhoto = nil
        capturedDate = nil
        isSavingCapture = false
        if cameraInput != nil { applyFocus(); setExposure(exposure) }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorizationState = .authorized
        case .denied, .restricted: authorizationState = .denied
        case .notDetermined: authorizationState = .unknown
        @unknown default: authorizationState = .denied
        }
        switch authorizationState {
        case .authorized:
            configureAndStartIfNeeded()
        case .unknown:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let service = self else { return }
                Task { @MainActor in
                    service.authorizationState = granted ? .authorized : .denied
                    if granted && service.sessionRequested { service.configureAndStartIfNeeded() }
                }
            }
        case .denied, .unavailable:
            break
        }
    }

    private func startAccentSampling() {
        guard accentGeneration == nil else { return }
        videoQueue.sync { accentGeneration = UUID() }
    }

    func stop() {
        videoQueue.sync { accentGeneration = nil }
        sessionRequested = false
        cameraSwitchRecoveryTask?.cancel()
        cameraSwitchRecoveryTask = nil
        isSwitchingCamera = false
        if firstExposure != nil { firstExposure = nil }
        previewRenderer.clear()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Task { @MainActor in self.isRunning = false }
        }
    }

    func setDoubleExposure(_ enabled: Bool) {
        guard !isCapturing, !isProcessingCapture else { return }
        if enabled {
            guard canUseDoubleExposure else { return }
            doubleExposureEnabled = true
        } else {
            clearDoubleExposureMode()
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func clearDoubleExposureMode() {
        if doubleExposureEnabled { doubleExposureEnabled = false }
        if firstExposure != nil { firstExposure = nil }
    }

    func capture() {
        guard shutterReady else { return }
        guard let connection = photoOutput.connection(with: .video) else { return }
        var captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        var panoramaCorrection = CGImagePropertyOrientation.up
        if hpanEnabled {
            guard let device = cameraInput?.device, device.deviceType == .builtInUltraWideCamera,
                  abs(device.videoZoomFactor - 1) < 0.001, let coordinator = rotationCoordinator else { return }
            let portrait = portraitAngle(coordinator)
            let orientation = HPan.Orientation(captureAngle: captureAngle, portraitAngle: portrait)
            if hpanOrientation != orientation { hpanOrientation = orientation }
            guard orientation.isLandscape else {
                statusMessage = LanguageManager.text("Hold the iPhone horizontally to capture HPan0.5.")
                return
            }
            let desired = orientation.captureAngle(relativeTo: portrait)
            captureAngle = connection.isVideoRotationAngleSupported(desired) ? desired : connection.videoRotationAngle
            panoramaCorrection = HPan.orientationCorrection(desired: desired, applied: captureAngle)
        }
        captureIsHPan = hpanEnabled
        captureHPanCorrection = panoramaCorrection
        let shootingRAW = !captureIsHPan && captureFormat == .raw
        if shootingRAW, photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            statusMessage = LanguageManager.text("RAW capture failed. Please retake the photo.")
            return
        }
        captureRequiresRAW = shootingRAW
        captureDeliveryComplete = false
        if !captureIsHPan, selectedMotion == .livePhoto,
           !photoOutput.isLivePhotoCaptureEnabled || photoOutput.isLivePhotoCaptureSuspended {
            // Never silently flatten a requested Live Photo into a still.
            isLivePhotoAvailable = false
            statusMessage = LanguageManager.text("Live Photo isn’t available with the current camera configuration.")
            return
        }
        let recordsLivePhoto = !captureIsHPan && selectedMotion == .livePhoto
            && captureFormat == .processed
            && photoOutput.isLivePhotoCaptureEnabled
        // A still freezes at shutter time. A Live Photo must keep presenting fresh
        // preview frames until AVFoundation reports that motion recording ended.
        if recordsLivePhoto {
            isRecordingLivePhoto = true
            previewRenderer.resume()
        } else {
            isRecordingLivePhoto = false
            previewRenderer.freeze()
        }
        if doubleExposureEnabled && canUseDoubleExposure {
            doubleExposureCapture = firstExposure.map(DoubleExposureCapture.second) ?? .first
        } else {
            doubleExposureCapture = .off
        }
        pendingFirstExposure = nil
        let defaults = UserDefaults.standard
        let saveFormat = defaults.string(forKey: CameraAutoSaveFormat.preferenceKey)
            .flatMap(CameraAutoSaveFormat.init(rawValue:)) ?? .photo
        autoSavePending = defaults.bool(forKey: Self.autoSaveKey) ? saveFormat : nil
        savedVariants = []
        originalSaved = false
        isCapturing = true
        isProcessingCapture = true
        capturedDate = Date()
        pendingProcessedImage = nil
        pendingPreviewImage = nil
        pendingHPanOriginal = nil
        pendingRawData = nil
        pendingLivePhotoData = nil
        if let pendingLivePhotoMovieURL { try? FileManager.default.removeItem(at: pendingLivePhotoMovieURL) }
        pendingLivePhotoMovieURL = nil
        pendingLivePhotoDisplayTime = nil
        captureUsesLivePhoto = recordsLivePhoto
        capturedHasMotion = recordsLivePhoto
        captureProcessingToken = UUID()
        isSavingCapture = false

        let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let processedFormat: [String: Any] = [AVVideoCodecKey: codec]
        let settings: AVCapturePhotoSettings
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let preferredRawType = rawTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) ?? rawTypes.first
        if shootingRAW, let rawType = preferredRawType {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processedFormat)
            if AVCapturePhotoOutput.isBayerRAWPixelFormat(rawType) {
                // Full-sensor RAW requires the physical lens at its native zoom.
                // AVFoundation requires speed prioritization for Bayer RAW.
                settings.photoQualityPrioritization = .speed
                if let device = cameraInput?.device, device.videoZoomFactor != 1 {
                    do {
                        try device.lockForConfiguration()
                        device.videoZoomFactor = 1
                        device.unlockForConfiguration()
                    } catch { }
                }
            } else {
                settings.photoQualityPrioritization = .quality
            }
        } else {
            settings = AVCapturePhotoSettings(format: processedFormat)
            settings.photoQualityPrioritization = .quality
        }
        (captureCharacter, captureCharacterAdjustment, captureFrameStock) = videoQueue.sync {
            (renderCharacter, renderCharacterAdjustment, renderFrameStock)
        }
        captureLiveAspectRatio = selectedRatio.portraitRatio
        captureLiveTargetMegapixels = selectedTargetMegapixels()
        if captureUsesLivePhoto {
            let movieURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Hibiscus-Live-Capture-\(UUID().uuidString).mov")
            pendingLivePhotoMovieURL = movieURL
            settings.livePhotoMovieFileURL = movieURL
        }
        let photoDimensions = captureIsHPan ? photoOutput.maxPhotoDimensions : selectedPhotoDimensions()
        if photoDimensions.width > 0, photoDimensions.height > 0 {
            settings.maxPhotoDimensions = photoDimensions
        }
        if flashAvailable {
            let requestedFlash: AVCaptureDevice.FlashMode = !captureIsHPan && flashMode == .on ? .on : .off
            if photoOutput.supportedFlashModes.contains(requestedFlash) { settings.flashMode = requestedFlash }
        }
        if connection.isVideoRotationAngleSupported(captureAngle) {
            connection.videoRotationAngle = captureAngle
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
    }

    func retake(lockFocus: Bool) {
        startAccentSampling()
        sessionRequested = true
        locksFocus = lockFocus
        applyFocus()
        setExposure(exposure)
        if !hpanEnabled, let capturedPreviewImage,
           let heldImage = CameraImageRenderer.sourceCIImage(capturedPreviewImage) {
            previewRenderer.hold(heldImage)
        } else {
            previewRenderer.freeze()
        }
        beginPreviewTransition()
        capturedImage = nil
        capturedPreviewImage = nil
        capturedLivePhoto?.cleanUp()
        capturedLivePhoto = nil
        capturedDate = nil
        checkCapturePreferences()
        pendingProcessedImage = nil
        pendingPreviewImage = nil
        pendingHPanOriginal = nil
        pendingRawData = nil
        pendingLivePhotoData = nil
        if let pendingLivePhotoMovieURL { try? FileManager.default.removeItem(at: pendingLivePhotoMovieURL) }
        pendingLivePhotoMovieURL = nil
        pendingLivePhotoDisplayTime = nil
        captureUsesLivePhoto = false
        capturedHasMotion = false
        isRecordingLivePhoto = false
        isProcessingCapture = false
        isSavingCapture = false
        captureProcessingToken = UUID()
        statusMessage = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let device = self.cameraInput?.device {
                self.configureVideoConnectionFallback(for: device)
            }
            self.startSessionOnlyFromQueue()
            if self.beforeHPan == nil, self.session.isRunning {
                self.refreshRAWAvailability(applyDefaults: true)
            }
        }
    }

    @discardableResult
    private func beginPreviewTransition() -> UUID {
        let resumeToken = UUID()
        videoQueue.sync {
            acceptsPreviewFrames = false
            pendingCameraSwitchToken = resumeToken
        }
        isSwitchingCamera = true
        cameraSwitchRecoveryTask?.cancel()
        cameraSwitchRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.recoverCameraSwitchIfNeeded(token: resumeToken)
        }
        return resumeToken
    }

    private func applyFocus() {
        guard let device = cameraInput?.device else { return }
        let mode: AVCaptureDevice.FocusMode = locksFocus ? .locked : .continuousAutoFocus
        guard device.isFocusModeSupported(mode), (try? device.lockForConfiguration()) != nil else { return }
        device.focusMode = mode
        device.unlockForConfiguration()
    }

    func restoreFramingRatio(_ ratio: CameraAspectRatio) {
        if ratio != .hpan { framingRatio = ratio }
    }

    func selectRatio(_ ratio: CameraAspectRatio) {
        guard ratio != selectedRatio, !changingMode, !isSwitchingCamera, !isCapturing,
              !isProcessingCapture, !isConfiguringLivePhoto else { return }
        let enable = ratio == .hpan
        if !enable && !hpanEnabled {
            framingRatio = ratio
            return
        }
        guard isRunning, sessionRequested, !enable || hasUltraWide else { return }
        changingMode = true
        previewRenderer.freeze()
        sessionQueue.async { [self] in
            do {
                guard let input = cameraInput else { throw HPanConfiguration.Failure.connection }
                let previous = HPanConfiguration(current: input, session: session, output: photoOutput)
                let target: HPanConfiguration
                if enable {
                    guard let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                    else { throw HPanConfiguration.Failure.lens }
                    target = try HPanConfiguration(ultraWide: ultra, existing: input)
                } else {
                    guard let saved = beforeHPan else { throw HPanConfiguration.Failure.connection }
                    target = saved
                }
                session.beginConfiguration()
                do {
                    try target.apply(in: session, output: photoOutput)
                } catch {
                    do {
                        try previous.apply(in: session, output: photoOutput)
                        configureCameraControls(for: previous.input.device, panoramic: beforeHPan != nil)
                    } catch {
                        session.commitConfiguration()
                        session.stopRunning()
                        Task { @MainActor in self.isRunning = false }
                        throw error
                    }
                    session.commitConfiguration()
                    throw error
                }
                cameraInput = target.input
                beforeHPan = enable ? previous : nil
                configureCameraControls(for: target.input.device, panoramic: enable)
                session.commitConfiguration()
                Task { @MainActor in
                    if !enable { self.framingRatio = ratio }
                    self.hpanEnabled = enable
                    self.flashAvailable = target.input.device.hasFlash
                    let switchToken = self.beginPreviewTransition()
                    self.configureRotationCoordinator(for: target.input.device, switchToken: switchToken)
                    self.applyFocus()
                    self.setExposure(self.exposure)
                    self.changingMode = false
                    if !enable { self.applyCameraDefaultsIfNeeded() }
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    self.changingMode = false
                    if let device = self.cameraInput?.device { self.configureRotationCoordinator(for: device) }
                    self.previewRenderer.resume()
                    self.statusMessage = message
                }
            }
        }
    }

    func selectLens(_ option: CameraLensOption) {
        guard !hpanEnabled, !changingMode, !isCapturing, !isConfiguringLivePhoto, !isSwitchingCamera else { return }
        displayZoom = CGFloat(option.factor)
        sessionQueue.async { [weak self] in
            self?.selectRearLens(displayFactor: CGFloat(option.factor))
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func selectNextLens() {
        guard let first = lensOptions.first else { return }
        let next = lensOptions.first { $0.factor > Double(displayZoom) + 0.025 }
        selectLens(next ?? first)
    }

    func setExposure(_ value: Double) {
        guard let device = cameraInput?.device else {
            exposure = min(2, max(-2, value))
            return
        }
        let supported = Self.exposureLimits(for: device)
        let minimum = supported.lowerBound
        let maximum = supported.upperBound
        if exposureRange != supported { exposureRange = supported }
        exposure = min(maximum, max(minimum, value))

        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(Float(exposure))
            device.unlockForConfiguration()
        } catch {
            statusMessage = LanguageManager.text("Exposure adjustment isn’t available.")
        }
    }

    nonisolated private static func exposureLimits(for device: AVCaptureDevice) -> ClosedRange<Double> {
        if let range = device.activeFormat.systemRecommendedExposureBiasRange {
            return Double(range.lowerBound)...Double(range.upperBound)
        }
        return max(-2, Double(device.minExposureTargetBias))...min(2, Double(device.maxExposureTargetBias))
    }

    // Called on sessionQueue inside the input configuration transaction.
    nonisolated private func configureCameraControls(for device: AVCaptureDevice, panoramic: Bool) {
        guard session.supportsControls else { return }
        session.setControlsDelegate(self, queue: sessionQueue)
        for control in session.controls { session.removeControl(control) }
        if !panoramic, device.maxAvailableVideoZoomFactor > device.minAvailableVideoZoomFactor {
            let base = nativeDisplayFactor(for: device)
            let zoom = AVCaptureSystemZoomSlider(device: device) { [weak self] factor in
                guard let self, self.cameraInput?.device === device, !self.hpanEnabled else { return }
                self.displayZoom = base * factor
            }
            if session.canAddControl(zoom) { session.addControl(zoom) }
        }
        if device.maxExposureTargetBias > device.minExposureTargetBias {
            let bias = AVCaptureSystemExposureBiasSlider(device: device) { [weak self] value in
                guard let self, self.cameraInput?.device === device else { return }
                self.exposure = Double(value)
            }
            if session.canAddControl(bias) { session.addControl(bias) }
        }
    }

    func attachPreviewLayer(_ layer: CALayer) {
        let layerChanged = previewLayer !== layer
        previewLayer = layer
        guard layerChanged || pendingCameraSwitchToken != nil else { return }
        // makeUIView attaches the layer during a SwiftUI update. Configure on the next
        // main-actor turn because the rotation coordinator publishes HPan state.
        Task { @MainActor [weak self, weak layer] in
            guard let self, let layer, previewLayer === layer, let device = cameraInput?.device else { return }
            configureRotationCoordinator(for: device, switchToken: pendingCameraSwitchToken)
        }
    }

    func selectCapture(format: CaptureFormatOption, megapixels: Int, isDefault: Bool = false) {
        guard !hpanEnabled, !changingMode, !isCapturing, !isConfiguringLivePhoto else { return }
        guard format == .processed || isRAWAvailable else { return }
        // Compatibility recovery can temporarily disable ProRAW. Restore it
        // before accepting a RAW selection, not during capability discovery.
        if livePhotoResolutionLimited || (format == .raw && (selectedMotion == .livePhoto ||
            (photoOutput.isAppleProRAWSupported && !photoOutput.isAppleProRAWEnabled))) {
            isConfiguringLivePhoto = true
            selectedMotion = .photo
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let wasRunning = self.session.isRunning
                if wasRunning { self.session.stopRunning() }
                self.session.beginConfiguration()
                self.photoOutput.isLivePhotoCaptureEnabled = false
                if format == .raw { self.enableAppleProRAWIfSupported() }
                self.session.commitConfiguration()
                self.livePhotoResolutionLimited = false
                if let device = self.cameraInput?.device {
                    self.updatePhotoResolutionCapabilities(for: device)
                }
                self.refreshRAWAvailability()
                if wasRunning { self.session.startRunning() }
                Task { @MainActor in
                    self.isLivePhotoAvailable = false
                    self.isConfiguringLivePhoto = false
                    if format == .processed || !self.photoOutput.isAppleProRAWSupported
                        || self.photoOutput.isAppleProRAWEnabled {
                        self.selectCapture(format: format, megapixels: megapixels, isDefault: isDefault)
                    } else if isDefault {
                        self.selectedFormat = .processed
                        self.applyPreferredResolution()
                        self.statusMessage = LanguageManager.text("RAW capture is unavailable on this camera. Using HEIF.")
                    }
                    if isDefault || self.pendingCaptureFormat != nil { self.applyCameraDefaultsIfNeeded() }
                }
            }
            return
        }
        resolutionLock.lock()
        let hasNativeTarget = supportedPhotoDimensions.contains {
            Self.megapixels(for: $0) == megapixels
        }
        let selected: CMVideoDimensions?
        if format == .processed, megapixels == 24, !hasNativeTarget {
            // Some devices expose 12 MP and 48 MP capture dimensions but no
            // native 24 MP request. Capture the smallest valid higher source
            // and let the existing final renderer produce the 24 MP result.
            selected = supportedPhotoDimensions.first {
                Self.megapixels(for: $0) > megapixels
            }
        } else {
            selected = supportedPhotoDimensions.min {
                abs(Self.megapixels(for: $0) - megapixels) < abs(Self.megapixels(for: $1) - megapixels)
            }
        }
        if let selected { capturePhotoDimensions = selected }
        captureTargetMegapixels = megapixels
        requestedPhotoMegapixels = isDefault ? nil : megapixels
        resolutionLock.unlock()
        selectedFormat = format
        selectedMegapixels = megapixels
        if format == .raw { selectedMotion = .photo }
#if DEBUG
        sessionQueue.async { [weak self] in
            self?.debugLogCameraConfiguration(context: "resolution selected")
        }
#endif
        if !isDefault { UISelectionFeedbackGenerator().selectionChanged() }
    }

    func selectMotion(_ option: CaptureMotionOption) {
        guard selectedFormat == .processed || option == .photo else { return }
        guard !hpanEnabled, !changingMode, !isConfiguringLivePhoto, !isCapturing, !isSwitchingCamera else { return }
        if option == .photo {
            selectedMotion = .photo
            if livePhotoResolutionLimited {
                var options = cameraInput?.device.activeFormat.supportedMaxPhotoDimensions.map(Self.megapixels(for:))
                    ?? availableMegapixels
                if options.contains(where: { $0 > 24 }) { options.append(24) }
                let previousRequest = resolutionLock.withLock { requestedPhotoMegapixels }
                if let preferred = CaptureResolution.preferred(in: options, requested: previousRequest,
                                                               setting: Self.captureResolutionPreference) {
                    selectCapture(format: .processed, megapixels: preferred)
                }
            }
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        if isLivePhotoAvailable {
            selectedMotion = .livePhoto
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        prepareLivePhotoCapture()
    }

    func toggleLivePhoto() {
        selectMotion(selectedMotion == .livePhoto ? .photo : .livePhoto)
    }

    private func prepareLivePhotoCapture() {
        isConfiguringLivePhoto = true
        statusMessage = nil
        previewRenderer.freeze()
        let finishAuthorization: @Sendable (Bool) -> Void = { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let service = self else { return }
                guard service.sessionRequested else {
                    service.isConfiguringLivePhoto = false
                    return
                }
                guard granted else {
                    service.isConfiguringLivePhoto = false
                    service.previewRenderer.resume()
                    service.selectedMotion = .photo
                    service.statusMessage = LanguageManager.text("Microphone access is required for Live Photos.")
                    if service.pendingCaptureFormat != nil { service.applyCameraDefaultsIfNeeded() }
                    return
                }
                service.sessionQueue.async { [weak service] in
                    service?.configureLivePhotoPipeline()
                }
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            finishAuthorization(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: finishAuthorization)
        case .denied, .restricted:
            finishAuthorization(false)
        @unknown default:
            finishAuthorization(false)
        }
    }

    var canExportCapture: Bool {
        captureDeliveryComplete && !isProcessingCapture && !isSavingCapture && capturedImage != nil &&
            pendingProcessedImage != nil && (!captureUsesLivePhoto || capturedLivePhoto != nil)
    }

    func captureForExport() -> CameraCaptureExport? {
        guard canExportCapture, let cgImage = pendingProcessedImage?.cgImage else { return nil }
        let recipe = captureCharacterAdjustment
        let base = recipe.accentBase
        let accent: AccentRGB?
        if recipe.accentStrength > 0 && FilmFrame.acceptsAccent(base) {
            let pad = PadAccent(x: recipe.accentPoint.x, y: recipe.accentPoint.y, strength: recipe.accentStrength / 100)
            let tones = pad.tones(base: base)
            accent = tones.pivot < 0 ? tones.shadow : tones.highlight
        } else {
            accent = nil
        }
        return CameraCaptureExport(photo: cgImage, stock: captureFrameStock, recipeAccent: accent, isHPan: captureIsHPan)
    }

    // Delivery and full-resolution processing can finish in either order.
    private func autoSaveIfReady() {
        guard let format = autoSavePending, canExportCapture, !captureRequiresRAW || pendingRawData != nil else { return }
        autoSavePending = nil
        saveCapture(format.variants)
    }

    func saveCapture(_ requested: Set<CameraExportVariant>) {
        let variants = requested.subtracting(savedVariants)
        guard !variants.isEmpty, let image = captureForExport() else { return }
        guard !captureRequiresRAW || pendingRawData != nil else {
            statusMessage = LanguageManager.text("RAW capture failed. Please retake the photo.")
            return
        }

        let live = variants.contains(.photo) ? capturedLivePhoto : nil
        let original = originalSaved ? nil : pendingHPanOriginal
        let raw = originalSaved ? nil : pendingRawData
        let date = capturedDate
        isSavingCapture = true

        Task {
            defer { isSavingCapture = false }
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else {
                handleDeniedPhotoAccess()
                return
            }

            do {
                let photo = variants.contains(.photo) && live == nil ? try await image.file(for: .photo) : nil
                let framed = variants.contains(.filmFrame) ? try await image.file(for: .filmFrame) : nil
                defer { withExtendedLifetime((photo, framed)) {} }

                if let raw {
                    let (success, representation, diagnostic) = await withCheckedContinuation { continuation in
                        RAWPhotoLibrarySaver.save(rawData: raw, companionFile: photo?.url, frameFile: framed?.url,
                                                 date: date, location: nil) { success, representation, diagnostic in
                            continuation.resume(returning: (success, representation, diagnostic))
                        }
                    }
                    guard success else {
                        let message = LanguageManager.text("Couldn’t save this photo.")
                        statusMessage = diagnostic.map { message + "\n" + $0 } ?? message
                        return
                    }
                    originalSaved = true
                    if representation == .rawOnly {
                        statusMessage = LanguageManager.text("Saved RAW. The processed companion couldn’t be saved.")
                        return
                    }
                    if representation == .separate && photo != nil {
                        finishCaptureSave(variants, message: LanguageManager.text("Saved RAW and processed photo separately."))
                    } else {
                        finishCaptureSave(variants, message: LanguageManager.text("Saved to Photos"))
                    }
                    return
                }

                try await PHPhotoLibrary.shared().performChanges {
                    if let original {
                        let source = PHAssetCreationRequest.forAsset()
                        source.creationDate = date
                        source.addResource(with: .photo, data: original, options: nil)
                    }
                    if let live {
                        let request = PHAssetCreationRequest.forAsset()
                        request.creationDate = date
                        request.location = live.location
                        request.addResource(with: .photo, fileURL: live.stillURL, options: nil)
                        request.addResource(with: .pairedVideo, fileURL: live.motionURL, options: nil)
                    }
                    for file in [photo, framed].compactMap({ $0 }) {
                        let request = PHAssetCreationRequest.forAsset()
                        request.creationDate = date
                        request.addResource(with: .photo, fileURL: file.url, options: nil)
                    }
                }
                if original != nil { originalSaved = true }
                let message = if original != nil {
                    LanguageManager.text("Saved panorama and original to Photos.")
                } else if live != nil && framed == nil {
                    LanguageManager.text("Saved Live Photo")
                } else {
                    LanguageManager.text("Saved to Photos")
                }
                finishCaptureSave(variants, message: message)
            } catch {
                if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .denied {
                    handleDeniedPhotoAccess()
                } else {
                    statusMessage = LanguageManager.text("Couldn’t save this photo.")
                }
            }
        }
    }

    private func finishCaptureSave(_ variants: Set<CameraExportVariant>, message: String) {
        savedVariants.formUnion(variants)
        statusMessage = message
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func handleDeniedPhotoAccess() {
        isSavingCapture = false
        UserDefaults.standard.set(false, forKey: Self.autoSaveKey)
        statusMessage = LanguageManager.text("Allow photo access in Settings to save.")
    }

    private func configureAndStartIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.cameraInput == nil { self.configureSession() }
            if let device = self.cameraInput?.device {
                Task { @MainActor in self.configureRotationCoordinator(for: device) }
            }
            self.startSessionOnlyFromQueue()
            if self.beforeHPan == nil, self.session.isRunning {
                self.refreshRAWAvailability(applyDefaults: true)
            }
        }
    }

    private func checkCapturePreferences() {
        let format = UserDefaults.standard.string(forKey: CaptureFormatOption.preferenceKey)
            .flatMap(CaptureFormatOption.init(rawValue:)) ?? .processed
        let resolution = Self.captureResolutionPreference
        let nextFormat = lastCaptureFormatPreference == format ? nil : format
        let changed = pendingCaptureFormat != nextFormat || lastCaptureResolutionPreference != resolution
        if pendingCaptureFormat != nextFormat { pendingCaptureFormat = nextFormat }
        if changed {
            lastCaptureResolutionPreference = resolution
            resolutionLock.withLock { requestedPhotoMegapixels = nil }
            if pendingCaptureFormat == nil { applyPreferredResolution() }
        }
    }

    private func applyCameraDefaultsIfNeeded() {
        guard sessionRequested, session.isRunning, !hpanEnabled, !changingMode, !isConfiguringLivePhoto else { return }
        if let requested = pendingCaptureFormat {
            let format = requested.supported(rawAvailable: isRAWAvailable)
            let resolution = resolutionLock.withLock {
                let native = supportedPhotoDimensions.map(Self.megapixels(for:))
                let choices = CaptureResolution.choices(native: native, format: format)
                return CaptureResolution.preferred(in: choices, requested: nil, setting: Self.captureResolutionPreference)
            } ?? selectedMegapixels
            lastCaptureFormatPreference = requested
            pendingCaptureFormat = nil
            selectCapture(format: format, megapixels: resolution, isDefault: true)
            if requested == .raw { shouldApplyDefaultMotionOnStart = false }
            if format != requested { statusMessage = LanguageManager.text("RAW capture is unavailable on this camera. Using HEIF.") }
        }
        if !isConfiguringLivePhoto { applyDefaultMotionIfNeeded() }
    }

    private func applyDefaultMotionIfNeeded() {
        guard sessionRequested, shouldApplyDefaultMotionOnStart, !hpanEnabled, !changingMode else { return }
        shouldApplyDefaultMotionOnStart = false
        guard selectedFormat == .processed else { return }
        if !wantsLivePhoto {
            if selectedMotion == .livePhoto {
                selectMotion(.photo)
            } else {
                selectedMotion = .photo
            }
        } else {
            selectMotion(.livePhoto)
        }
    }

    nonisolated private func configureSession() {
        session.beginConfiguration()
        guard session.canSetSessionPreset(.photo) else {
            session.commitConfiguration()
            Task { @MainActor in
                self.authorizationState = .unavailable
                self.statusMessage = LanguageManager.text("Hibiscus Film couldn’t start the camera.")
            }
            return
        }
        session.sessionPreset = .photo
        var didConfigureSession = false
        defer {
            session.commitConfiguration()
            if didConfigureSession {
                if let device = cameraInput?.device {
                    updatePhotoResolutionCapabilities(for: device)
                }
                refreshRAWAvailability()
                reevaluateLivePhotoCompatibility()
#if DEBUG
                debugLogCameraConfiguration(context: "initial configuration")
#endif
            }
        }

        guard let device = preferredRearDevice() else {
            Task { @MainActor in self.authorizationState = .unavailable }
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return }
            session.addInput(input)
            cameraInput = input

            videoOutput.alwaysDiscardsLateVideoFrames = true
            // The .photo preset otherwise allows AVFoundation to hand the data
            // output a deliberately small proxy buffer. Hibiscus renders that
            // buffer directly, so request the active format's full video stream
            // and let Core Image scale it to the Metal drawable instead.
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = false
            let preferredPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if videoOutput.availableVideoPixelFormatTypes.contains(preferredPixelFormat) {
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: preferredPixelFormat
                ]
            }
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .quality
                enableAppleProRAWIfSupported()
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                _ = addAudioInputDuringConfiguration()
            }

            configureVideoConnectionFallback(for: device)
            updateDeviceState(device)
            configureCameraControls(for: device, panoramic: false)
            didConfigureSession = true
        } catch {
            Task { @MainActor in
                self.authorizationState = .unavailable
                self.statusMessage = LanguageManager.text("Hibiscus Film couldn’t start the camera.")
            }
        }
    }

    nonisolated private func replaceCameraInput(
        with device: AVCaptureDevice,
        requestedZoomFactor: CGFloat? = nil,
        requestedDisplayFactor: CGFloat? = nil,
        switchToken: UUID? = nil
    ) {
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        session.beginConfiguration()
        let hasCompatiblePreset = session.canSetSessionPreset(.photo)
        if hasCompatiblePreset {
            session.sessionPreset = .photo
        }
        // Disable the old device's capability before replacing its input. The
        // final configuration is reevaluated and enabled again after commit.
        photoOutput.isLivePhotoCaptureEnabled = false
        photoOutput.isLivePhotoAutoTrimmingEnabled = false
        if let cameraInput { session.removeInput(cameraInput) }
        var didReplaceInput = false
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                cameraInput = newInput
                didReplaceInput = true
                configureCameraControls(for: device, panoramic: false)
                enableAppleProRAWIfSupported()
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    _ = addAudioInputDuringConfiguration()
                }
                configureVideoConnectionFallback(for: device)
                updateDeviceState(
                    device,
                    requestedZoomFactor: requestedZoomFactor,
                    requestedDisplayFactor: requestedDisplayFactor
                )
            }
        } catch {
            Task { @MainActor in self.statusMessage = LanguageManager.text("Couldn’t switch cameras.")
            }
        }
        if !didReplaceInput, let original = cameraInput, session.canAddInput(original) {
            session.addInput(original)
            configureCameraControls(for: original.device, panoramic: false)
        }
        session.commitConfiguration()
        guard didReplaceInput else {
            if let original = cameraInput, session.inputs.contains(original) {
                updateDeviceState(original.device, requestedZoomFactor: original.device.videoZoomFactor,
                                  requestedDisplayFactor: nativeDisplayFactor(for: original.device) * original.device.videoZoomFactor)
                reevaluateLivePhotoCompatibility(allowingCapture: hasCompatiblePreset)
                if wasRunning && !session.isRunning { session.startRunning() }
            }
            finishCameraSwitchFailure(token: switchToken)
            return
        }
        updatePhotoResolutionCapabilities(for: device)
        refreshRAWAvailability()
        reevaluateLivePhotoCompatibility(allowingCapture: hasCompatiblePreset)
#if DEBUG
        debugLogCameraConfiguration(context: "camera input replaced")
#endif
        if wasRunning { session.startRunning() }
        Task { @MainActor in
            self.configureRotationCoordinator(for: device, switchToken: switchToken)
            self.isRunning = self.session.isRunning
        }
    }

    nonisolated private func refreshRAWAvailability(applyDefaults: Bool = false) {
        // Discovery must not silently undo a Live Photo-compatible pipeline.
        let rawAvailable = photoOutput.isAppleProRAWSupported
            || !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let rawMegapixels = rawAvailable ? supportedRAWPhotoMegapixels() : []
        Task { @MainActor in
            self.isRAWAvailable = rawAvailable
            self.availableRawMegapixels = rawMegapixels
            if !rawAvailable { self.selectedFormat = .processed }
            if applyDefaults { self.applyCameraDefaultsIfNeeded() }
        }
    }

    @discardableResult
    nonisolated private func reevaluateLivePhotoCompatibility(
        allowingCapture: Bool = true, requestingLivePhoto: Bool = false
    ) -> Bool {
        if allowingCapture, requestingLivePhoto || requestsLivePhoto,
           audioInput != nil, !photoOutput.isLivePhotoCaptureSupported {
            recoverLivePhotoCompatibility()
        }
        let available = allowingCapture
            && audioInput != nil
            && photoOutput.isLivePhotoCaptureSupported
        if photoOutput.isLivePhotoCaptureEnabled != available {
            photoOutput.isLivePhotoCaptureEnabled = available
        }
        photoOutput.isLivePhotoAutoTrimmingEnabled = available
        Task { @MainActor in
            self.isLivePhotoAvailable = available
            if !available { self.selectedMotion = .photo }
        }
        return available
    }

    /// Negotiate output constraints rather than repeatedly testing the same
    /// incompatible configuration. Never take ownership of activeFormat.
    /// Called on sessionQueue while the session is stopped.
    nonisolated private func recoverLivePhotoCompatibility() {
        guard !session.isRunning else { return }
        let wasAutomatic = videoOutput.automaticallyConfiguresOutputBufferDimensions
        let wasPreviewSized = videoOutput.deliversPreviewSizedOutputBuffers
        let wasProRAWEnabled = photoOutput.isAppleProRAWEnabled
        session.beginConfiguration()
        videoOutput.automaticallyConfiguresOutputBufferDimensions = true
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        session.commitConfiguration()
        if let device = cameraInput?.device {
            updatePhotoResolutionCapabilities(for: device)
        }
#if DEBUG
        debugLogCameraConfiguration(context: "Live Photo recovery: automatic preview dimensions")
#endif
        guard !photoOutput.isLivePhotoCaptureSupported else { return }

        if photoOutput.isAppleProRAWEnabled {
            session.beginConfiguration()
            photoOutput.isAppleProRAWEnabled = false
            session.commitConfiguration()
#if DEBUG
            debugLogCameraConfiguration(context: "Live Photo recovery: ProRAW disabled")
#endif
        }
        guard !photoOutput.isLivePhotoCaptureSupported,
              let device = cameraInput?.device else { return }
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) > Int64($1.width) * Int64($1.height)
        }
        for candidate in dimensions where
            Int64(candidate.width) * Int64(candidate.height)
                < Int64(photoOutput.maxPhotoDimensions.width) * Int64(photoOutput.maxPhotoDimensions.height) {
            session.beginConfiguration()
            photoOutput.maxPhotoDimensions = candidate
            session.commitConfiguration()
#if DEBUG
            debugLogCameraConfiguration(context: "Live Photo recovery: lower output ceiling")
#endif
            if photoOutput.isLivePhotoCaptureSupported {
                livePhotoResolutionLimited = true
                updatePhotoResolutionCapabilities(for: device, maximum: candidate)
                return
            }
        }
        // Unsupported even at the smallest size: don't leave still capture
        // needlessly restricted after a failed recovery attempt.
        session.beginConfiguration()
        videoOutput.automaticallyConfiguresOutputBufferDimensions = wasAutomatic
        if !wasAutomatic { videoOutput.deliversPreviewSizedOutputBuffers = wasPreviewSized }
        if wasProRAWEnabled { enableAppleProRAWIfSupported() }
        session.commitConfiguration()
        updatePhotoResolutionCapabilities(for: device)
    }

    nonisolated private func addAudioInputDuringConfiguration() -> Bool {
        if audioInput != nil { return true }
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        audioInput = input
        return true
    }

    nonisolated private func configureLivePhotoPipeline() {
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }

        session.beginConfiguration()
        photoOutput.isLivePhotoCaptureEnabled = false
        photoOutput.isLivePhotoAutoTrimmingEnabled = false
        let hasAudio = addAudioInputDuringConfiguration()
        let hasCompatiblePreset = session.canSetSessionPreset(.photo)
        if hasCompatiblePreset {
            session.sessionPreset = .photo
        }
        session.commitConfiguration()
        if let device = cameraInput?.device {
            updatePhotoResolutionCapabilities(for: device)
        }

        refreshRAWAvailability()
        let available = reevaluateLivePhotoCompatibility(
            allowingCapture: hasAudio && hasCompatiblePreset,
            requestingLivePhoto: true
        )
#if DEBUG
        debugLogCameraConfiguration(context: "Live Photo configuration")
#endif
        if wasRunning { session.startRunning() }

        Task { @MainActor in
            self.isRunning = self.session.isRunning
            self.isLivePhotoAvailable = available
            self.isConfiguringLivePhoto = false
            self.previewRenderer.resume()
            self.selectedMotion = available ? .livePhoto : .photo
            if available {
                self.statusMessage = nil
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                self.statusMessage = LanguageManager.text("Live Photo isn’t available with the current camera configuration.")
            }
            if self.pendingCaptureFormat != nil { self.applyCameraDefaultsIfNeeded() }
        }
    }

    nonisolated private func enableAppleProRAWIfSupported() {
        if photoOutput.isAppleProRAWSupported && !photoOutput.isAppleProRAWEnabled {
            photoOutput.isAppleProRAWEnabled = true
        }
    }

    /// Discovers still resolutions from the format selected by AVFoundation's
    /// `.photo` preset. Resolution changes only update photo-output/settings
    /// dimensions; they never take ownership of `device.activeFormat`.
    nonisolated private func updatePhotoResolutionCapabilities(
        for device: AVCaptureDevice, maximum limit: CMVideoDimensions? = nil
    ) {
        if limit == nil { livePhotoResolutionLimited = false }
        let supported = device.activeFormat.supportedMaxPhotoDimensions.filter {
            guard let limit else { return true }
            return Int64($0.width) * Int64($0.height) <= Int64(limit.width) * Int64(limit.height)
        }.sorted(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        })
        guard let maximum = supported.last else { return }
        photoOutput.maxPhotoDimensions = maximum

        var distinct: [CMVideoDimensions] = []
        for dimensions in supported where !distinct.contains(where: {
            Self.megapixels(for: $0) == Self.megapixels(for: dimensions)
        }) {
            distinct.append(dimensions)
        }
        if distinct.isEmpty { distinct = [maximum] }
        var values = Array(Set(distinct.map(Self.megapixels(for:)).filter { $0 > 0 })).sorted()
        if values.isEmpty { values = [Self.megapixels(for: maximum)] }
        // Hibiscus can produce a true 24 MP processed output from a larger
        // supported source without assigning an unsupported capture dimension.
        // Keep RAW choices limited to dimensions the active format reports.
        let options = CaptureResolution.choices(native: values, format: .processed)
        resolutionLock.withLock {
            supportedPhotoDimensions = distinct
            _ = chooseResolution(from: options, format: captureFormat)
        }
        Task { @MainActor in
            self.availableMegapixels = options
            self.selectedMegapixels = self.selectedTargetMegapixels()
        }
    }

    nonisolated private static var captureResolutionPreference: CaptureResolution {
        CaptureResolution(rawValue: UserDefaults.standard.integer(forKey: CaptureResolution.preferenceKey)) ?? .automatic
    }

    private func applyPreferredResolution() {
        let choices = selectedFormat == .raw ? availableRawMegapixels : availableMegapixels
        guard !choices.isEmpty else { return }
        selectedMegapixels = resolutionLock.withLock { chooseResolution(from: choices, format: selectedFormat) }
    }

    // Called with resolutionLock held. RAW only offers native sensor dimensions.
    nonisolated private func chooseResolution(from options: [Int], format: CaptureFormatOption) -> Int {
        let native = supportedPhotoDimensions.map(Self.megapixels(for:))
        let choices = format == .raw && !native.isEmpty ? native : options
        let target = CaptureResolution.preferred(in: choices, requested: requestedPhotoMegapixels,
                                                  setting: Self.captureResolutionPreference) ?? 12
        if let dimensions = supportedPhotoDimensions.first(where: { Self.megapixels(for: $0) == target })
            ?? supportedPhotoDimensions.first(where: { Self.megapixels(for: $0) > target }) {
            capturePhotoDimensions = dimensions
        }
        captureTargetMegapixels = target
        return target
    }

    nonisolated private func selectedPhotoDimensions() -> CMVideoDimensions {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        return capturePhotoDimensions
    }

    nonisolated private func selectedTargetMegapixels() -> Int {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        return captureTargetMegapixels
    }

    nonisolated private static func megapixels(for dimensions: CMVideoDimensions) -> Int {
        let measured = Double(dimensions.width) * Double(dimensions.height) / 1_000_000
        let nativeLabels = [12, 24, 48]
        if let label = nativeLabels.min(by: { abs(Double($0) - measured) < abs(Double($1) - measured) }),
           abs(Double(label) - measured) < 3 {
            return label
        }
        return Int(measured.rounded())
    }

    nonisolated private func supportedRAWPhotoMegapixels() -> [Int] {
        resolutionLock.lock()
        let values = supportedPhotoDimensions.map(Self.megapixels(for:))
        resolutionLock.unlock()
        // Surface every photo dimension the active camera format reports. RAW
        // selection then requests that exact native dimension rather than using
        // the processed 24 MP downsampling path.
        return Array(Set(values.filter { $0 > 0 })).sorted()
    }

    nonisolated private func preferredRearDevice() -> AVCaptureDevice? {
        // Prefer the physical main camera for its native still-photo resolutions.
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera
        ]
        for type in types {
            if let device = AVCaptureDevice.DiscoverySession(
                deviceTypes: [type],
                mediaType: .video,
                position: .back
            ).devices.first {
                return device
            }
        }
        return nil
    }

    nonisolated private func configureVideoConnectionFallback(for device: AVCaptureDevice) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        let angle = currentPreviewRotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device.position == .front
        }
    }

    private func configureRotationCoordinator(for device: AVCaptureDevice, switchToken: UUID? = nil) {
        if previewLayer == nil && !hpanEnabled {
            prepareFirstFrameAfterSwitch(token: switchToken)
            return
        }
        previewRotationObservation = nil
        captureRotationObservation = nil

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        if hpanEnabled {
            let portrait = portraitAngle(coordinator)
            applyPreviewRotation(portrait, position: device.position, switchToken: switchToken)
            updateHPanOrientation(coordinator.videoRotationAngleForHorizonLevelCapture, portrait: portrait)
            captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) {
                [weak self, weak coordinator] _, _ in
                guard let coordinator else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.rotationCoordinator === coordinator, self.hpanEnabled else { return }
                    self.updateHPanOrientation(coordinator.videoRotationAngleForHorizonLevelCapture, portrait: portrait)
                }
            }
            return
        }
        applyPreviewRotation(
            coordinator.videoRotationAngleForHorizonLevelPreview,
            position: device.position,
            switchToken: switchToken
        )

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self, weak coordinator] _, change in
            guard let coordinator, let angle = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.rotationCoordinator === coordinator else { return }
                self.applyPreviewRotation(angle, position: device.position)
            }
        }
    }

    private func updateHPanOrientation(_ angle: CGFloat, portrait: CGFloat) {
        let orientation = HPan.Orientation(captureAngle: angle, portraitAngle: portrait)
        if hpanOrientation != orientation { hpanOrientation = orientation }
    }

    private func portraitAngle(_ coordinator: AVCaptureDevice.RotationCoordinator) -> CGFloat {
        if #available(iOS 27.0, *) {
            return coordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)
        }
        return 90 // Native sensor-to-portrait rotation of the rear Ultra Wide.
    }

    private func applyPreviewRotation(
        _ angle: CGFloat,
        position: AVCaptureDevice.Position,
        switchToken: UUID? = nil
    ) {
        currentPreviewRotationAngle = angle
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.videoOutput.connection(with: .video) else { return }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
            self.prepareFirstFrameAfterSwitch(token: switchToken)
        }
    }

    nonisolated private func prepareFirstFrameAfterSwitch(token: UUID?) {
        guard let token else { return }
        videoQueue.async { [weak self] in
            guard let self, self.pendingCameraSwitchToken == token else { return }
            self.acceptsPreviewFrames = true
        }
    }

    private func recoverCameraSwitchIfNeeded(token: UUID) {
        videoQueue.async { [weak self] in
            guard let self, self.pendingCameraSwitchToken == token else { return }
            self.pendingCameraSwitchToken = nil
            self.acceptsPreviewFrames = true
            self.previewRenderer.resume()
            Task { @MainActor in
                guard self.isSwitchingCamera else { return }
                self.cameraSwitchRecoveryTask = nil
                withAnimation(.easeOut(duration: 0.18)) {
                    self.isSwitchingCamera = false
                }
            }
        }
    }

    nonisolated private func finishCameraSwitchFailure(token: UUID?) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            if let token {
                guard self.pendingCameraSwitchToken == token else { return }
                self.pendingCameraSwitchToken = nil
            }
            self.acceptsPreviewFrames = true
            self.previewRenderer.resume()
            Task { @MainActor in
                self.cameraSwitchRecoveryTask?.cancel()
                self.cameraSwitchRecoveryTask = nil
                self.isSwitchingCamera = false
            }
        }
    }

    nonisolated private func selectRearLens(displayFactor: CGFloat) {
        guard let target = rearLensTargets().min(by: {
            abs($0.displayFactor - displayFactor) < abs($1.displayFactor - displayFactor)
        }) else { return }

        if cameraInput?.device.uniqueID == target.device.uniqueID {
            updateDeviceState(
                target.device,
                requestedZoomFactor: target.deviceZoomFactor,
                requestedDisplayFactor: target.displayFactor
            )
        } else {
            replaceCameraInput(
                with: target.device,
                requestedZoomFactor: target.deviceZoomFactor,
                requestedDisplayFactor: target.displayFactor
            )
        }
    }

    /// Builds the native rear-camera rail from the physical constituents. The
    /// virtual device provides Apple's display-space focal-length mapping, while
    /// each physical device keeps access to its full still-photo dimensions.
    nonisolated private func rearLensTargets() -> [CameraLensTarget] {
        let virtualTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]
        let virtualDevice = virtualTypes.lazy.compactMap { type in
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [type],
                mediaType: .video,
                position: .back
            ).devices.first
        }.first

        var physicalDevices = virtualDevice?.constituentDevices ?? []
        if physicalDevices.isEmpty {
            physicalDevices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                mediaType: .video,
                position: .back
            ).devices
        }
        var seenDeviceIDs = Set<String>()
        physicalDevices = physicalDevices.filter { seenDeviceIDs.insert($0.uniqueID).inserted }
        physicalDevices.sort {
            Self.videoFieldOfView(for: $0) > Self.videoFieldOfView(for: $1)
        }
        guard !physicalDevices.isEmpty else { return [] }

        var nativeDisplayFactors: [CGFloat] = []
        if let virtualDevice {
            let multiplier = displayZoomMultiplier(for: virtualDevice)
            nativeDisplayFactors = [virtualDevice.minAvailableVideoZoomFactor]
            nativeDisplayFactors.append(contentsOf: virtualDevice.virtualDeviceSwitchOverVideoZoomFactors.map {
                CGFloat(truncating: $0)
            })
            nativeDisplayFactors = nativeDisplayFactors.map { $0 * multiplier }.sorted()
        }
        if nativeDisplayFactors.count != physicalDevices.count {
            nativeDisplayFactors = physicalDevices.enumerated().map { index, device in
                switch device.deviceType {
                case .builtInUltraWideCamera: 0.5
                case .builtInWideAngleCamera: 1
                case .builtInTelephotoCamera: index > 1 ? 3 : 2
                default: CGFloat(index + 1)
                }
            }
        }

        var targets = zip(physicalDevices, nativeDisplayFactors).map { device, displayFactor in
            CameraLensTarget(displayFactor: displayFactor, device: device, deviceZoomFactor: 1)
        }
        for (device, baseDisplayFactor) in zip(physicalDevices, nativeDisplayFactors) {
            for zoomFactor in device.activeFormat.secondaryNativeResolutionZoomFactors {
                let displayFactor = baseDisplayFactor * zoomFactor
                guard zoomFactor >= device.minAvailableVideoZoomFactor,
                      zoomFactor <= device.maxAvailableVideoZoomFactor,
                      !targets.contains(where: { abs($0.displayFactor - displayFactor) < 0.025 }) else { continue }
                targets.append(CameraLensTarget(
                    displayFactor: displayFactor,
                    device: device,
                    deviceZoomFactor: zoomFactor
                ))
            }
        }

        // Single-camera iPhones (including Air/SE/e configurations) do not
        // have a telephoto constituent to contribute to the native rail. Keep
        // every system-reported option above, then provide only the requested
        // 3× and 4× crop targets when the active format can actually reach them.
        if physicalDevices.count == 1,
           let device = physicalDevices.first,
           let baseDisplayFactor = nativeDisplayFactors.first {
            for displayFactor in [CGFloat(3), CGFloat(4)] {
                let zoomFactor = displayFactor / max(0.01, baseDisplayFactor)
                guard zoomFactor >= device.minAvailableVideoZoomFactor,
                      zoomFactor <= device.activeFormat.videoMaxZoomFactor,
                      !targets.contains(where: { abs($0.displayFactor - displayFactor) < 0.025 }) else { continue }
                targets.append(CameraLensTarget(
                    displayFactor: displayFactor,
                    device: device,
                    deviceZoomFactor: zoomFactor
                ))
            }
        }
        return targets.sorted { $0.displayFactor < $1.displayFactor }
    }

    nonisolated private static func videoFieldOfView(for device: AVCaptureDevice) -> Float {
        device.formats.map(\.videoFieldOfView).max() ?? device.activeFormat.videoFieldOfView
    }

    nonisolated private func updateDeviceState(
        _ device: AVCaptureDevice,
        requestedZoomFactor: CGFloat? = nil,
        requestedDisplayFactor: CGFloat? = nil
    ) {
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = device.maxAvailableVideoZoomFactor
        let targets = rearLensTargets()
        let selectedTarget = targets.min(by: { lhs, rhs in
            if let requestedDisplayFactor {
                return abs(lhs.displayFactor - requestedDisplayFactor) < abs(rhs.displayFactor - requestedDisplayFactor)
            }
            let lhsMatchesDevice = lhs.device.uniqueID == device.uniqueID
            let rhsMatchesDevice = rhs.device.uniqueID == device.uniqueID
            if lhsMatchesDevice != rhsMatchesDevice { return lhsMatchesDevice }
            return abs(lhs.displayFactor - 1) < abs(rhs.displayFactor - 1)
        })
        let selectedFactor = max(minimum, min(requestedZoomFactor ?? selectedTarget?.deviceZoomFactor ?? 1, maximum))
        let displayFactor = requestedDisplayFactor ?? selectedTarget?.displayFactor ?? 1
        let publishedOptions = Self.uniqueLensOptions(targets.map {
            CameraLensOption(factor: Double($0.displayFactor), label: formatLens($0.displayFactor))
        })

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.videoZoomFactor = selectedFactor
            device.unlockForConfiguration()
        } catch { }
        Task { @MainActor in
            self.flashAvailable = device.hasFlash && device.position == .back
            self.displayZoom = displayFactor
            self.lensOptions = publishedOptions
            self.applyFocus()
            self.setExposure(self.exposure)
        }
    }

    nonisolated private func nativeDisplayFactor(for device: AVCaptureDevice) -> CGFloat {
        rearLensTargets().first { $0.device == device && $0.deviceZoomFactor == 1 }?.displayFactor
            ?? displayZoomMultiplier(for: device)
    }

    nonisolated private func displayZoomMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return max(0.01, device.displayVideoZoomFactorMultiplier)
        }
        return device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }) ? 0.5 : 1
    }

#if DEBUG
    nonisolated private func debugLogCameraConfiguration(context: String) {
        let device = cameraInput?.device
        let activeDimensions = device.map {
            CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
        } ?? CMVideoDimensions(width: 0, height: 0)
        let supportedDimensions = device?.activeFormat.supportedMaxPhotoDimensions.map {
            "\($0.width)x\($0.height) (~\(Self.megapixels(for: $0)) MP)"
        }.joined(separator: ", ") ?? "none"
        let selectedDimensions = selectedPhotoDimensions()
        let selectedMegapixels = selectedTargetMegapixels()
        print(
            """
            [Hibiscus Camera] \(context)
              sessionPreset: \(session.sessionPreset.rawValue)
              activeDevice: \(device?.localizedName ?? "none") [\(device?.uniqueID ?? "none")]
              activeFormatDimensions: \(activeDimensions.width)x\(activeDimensions.height)
              supportedMaxPhotoDimensions: [\(supportedDimensions)]
              selectedPhotoResolution: \(selectedDimensions.width)x\(selectedDimensions.height) (~\(selectedMegapixels) MP)
              isLivePhotoCaptureSupported: \(photoOutput.isLivePhotoCaptureSupported)
              isLivePhotoCaptureEnabled: \(photoOutput.isLivePhotoCaptureEnabled)
              isAppleProRAWEnabled: \(photoOutput.isAppleProRAWEnabled)
              maxPhotoDimensions: \(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height)
              automaticPreviewDimensions: \(videoOutput.automaticallyConfiguresOutputBufferDimensions)
              hasAudioInput: \(audioInput != nil)
            """
        )
    }
#endif

    private func startSessionOnly() {
        sessionQueue.async { [weak self] in self?.startSessionOnlyFromQueue() }
    }

    nonisolated private func startSessionOnlyFromQueue() {
        guard !session.isRunning, cameraInput != nil else { return }
        session.startRunning()
        Task { @MainActor in self.isRunning = true }
    }

    nonisolated private func formatLens(_ factor: CGFloat) -> String {
        // Some devices expose a near-unity display multiplier (for example
        // 0.9) even though it is not a distinct native lens selection. Present
        // that optical state as the system-facing 1× option.
        let displayFactor = abs(factor - 1) < 0.15 ? CGFloat(1) : factor
        return abs(displayFactor - displayFactor.rounded()) < 0.01
            ? "\(Int(displayFactor.rounded()))×"
            : "\(String(format: "%.1f", Double(displayFactor)))×"
    }

    nonisolated private static func uniqueLensOptions(_ options: [CameraLensOption]) -> [CameraLensOption] {
        var labels = Set<String>()
        return options.filter { labels.insert($0.label).inserted }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The video connection delivers physically rotated portrait buffers.
        // Front-camera mirroring is also applied at the connection level.
        let image = CIImage(cvPixelBuffer: buffer)
        let character = renderCharacter
        let adjustment = renderCharacterAdjustment
        guard acceptsPreviewFrames else { return }
        guard pendingCameraSwitchToken == nil || previewBufferMatchesCurrentRotation(buffer, connection: connection) else { return }
        if adjustment.usesSceneAccent, let generation = accentGeneration {
            accentSampler.submit(image, generation: generation) { [weak self] color in
                guard let self else { return }
                Task { @MainActor in
                    guard self.accentGeneration == generation else { return }
                    self.videoQueue.sync {
                        if self.renderCharacterAdjustment.usesSceneAccent {
                            self.renderCharacterAdjustment.sceneColor = color
                        }
                    }
                    self.sceneAccent = color
                }
            }
        }
        if pendingCameraSwitchToken != nil {
            // Connection changes can leave one stale, pre-rotation buffer queued.
            // Keep the held frame until dimensions agree with the coordinator.
            pendingCameraSwitchToken = nil
            acceptsPreviewFrames = true
            previewRenderer.reveal(image, character: character, adjustment: adjustment) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isSwitchingCamera else { return }
                    self.cameraSwitchRecoveryTask?.cancel()
                    self.cameraSwitchRecoveryTask = nil
                    withAnimation(.easeOut(duration: 0.28)) {
                        self.isSwitchingCamera = false
                    }
                }
            }
        } else {
            previewRenderer.submit(image, character: character, adjustment: adjustment)
        }
    }

    nonisolated private func previewBufferMatchesCurrentRotation(_ buffer: CVPixelBuffer, connection: AVCaptureConnection) -> Bool {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width != height else { return true }
        let normalizedAngle = Int(currentPreviewRotationAngle.rounded()).quotientAndRemainder(dividingBy: 180).remainder
        guard let description = connection.inputPorts.first(where: { $0.mediaType == .video })?.formatDescription else { return true }
        let native = CMVideoFormatDescriptionGetDimensions(description)
        guard native.width != native.height else { return true }
        let quarterTurn = abs(normalizedAngle) == 90
        let expectsPortrait = quarterTurn ? native.width > native.height : native.height > native.width
        return expectsPortrait == (height > width)
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
#if DEBUG
            let failure = error as NSError
            print("[Hibiscus Camera] Photo processing failed: \(failure.domain) (\(failure.code)), RAW: \(photo.isRawPhoto)")
#endif
            return
        }
        let data = photo.fileDataRepresentation()
        guard let data else {
            return
        }
        if photo.isRawPhoto {
            pendingRawData = data
            return
        }
        if captureUsesLivePhoto { pendingLivePhotoData = data }
        guard let image = UIImage(data: data) else { return }
        let reference: UIImage?
        switch doubleExposureCapture {
        case .off: reference = nil
        case .first:
            pendingFirstExposure = data
            return
        case .second(let bytes):
            guard let first = UIImage(data: bytes) else { return }
            reference = first
        }
        if captureIsHPan {
            guard let style = captureCharacter,
                  let panorama = CameraImageRenderer.panoramicImage(image, character: style, adjustment: captureCharacterAdjustment,
                                                                    orientationCorrection: captureHPanCorrection)
            else { return }
            pendingHPanOriginal = data
            pendingPreviewImage = panorama
            pendingProcessedImage = panorama
            return
        }
        let character = captureCharacter
        let adjustment = captureCharacterAdjustment
        let aspectRatio = captureLiveAspectRatio
        let targetMegapixels = captureLiveTargetMegapixels
        let token = captureProcessingToken
        let preview = CameraImageRenderer.cameraImage(
            image,
            character: character,
            adjustment: adjustment,
            aspectRatio: aspectRatio,
            targetMegapixels: min(2, targetMegapixels), firstExposure: reference
        )
        pendingPreviewImage = preview
        pendingProcessedImage = preview

        // Live Photo development renders its full-size still alongside the movie.
        guard !captureUsesLivePhoto else { return }
        photoProcessingQueue.async { [weak self] in
            let processed = autoreleasepool {
                CameraImageRenderer.cameraImage(
                    image,
                    character: character,
                    adjustment: adjustment,
                    aspectRatio: aspectRatio,
                    targetMegapixels: targetMegapixels, firstExposure: reference
                )
            }
            Task { @MainActor [weak self] in
                guard let self, self.captureProcessingToken == token else { return }
                self.pendingProcessedImage = processed
                if processed == nil {
                    self.statusMessage = LanguageManager.text("The full-resolution film render failed. Please retake this photo.")
                }
                if self.capturedImage != nil, processed != nil {
                    self.capturedImage = processed
                    self.capturedPreviewImage = processed
                }
                if !self.captureUsesLivePhoto {
                    self.isProcessingCapture = false
                    self.autoSaveIfReady()
                }
            }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL,
        resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.captureUsesLivePhoto else { return }
            // This delegate boundary is the authoritative end of Live Photo
            // motion capture. Freeze only now, while file/color processing runs.
            self.isRecordingLivePhoto = false
            self.previewRenderer.freeze()
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        guard error == nil else {
            try? FileManager.default.removeItem(at: outputFileURL)
            pendingLivePhotoMovieURL = nil
            return
        }
        pendingLivePhotoMovieURL = outputFileURL
        pendingLivePhotoDisplayTime = photoDisplayTime
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if case .first = doubleExposureCapture {
            let exposed = pendingFirstExposure
            let token = captureProcessingToken
            pendingFirstExposure = nil
            doubleExposureCapture = .off
            Task { @MainActor [weak self] in
                guard let self, self.captureProcessingToken == token else { return }
                self.isCapturing = false
                self.isProcessingCapture = false
                self.capturedDate = nil
                self.autoSavePending = nil
                self.previewRenderer.resume()
                if error == nil, let exposed, self.sessionRequested {
                    self.firstExposure = exposed
                } else if self.sessionRequested {
                    self.statusMessage = LanguageManager.text("Couldn’t capture this photo.")
                }
            }
            return
        }
        let preview = pendingPreviewImage
        let usesLivePhoto = captureUsesLivePhoto
        let livePhotoData = pendingLivePhotoData
        let livePhotoMovieURL = pendingLivePhotoMovieURL
        let liveDisplayTime = pendingLivePhotoDisplayTime
        let liveCharacter = captureCharacter
        let liveAdjustment = captureCharacterAdjustment
        let liveAspectRatio = captureLiveAspectRatio
        let liveTargetMegapixels = captureLiveTargetMegapixels
        let token = captureProcessingToken
        let missingRAW = captureRequiresRAW && pendingRawData == nil
        doubleExposureCapture = .off
        Task { @MainActor [weak self] in
            guard let self, self.captureProcessingToken == token else { return }
            self.captureDeliveryComplete = true
            self.isRecordingLivePhoto = false
            self.isCapturing = false
            // Rendering may finish while this callback waits for MainActor.
            // Read the latest result here, not a stale low-resolution snapshot.
            guard error == nil, let processed = self.pendingProcessedImage else {
                self.isProcessingCapture = false
                self.previewRenderer.resume()
                self.statusMessage = LanguageManager.text("Couldn’t capture this photo.")
                return
            }
            if self.captureIsHPan { self.isProcessingCapture = false }
            self.capturedImage = processed
            self.capturedPreviewImage = preview ?? processed
            if missingRAW {
                self.statusMessage = LanguageManager.text("RAW capture failed. Please retake the photo.")
            }
            self.stop()
            self.autoSaveIfReady()
        }
        guard error == nil, usesLivePhoto,
              let livePhotoData, let livePhotoMovieURL else {
            if usesLivePhoto {
                Task { @MainActor [weak self] in
                    guard let self, self.captureProcessingToken == token else { return }
                    self.isProcessingCapture = false
                    self.statusMessage = LanguageManager.text("Couldn’t capture this Live Photo.")
                }
            }
            return
        }
        Task { @MainActor [weak self] in
            let output = await Task.detached(priority: .userInitiated) {
                await LivePhotoProcessor.processCameraCapture(
                    photoData: livePhotoData,
                    motionURL: livePhotoMovieURL,
                    displayTime: liveDisplayTime,
                    character: liveCharacter,
                    adjustment: liveAdjustment,
                    aspectRatio: liveAspectRatio,
                    targetMegapixels: liveTargetMegapixels,
                    location: nil
                )
            }.value
            guard let self, self.captureProcessingToken == token else {
                output?.cleanUp()
                return
            }
            self.capturedLivePhoto?.cleanUp()
            self.capturedLivePhoto = output
            if let output, let still = UIImage(contentsOfFile: output.stillURL.path) {
                self.capturedImage = still
                self.pendingProcessedImage = still
            }
            self.isProcessingCapture = false
            self.autoSaveIfReady()
            if output == nil {
                self.statusMessage = LanguageManager.text("Couldn’t capture this Live Photo.")
            }
        }
    }
}


// Keep the app's camera controls anchored while iOS presents its hardware overlay.
extension CameraService: AVCaptureSessionControlsDelegate {
    nonisolated func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    nonisolated func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    nonisolated func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    nonisolated func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
