// SPDX-License-Identifier: MPL-2.0
// Ported from the original Hibiscus CameraView.
import AVKit
import Photos
import SwiftUI

struct CameraScreen: View {
    @Environment(FilmSession.self) private var film
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("grid") private var grid = false
    @State private var showsLibrary = false
    @State private var capturedStock: Stock?
    @ObservedObject var camera: CameraService
    @State private var showsExposure = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hingePose = CameraHingePose.ordinary
    @State private var captureDevelopmentProgress: CGFloat = 1
    @State private var captureLivePhotoPreview: PHLivePhoto?
    @State private var livePlaybackRequested = false
    @State private var livePreviewFailed = false
    @State private var captureAnimationTask: Task<Void, Never>?
    @State private var shareVariant: CameraExportVariant?
    @State private var shareItem: CameraShareItem?
    let isActive: Bool
    let navigationSize: CGSize
    @Binding var navigationShutter: CGRect?
    @State private var showsLiveGrading = false
    @State private var gradeSurface = PadSurface.style
    @State private var choosingAccentHue = false

    private var hpanControlRotation: Angle {
        .degrees(camera.hpanEnabled ? Double(camera.hpanOrientation.rawValue) : 0)
    }

    private func startCamera() {
        camera.updateProfile(stock: film.active, recipe: film.recipe)
        camera.restoreFramingRatio(film.ratio)
        camera.start(live: film.live, lockFocus: film.lockFocus)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.065).ignoresSafeArea()

            if let captured = camera.capturedImage {
                captureResult(captured)
            } else {
                liveCamera.overlay {
                    if camera.isConfiguringLivePhoto && isActive {
                        ProgressView("Preparing Live Photo…")
                            .controlSize(.small)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .hibiscusGlass(in: Capsule())
                            .allowsHitTesting(false)
                    } else if camera.loadingFilm && camera.authorizationState == .authorized && isActive {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Loading color profile: \(film.active.name)…").font(.subheadline)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .hibiscusGlass(in: Capsule())
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let status = camera.statusMessage {
                StatusPill(message: status)
                    .zIndex(10)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) {
                            camera.statusMessage = nil
                        }
                    }
                    .task(id: status) {
                        do {
                            try await Task.sleep(for: .seconds(3))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled, camera.statusMessage == status else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            camera.statusMessage = nil
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: camera.statusMessage)
        .tint(.white)
        .observeCameraHinge($hingePose)
        .task(id: isActive && scenePhase != .background) {
            if isActive && scenePhase != .background {
                if camera.capturedImage == nil { startCamera() }
            } else {
                camera.stop()
            }
        }
        .sheet(isPresented: $showsLibrary) { FilmLibrary() }
        .sheet(item: $shareItem) { item in
            PhotoShareSheet(file: item.file, livePhoto: item.livePhoto) { _, error in
                if error != nil { camera.statusMessage = LanguageManager.text("This photo could not be shared.") }
            }
        }
        .task(id: shareVariant) {
            if let shareVariant { await shareCapture(shareVariant) }
        }
        .onChange(of: camera.isCapturing) { if camera.isCapturing { capturedStock = film.active } }
        .onChange(of: film.active) { camera.updateProfile(stock: film.active, recipe: film.recipe) }
        .onChange(of: film.recipe) { camera.updateProfile(stock: film.active, recipe: film.recipe) }
        .onChange(of: camera.framingRatio) { film.ratio = camera.framingRatio }
        .onChange(of: camera.selectedMotion) { film.live = camera.selectedMotion == .livePhoto }
        .onChange(of: camera.capturedImage != nil) { _, hasCapture in
            captureAnimationTask?.cancel()
            guard hasCapture else {
                captureDevelopmentProgress = 1
                captureLivePhotoPreview = nil
                livePlaybackRequested = false
                livePreviewFailed = false
                return
            }
            if reduceMotion {
                captureDevelopmentProgress = 1
                return
            }
            captureDevelopmentProgress = 0
            captureAnimationTask = Task { @MainActor in
                do {
                    let start = ContinuousClock.now
                    let duration = Duration.seconds(1.05)
                    repeat {
                        try await Task.sleep(for: .milliseconds(33))
                        captureDevelopmentProgress = min(1, (ContinuousClock.now - start) / duration)
                    } while captureDevelopmentProgress < 1
                } catch { return }
            }
        }
        .onDisappear {
            showsLiveGrading = false
            choosingAccentHue = false
            captureAnimationTask?.cancel()
            if camera.capturedImage != nil { captureDevelopmentProgress = 1 }
            camera.stop()
        }
    }

    private var liveCamera: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let panoramic = camera.hpanEnabled
            let layout = CameraWorkspace(cameraFrame: proxy.frame(in: .named(CameraWorkspace.navigationSpace)),
                                         navigationSize: navigationSize, portraitRatio: camera.framingRatio.portraitRatio,
                                         fold: CameraWorkspace.division(in: proxy, pose: hingePose),
                                         pose: hingePose, exposureVisible: showsExposure)
            let finder = panoramic ? HPan.finder(in: layout.finder) : layout.finder
            let width = finder.width
            let height = finder.height
            let showRotationPrompt = panoramic && !camera.hpanOrientation.isLandscape && !showsLiveGrading

            ZStack(alignment: .top) {
                ZStack(alignment: .top) {
                    cameraPreview
                        .scaleEffect(camera.isSwitchingCamera ? 1.012 : 1)
                        .blur(radius: camera.isSwitchingCamera ? 1.2 : 0)
                        .overlay {
                            if camera.isSwitchingCamera { Color.black.opacity(0.13) }
                        }
                        .animation(.easeInOut(duration: 0.28), value: camera.isSwitchingCamera)
                        .frame(width: width, height: height)
                        .clipped()

                    if grid && camera.authorizationState == .authorized {
                        CameraGrid().allowsHitTesting(false)
                    }

                    if camera.doubleExposureEnabled && !showsLiveGrading {
                        Text(camera.awaitingSecondExposure ? LocalizedStringKey("Second exposure") : "First exposure")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.62), in: Capsule())
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 44)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: width, height: height)
                .position(x: finder.midX, y: finder.midY)

                ZStack {
                    if showRotationPrompt {
                        Label("Rotate to landscape", systemImage: "rotate.right")
                            .font(.footnote.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.68), in: Capsule())
                            .padding(.horizontal, 6)
                            .padding(.bottom, min(30, height * 0.10))
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
                .frame(width: width, height: height, alignment: .bottom)
                .position(x: finder.midX, y: finder.midY)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showRotationPrompt)

                Group {
                    if layout.mode == .waistLevel {
                        waistLevelControls
                            .frame(width: layout.controls.width, height: layout.controls.height)
                            .position(x: layout.controls.midX, y: layout.controls.midY)
                        if !panoramic { zoomControl.position(layout.lens) }
                    } else {
                        cameraTopBar()
                            .frame(width: max(1, (layout.mode == .portrait ? size.width : layout.finder.width) - 24))
                            .position(x: layout.finder.midX, y: layout.finder.minY + 28)
                        if !panoramic && layout.verticalDivision == nil { zoomControl.position(layout.lens) }
                        cameraControls(layout)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                            .frame(width: layout.controls.width, height: layout.controls.height, alignment: .bottom)
                            .position(x: layout.controls.midX, y: layout.controls.midY)
                    }
                }
                .opacity(showsLiveGrading ? 0 : 1)
                .allowsHitTesting(!showsLiveGrading)
                .accessibilityHidden(showsLiveGrading)
                .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: showsLiveGrading)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { setGrading(false) }
                    .allowsHitTesting(showsLiveGrading)
                    .accessibilityHidden(true)

                liveGradingControls(padSize: layout.padSize, division: layout.verticalDivision)
                    .offset(y: showsLiveGrading || reduceMotion ? 0 : 10)
                    .rotationEffect(hpanControlRotation)
                    .position(panoramic && camera.hpanOrientation.isLandscape && layout.mode == .portrait
                              ? CGPoint(x: finder.midX, y: finder.midY) : layout.gradingCenter)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: camera.hpanOrientation)
                    .opacity(showsLiveGrading ? 1 : 0)
                    .allowsHitTesting(showsLiveGrading)
                    .accessibilityHidden(!showsLiveGrading)
                    .animation(reduceMotion ? .easeOut(duration: 0.12)
                        : .smooth(duration: 0.28).delay(showsLiveGrading ? 0.055 : 0), value: showsLiveGrading)
                    .accessibilityAction(.escape) { setGrading(false) }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .onChange(of: isActive && !showsLiveGrading ? layout.navigationShutter : nil, initial: true) {
                navigationShutter = isActive && !showsLiveGrading ? layout.navigationShutter : nil
            }
            .onDisappear { navigationShutter = nil }
            .onCameraCaptureEvent(isEnabled: isActive && scenePhase == .active && !showsLibrary
                                  && !showsLiveGrading && camera.shutterReady) { event in
                if event.phase == .ended { camera.capture() }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: camera.selectedRatio)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: layout.mode)
        }
    }

    private var zoomControl: some View {
        Button(action: camera.selectNextLens) {
            Text(camera.lensLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 36, minHeight: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zoom \(camera.lensLabel)")
        .accessibilityHint("Cycles through the available lenses")
        .disabled(camera.changingMode || !camera.isRunning || camera.lensOptions.count < 2)
        .padding(2)
        .hibiscusGlass(tint: .black.opacity(0.18), in: Capsule())
        .frame(minWidth: 40, minHeight: 34)
        .zIndex(2)
    }

    @ViewBuilder
    private var cameraPreview: some View {
        switch camera.authorizationState {
        case .authorized:
            CameraMetalPreview(
                renderer: camera.previewRenderer,
                isActive: isActive && (!camera.isCapturing || camera.isRecordingLivePhoto),
                onPreviewLayerReady: camera.attachPreviewLayer
            )
                .background(Color(white: 0.025))
        case .unknown:
            ZStack {
                Color(white: 0.04)
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Preparing camera…").font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        case .denied:
            permissionState(
                title: "Camera access is off",
                message: "Allow camera access in Settings to shoot with Hibiscus Film.",
                showsSettings: true
            )
        case .unavailable:
            permissionState(
                title: "Camera unavailable",
                message: "A camera isn’t available on this device.",
                showsSettings: false
            )
        }
    }

    private func cameraTopBar(compact: Bool = false) -> some View {
        HibiscusGlassContainer(spacing: 7) {
            HStack(spacing: 7) {
                if !camera.hpanEnabled {
                    flashTopControl
                    livePhotoTopControl
                }
                if !compact { Spacer() }
                ratioTopControl
                if !camera.hpanEnabled { qualityTopControl }
                adjustTopControl
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: film.active.id)
    }

    private func setGrading(_ open: Bool) {
        if !open { choosingAccentHue = false }
        showsLiveGrading = open
    }

    private var adjustTopControl: some View {
        Button { setGrading(true) } label: {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .hibiscusGlassButtonStyle()
        .accessibilityLabel("Adjust live grading")
        .disabled(camera.isCapturing || camera.isProcessingCapture)
    }

    private var flashTopControl: some View {
        Menu {
            Picker("Flash", selection: $camera.flashMode) {
                ForEach(CaptureFlashMode.allCases) { mode in
                    Label {
                        Text(LocalizedStringKey(mode.rawValue))
                    } icon: {
                        Image(systemName: mode.systemImage)
                    }
                    .tag(mode)
                }
            }
        } label: {
            Image(systemName: camera.flashMode.systemImage)
                .frame(width: 18, height: 18)
        }
        .hibiscusGlassButtonStyle()
        .accessibilityLabel("Flash, " + camera.flashMode.rawValue)
        .disabled(!camera.flashAvailable)
        .opacity(camera.flashAvailable ? 1 : 0.46)
    }

    private var livePhotoTopControl: some View {
        Button {
            camera.toggleLivePhoto()
        } label: {
            Group {
                if camera.isConfiguringLivePhoto {
                    ProgressView().controlSize(.mini)
                } else {
                    // Apple's Live Photo glyph is used only for the Live Photo
                    // capture state it represents.
                    Image(systemName: !camera.hpanEnabled && camera.selectedMotion == .livePhoto ? "livephoto" : "livephoto.slash")
                }
            }
            .frame(width: 18, height: 18)
        }
        .hibiscusGlassButtonStyle()
        .accessibilityLabel(!camera.hpanEnabled && camera.selectedMotion == .livePhoto ? "Live Photo on" : "Live Photo off")
        .disabled(camera.hpanEnabled || camera.changingMode || !camera.isRunning || camera.isConfiguringLivePhoto || camera.selectedFormat == .raw)
        .opacity(camera.selectedFormat == .processed ? 1 : 0.46)
    }

    private var ratioTopControl: some View {
        Menu {
            Section("Ratio") {
                Picker("Photo Ratio", selection: Binding(get: { camera.selectedRatio }, set: camera.selectRatio)) {
                    ForEach(CameraAspectRatio.allCases) { ratio in
                        Text(ratio.rawValue)
                            .tag(ratio)
                            .disabled(ratio == .hpan && (!camera.hasUltraWide || !camera.isRunning))
                    }
                }
                .disabled(camera.changingMode || camera.isSwitchingCamera || camera.isCapturing ||
                          camera.isConfiguringLivePhoto || camera.isProcessingCapture)
            }
            if !camera.hpanEnabled {
                Toggle("Double Exposure", isOn: Binding(get: { camera.doubleExposureEnabled }, set: camera.setDoubleExposure))
                    .disabled(!camera.canUseDoubleExposure || camera.isCapturing || camera.isProcessingCapture)
            }
        } label: {
            HStack(spacing: 5) {
                Text(camera.selectedRatio.rawValue)
                if camera.doubleExposureEnabled { Image(systemName: "square.on.square") }
            }
            .font(.caption2.weight(.bold))
            .frame(minHeight: 18)
        }
        .hibiscusGlassButtonStyle()
    }

    private var qualityTopControl: some View {
        Menu {
            Section("Current") {
                Button(selectedCaptureQualityTitle) { }
                    .disabled(true)
            }
            Menu("HEIF") {
                ForEach(camera.availableMegapixels, id: \.self) { megapixels in
                    Button {
                        camera.selectCapture(format: .processed, megapixels: megapixels)
                    } label: {
                        if camera.selectedFormat == .processed,
                           camera.selectedMegapixels == megapixels {
                            Label("\(megapixels) MP", systemImage: "checkmark")
                        } else {
                            Text("\(megapixels) MP")
                        }
                    }
                }
            }
            Menu("RAW") {
                if camera.availableRawMegapixels.isEmpty {
                    Button("Unavailable") { }
                        .disabled(true)
                } else {
                    ForEach(camera.availableRawMegapixels, id: \.self) { megapixels in
                        Button {
                            camera.selectCapture(format: .raw, megapixels: megapixels)
                        } label: {
                            if camera.selectedFormat == .raw,
                               camera.selectedMegapixels == megapixels {
                                Label("\(megapixels) MP", systemImage: "checkmark")
                            } else {
                                Text("\(megapixels) MP")
                            }
                        }
                    }
                }
            }
            .disabled(camera.availableRawMegapixels.isEmpty)
        } label: {
            topSettingLabel(camera.isRunning ? "\(camera.selectedMegapixels) MP" : "MP")
        }
        .hibiscusGlassButtonStyle()
        .disabled(camera.hpanEnabled || camera.changingMode || !camera.isRunning)
    }

    private var selectedCaptureQualityTitle: String {
        camera.selectedFormat == .raw
            ? "RAW \(camera.selectedMegapixels) MP"
            : "HEIF \(camera.selectedMegapixels) MP"
    }

    private func topSettingLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .frame(minWidth: 24, minHeight: 18)
    }

    private var stockButton: some View {
        Button {
            showsLibrary = true
        } label: {
            HStack(spacing: 6) {
                StockStyleMark(stock: film.active, size: 26)
                    .frame(width: 29, height: 29)
                VStack(alignment: .leading, spacing: 0) {
                    Text(film.active.name)
                        .font(.subheadline.weight(.semibold))
                    Text(LocalizedStringKey(film.active.family))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the film library")
    }

    private var waistLevelControls: some View {
        VStack(spacing: 0) {
            if camera.hpanEnabled { cameraTopBar().padding(.top, 6) }
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    GeometryReader { space in
                        let side = min(112, space.size.height * 0.60, space.size.width * 0.24)
                        if let icon = UIImage.hibiscusAppIcon, side >= 28 {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: side, height: side)
                                .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
                                .position(x: space.size.width / 2, y: space.size.height / 2)
                                .accessibilityHidden(true)
                        }
                    }
                    waistLevelSettings.fixedSize(horizontal: false, vertical: true)
                }
                ScrollView { waistLevelSettings }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var waistLevelSettings: some View {
        VStack(spacing: 4) {
            if !camera.hpanEnabled { cameraTopBar(compact: true) }
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    stockButton
                    exposureButton
                    gridButton
                }
                expandedExposure
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .hibiscusGlass(tint: cameraSurfaceTint.opacity(0.075),
                           in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .frame(maxWidth: 420)
    }

    private func cameraControls(_ layout: CameraWorkspace) -> some View {
        Group {
            if let division = layout.verticalDivision {
                // Each half has matching edge insets and a centered shutter-height control row.
                HStack(spacing: 0) {
                    VStack(spacing: 6) {
                        HStack {
                            stockButton
                            if !camera.hpanEnabled { zoomControl }
                        }
                        .frame(minHeight: CameraWorkspace.shutterDiameter)
                        expandedExposure
                    }
                    .frame(maxHeight: .infinity)
                    .modifier(CameraDeckSurface(tint: cameraSurfaceTint))
                    .frame(width: division.minX - 20)

                    Spacer().frame(width: division.width + 20)

                    captureControlRow
                        .frame(maxHeight: .infinity)
                        .modifier(CameraDeckSurface(tint: cameraSurfaceTint))
                }
            } else {
                VStack(spacing: 6) {
                    stockButton
                    expandedExposure
                    captureControlRow
                }
                .modifier(CameraDeckSurface(tint: cameraSurfaceTint))
            }
        }
    }

    private var cameraSurfaceTint: Color {
        film.active.tint
    }

    private var accentTint: Color {
        film.recipe.usesSceneAccent ? camera.sceneAccent.color : Color(hue: film.recipe.hue, saturation: 0.72, brightness: 0.94)
    }

    private func liveGradingControls(padSize: CGFloat, division: CGRect?) -> some View {
        let stockMode = gradeSurface == .style
        let strength = Binding(
            get: { stockMode ? film.recipe.strength : film.recipe.accentStrength },
            set: { if stockMode { film.recipe.strength = $0 } else { film.recipe.accentStrength = $0 } }
        )
        return HStack(alignment: .top, spacing: 8) {
            livePad(.style, size: padSize)
            if let division { Color.clear.frame(width: division.width, height: 1).allowsHitTesting(false) }
            livePad(.accent, size: padSize)
            PadStrengthSlider(title: stockMode ? "Stock strength" : "Accent strength",
                              value: strength, tint: stockMode ? film.active.tint : accentTint)
                .frame(height: padSize)
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: gradeSurface)
    }

    private func livePad(_ kind: PadSurface, size: CGFloat) -> some View {
        let stock = kind == .style
        return VStack(spacing: 0) {
            HibiscusPad(
                kind: kind,
                tint: stock ? film.active.tint : accentTint,
                point: stock ? film.recipe.point : film.recipe.accentPoint,
                onChange: { point in
                    gradeSurface = kind
                    if stock { film.recipe.point = point } else { film.recipe.accentPoint = point }
                },
                editing: { if $0 { gradeSurface = kind } },
                onReset: {
                    gradeSurface = kind
                    if stock {
                        film.recipe.point = film.active.recipe.point
                        film.recipe.strength = film.active.recipe.strength
                    } else {
                        film.recipe.accentPoint = film.active.recipe.accentPoint
                        film.recipe.accentStrength = film.active.recipe.accentStrength
                        film.recipe.hue = film.active.recipe.hue
                        film.recipe.automaticAccent = film.active.recipe.automaticAccent
                    }
                }
            )
            .frame(width: size, height: size)
            HStack(spacing: 4) {
                Button { gradeSurface = kind } label: { stock ? Text(verbatim: film.active.name) : Text("Accent") }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(gradeSurface == kind ? .primary : .secondary)
                    .accessibilityAddTraits(gradeSurface == kind ? .isSelected : [])
                if !stock {
                    Button {
                        gradeSurface = .accent
                        choosingAccentHue = true
                    } label: {
                        Circle().fill(accentTint)
                            .frame(width: ControlDot.handle, height: ControlDot.handle)
                            .frame(width: 32, height: 32)
                    }
                    .popover(isPresented: $choosingAccentHue) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Automatic", isOn: Binding(get: { film.recipe.usesSceneAccent }, set: { enabled in
                                if !enabled {
                                    let rgb = camera.sceneAccent
                                    film.recipe.hue = AccentAnalyzer.rgbToHSB(red: rgb.red, green: rgb.green, blue: rgb.blue).hue
                                }
                                film.recipe.automaticAccent = enabled
                            }))
                            if !film.recipe.usesSceneAccent {
                                Slider(value: Binding(get: { film.recipe.hue }, set: { film.recipe.hue = $0 }), in: 0...1)
                                    .tint(accentTint)
                                    .accessibilityLabel("Accent hue")
                            }
                        }
                        .frame(width: 180)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                    }
                    .accessibilityLabel("Select accent color")
                }
            }
            .frame(height: 22)
        }.frame(width: size)
    }

    @ViewBuilder
    private var expandedExposure: some View {
        if showsExposure {
            ExposureSlider(value: Binding(get: { camera.exposure }, set: camera.setExposure), range: camera.exposureRange)
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        }
    }

    private var captureControlRow: some View {
        HStack {
            exposureButton
            Spacer()
            CameraShutterButton(camera: camera, diameter: CameraWorkspace.shutterDiameter)
            Spacer()
            gridButton
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
    }

    private var exposureButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { showsExposure.toggle() }
        } label: {
            Image(systemName: "plusminus.circle")
                .font(.system(size: 21, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .hibiscusGlassButtonStyle(.clear)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(showsExposure ? "Expanded" : "Collapsed")
    }

    private var gridButton: some View {
        Button {
            grid.toggle()
        } label: {
            Image(systemName: "grid")
                .font(.system(size: 21, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .hibiscusGlassButtonStyle(.clear)
        .accessibilityLabel("Composition grid")
        .accessibilityValue(grid ? "On" : "Off")
        .accessibilityAddTraits(grid ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: grid)
    }

    private func permissionState(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        showsSettings: Bool
    ) -> some View {
        ZStack {
            Color(white: 0.04)
            VStack(spacing: 10) {
                Image(systemName: "camera.fill").font(.title)
                Text(title).font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                if showsSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .hibiscusGlassButtonStyle(tint: .white)
                    .foregroundStyle(.black)
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .hibiscusGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(20)
        }
    }

    private func captureResult(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            let displayImage = camera.capturedPreviewImage ?? image
            let imageRatio = max(0.01, displayImage.size.width / displayImage.size.height)
            let maximumWidth = max(1, proxy.size.width - 24)
            let maximumHeight = max(1, proxy.size.height - 170)
            let photoWidth = min(maximumWidth, maximumHeight * imageRatio)
            let photoHeight = photoWidth / imageRatio
            let shadowDevelopment = phaseProgress(captureDevelopmentProgress, from: 0, to: 0.42)
            let midtoneDevelopment = phaseProgress(captureDevelopmentProgress, from: 0.25, to: 0.78)
            let highlightDevelopment = phaseProgress(captureDevelopmentProgress, from: 0.62, to: 1)

            ZStack(alignment: .bottom) {
                ZStack(alignment: .top) {
                    VStack(spacing: 10) {
                        Group {
                            if livePlaybackRequested, let captureLivePhotoPreview {
                                HibiscusLivePhotoView(livePhoto: captureLivePhotoPreview) { livePlaybackRequested = false }
                                    .allowsHitTesting(false)
                            } else if captureDevelopmentProgress >= 1 {
                                PhotoFitView(image: displayImage)
                            } else {
                                ZStack {
                                    // Instant-film development establishes density first,
                                    // followed by midtone color and finally clean highlights.
                                    PhotoFitView(image: displayImage)
                                        .saturation(0.06)
                                        .contrast(0.58)
                                        .brightness(-0.24)
                                        .overlay {
                                            Color(red: 0.055, green: 0.065, blue: 0.06)
                                                .opacity(0.28)
                                        }

                                    PhotoFitView(image: displayImage)
                                        .saturation(0.22)
                                        .contrast(1.16)
                                        .blendMode(.multiply)
                                        .opacity(0.78 * shadowDevelopment)

                                    PhotoFitView(image: displayImage)
                                        .saturation(0.72)
                                        .contrast(1.04)
                                        .blendMode(.softLight)
                                        .opacity(0.72 * midtoneDevelopment)

                                    PhotoFitView(image: displayImage)
                                        .opacity(highlightDevelopment)
                                }
                            }
                        }
                            .frame(width: photoWidth, height: photoHeight)
                            .background(.black)
                            .compositingGroup()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(.white.opacity(0.10), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.26), radius: 10, y: 4)
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if camera.capturedHasMotion {
                                    if livePlaybackRequested && captureLivePhotoPreview == nil {
                                        ProgressView("Loading Live Photo…")
                                            .controlSize(.small)
                                            .padding(10)
                                            .background(.black.opacity(0.70), in: Capsule())
                                            .padding(10)
                                    } else if !livePlaybackRequested {
                                        Button(action: playCapture) {
                                            Image(systemName: "livephoto").frame(width: 44, height: 44)
                                        }
                                        .hibiscusGlassButtonStyle()
                                        .accessibilityLabel("Play Live Photo")
                                        .padding(10)
                                    }
                                }
                            }
                            .onTapGesture(perform: playCapture)
                            .task(id: camera.capturedLivePhoto?.motionURL) {
                                captureLivePhotoPreview = nil
                                livePreviewFailed = false
                                guard let output = camera.capturedLivePhoto else { return }
                                let preview = await LivePhotoPreviewFactory.make(from: output, placeholder: displayImage)
                                guard !Task.isCancelled else { return }
                                captureLivePhotoPreview = preview
                                livePreviewFailed = preview == nil
                                if livePreviewFailed && livePlaybackRequested { reportLivePreviewFailure() }
                            }
                            .onChange(of: camera.isProcessingCapture) {
                                if livePlaybackRequested && !camera.isProcessingCapture && camera.capturedLivePhoto == nil {
                                    reportLivePreviewFailure()
                                }
                            }

                        captureMetadata
                    }
                }
                .frame(width: maximumWidth, height: photoHeight + 56, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                HibiscusGlassContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        resultButton("Retake", systemImage: "arrow.counterclockwise", action: {
                            camera.updateProfile(stock: film.active, recipe: film.recipe)
                            camera.retake(lockFocus: film.lockFocus)
                        })
                            .disabled(camera.isSavingCapture || camera.isProcessingCapture || shareVariant != nil)
                            .opacity(camera.isSavingCapture ? 0.52 : 1)
                        captureExportMenu
                    }
                }
                .frame(height: 46)
                .padding(.bottom, 26)
            }
            .padding(.horizontal, 12)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var captureExportMenu: some View {
        Menu {
            Menu {
                ForEach(CameraExportVariant.allCases) { variant in
                    let title = variant.title(livePhoto: camera.capturedHasMotion)
                    let saved = camera.savedVariants.contains(variant)
                    Button {
                        camera.saveCapture([variant])
                    } label: {
                        if saved { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                    .disabled(saved)
                }
            } label: { Label("Save Photo", systemImage: "square.and.arrow.down") }
            Menu {
                ForEach(CameraExportVariant.allCases) { variant in
                    Button(variant.title(livePhoto: camera.capturedHasMotion)) { shareVariant = variant }
                }
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .hibiscusGlassButtonStyle()
        .disabled(!camera.canExportCapture || shareVariant != nil)
    }

    private func shareCapture(_ variant: CameraExportVariant) async {
        defer { shareVariant = nil }
        guard let image = camera.captureForExport() else { return }
        do {
            if variant == .photo, let output = camera.capturedLivePhoto {
                let live: PHLivePhoto?
                if let preview = captureLivePhotoPreview {
                    live = preview
                } else if let still = camera.capturedImage {
                    live = await LivePhotoPreviewFactory.make(from: output, placeholder: still)
                } else {
                    live = nil
                }
                try Task.checkCancellation()
                guard let live else { throw CocoaError(.coderInvalidValue) }
                shareItem = CameraShareItem(livePhoto: live)
            } else {
                let file = try await image.file(for: variant)
                try Task.checkCancellation()
                shareItem = CameraShareItem(file: file)
            }
        } catch {
            if !Task.isCancelled { camera.statusMessage = LanguageManager.text("This photo could not be shared.") }
        }
    }

    private func playCapture() {
        guard camera.capturedHasMotion, !livePlaybackRequested else { return }
        if livePreviewFailed || (camera.capturedLivePhoto == nil && !camera.isProcessingCapture) {
            reportLivePreviewFailure()
            return
        }
        livePlaybackRequested = true
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func reportLivePreviewFailure() {
        livePlaybackRequested = false
        camera.statusMessage = LanguageManager.text("This Live Photo could not be played.")
    }

    private var captureMetadata: some View {
        let stock = capturedStock ?? film.active
        return HStack(spacing: 9) {
            StockStyleMark(stock: stock, size: 26)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(stock.name)
                    .font(.caption.weight(.semibold))
                Text(LocalizedStringKey(stock.family))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                if captureDevelopmentProgress < 1 {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(developmentStage)
                    }
                } else if camera.isProcessingCapture {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(camera.capturedHasMotion ? "Processing Live Photo…" : "Rendering full-resolution photo…")
                    }
                } else if camera.isSavingCapture {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Saving")
                    }
                } else if shareVariant != nil {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Preparing to Share…")
                    }
                } else {
                    Text("Ready")
                }
                Text(captureTechnicalMetadata)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 11)
        .frame(height: 46)
        .hibiscusGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    private var developmentStage: LocalizedStringKey {
        switch captureDevelopmentProgress {
        case ..<0.30: "Forming shadows"
        case ..<0.70: (capturedStock ?? film.active).family == "Monochrome" ? "Building midtones" : "Developing color"
        default: "Settling highlights"
        }
    }

    private var captureTechnicalMetadata: String {
        if camera.hpanEnabled, let image = camera.capturedImage?.cgImage {
            return "HPan0.5 · \(image.width) × \(image.height)"
        }
        let live = camera.capturedLivePhoto == nil ? "" : " · LIVE"
        return "\(camera.selectedMegapixels) MP · \(camera.selectedFormat.rawValue) · \(camera.selectedRatio.rawValue)\(live)"
    }

    private func resultButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .hibiscusGlassButtonStyle()
    }

    private func phaseProgress(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(1, max(0, (progress - start) / (end - start)))
    }
}

private struct CameraShareItem: Identifiable {
    let id = UUID()
    var file: PhotoExportFile? = nil
    var livePhoto: PHLivePhoto? = nil
}

private struct CameraGrid: View {
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer()
                Rectangle().fill(.white.opacity(0.22)).frame(width: 0.5)
                Spacer()
                Rectangle().fill(.white.opacity(0.22)).frame(width: 0.5)
                Spacer()
            }
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(.white.opacity(0.22)).frame(height: 0.5)
                Spacer()
                Rectangle().fill(.white.opacity(0.22)).frame(height: 0.5)
                Spacer()
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 1)
    }
}

private struct CameraDeckSurface: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .hibiscusGlass(tint: tint.opacity(0.075),
                           in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct CameraShutterButton: View {
    @ObservedObject var camera: CameraService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let diameter: CGFloat

    var body: some View {
        let awaitingLandscape = camera.hpanEnabled && !camera.hpanOrientation.isLandscape
        Button(action: camera.capture) {
            LivePhotoShutter(
                isRecordingLivePhoto: camera.isRecordingLivePhoto,
                isProcessingCapture: camera.isProcessingCapture
            )
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!camera.shutterReady)
        .opacity(camera.hpanEnabled && !camera.shutterReady ? 0.48 : 1)
        .animation(camera.hpanEnabled ? .easeInOut(duration: reduceMotion ? 0.15 : 0.24) : nil,
                   value: camera.shutterReady)
        .accessibilityHint(awaitingLandscape ? "Hold the iPhone horizontally to take a panorama" : "")
        .accessibilityLabel("Shutter")
        .accessibilityValue(
            camera.isRecordingLivePhoto ? Text("Capturing Live Photo") : Text("")
        )
    }
}

private struct LivePhotoShutter: View {
    let isRecordingLivePhoto: Bool
    let isProcessingCapture: Bool

    var body: some View {
        ZStack {
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular.tint(isRecordingLivePhoto ? Color.hibiscusAccent : .clear).interactive(), in: Circle())
                Circle().fill(.white)
                    .padding(7)
            } else {
                Circle().fill(.white)
                Circle().stroke(.black.opacity(0.78), lineWidth: 3)
                    .padding(5)
                LivePhotoCaptureRing(isRecording: isRecordingLivePhoto)
            }

            if isProcessingCapture && !isRecordingLivePhoto {
                ProgressView()
                    .controlSize(.small)
                    .tint(.black)
            }
        }
    }
}

private struct LivePhotoCaptureRing: View {
    let isRecording: Bool

    @State private var recordingStartedAt: Date?
    @State private var completionProgress: CGFloat = 0
    @State private var progressOpacity: Double = 0
    @State private var completionTask: Task<Void, Never>?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isRecording)) { timeline in
            ZStack {
                Circle()
                    .stroke(Color.hibiscusAccent.opacity(0.72), lineWidth: 5)

                Circle()
                    .trim(from: 0, to: max(0.012, displayedProgress(at: timeline.date)))
                    .stroke(
                        Color.hibiscusAccent,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .opacity(progressOpacity)
        }
        .allowsHitTesting(false)
        .onAppear {
            if isRecording {
                beginProgress()
            }
        }
        .onChange(of: isRecording) { _, recording in
            recording ? beginProgress() : completeProgress()
        }
        .onDisappear {
            completionTask?.cancel()
        }
        .accessibilityHidden(true)
    }

    private func beginProgress() {
        completionTask?.cancel()
        recordingStartedAt = Date()
        completionProgress = 0
        progressOpacity = 1
    }

    private func completeProgress() {
        guard progressOpacity > 0 else { return }
        completionTask?.cancel()
        completionProgress = displayedProgress(at: Date())
        recordingStartedAt = nil
        withAnimation(.easeOut(duration: 0.18)) {
            completionProgress = 1
        }

        completionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(0.20))
            } catch {
                return
            }
            guard !Task.isCancelled, !isRecording else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                progressOpacity = 0
            }
            do {
                try await Task.sleep(for: .seconds(0.18))
            } catch {
                return
            }
            guard !Task.isCancelled, !isRecording else { return }
            completionProgress = 0
        }
    }

    private func displayedProgress(at date: Date) -> CGFloat {
        guard let recordingStartedAt else { return completionProgress }
        let elapsed = max(0, date.timeIntervalSince(recordingStartedAt))
        // This elapsed-time curve never reaches completion on its own. It stays
        // active for however long AVFoundation records, and the real recording
        // completion callback supplies the final segment of the ring.
        return min(0.97, CGFloat(1 - exp(-elapsed / 1.25)))
    }
}
