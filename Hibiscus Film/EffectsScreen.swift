import CoreImage
import Photos
import PhotosUI
import SwiftUI

struct EffectsScreen: View {
    @State private var photo: EffectPhoto?
    @State private var item: PhotosPickerItem?
    @State private var choosing = false
    @State private var importFailed = false

    var body: some View {
        Group {
            if let photo {
                EffectProof(photo: photo, importing: item != nil, choose: { choosing = true }, exit: { self.photo = nil })
                    .id(photo.id)
            } else {
                Button { choosing = true } label: {
                    VStack(spacing: 16) {
                        if let item {
                            ProgressView(EffectPhoto.isLivePhoto(item) ? "Loading Live Photo…" : "Loading photo…")
                        }
                        else {
                            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                            Text("Tap to add a photo").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item != nil)
            }
        }
        .background(Color(white: 0.065).ignoresSafeArea())
        .photosPicker(isPresented: $choosing, selection: $item, matching: .any(of: [.images, .livePhotos]), preferredItemEncoding: .current)
        .task(id: item) {
            guard let item else { return }
            do {
                let replacement = try await EffectPhoto.load(item, preservingMotion: true)
                try Task.checkCancellation()
                photo = replacement
            } catch {
                guard !Task.isCancelled else { return }
                importFailed = true
            }
            self.item = nil
        }
        .alert("This photo could not be opened.", isPresented: $importFailed) { Button("OK") {} }
    }
}

private struct EffectProof: View {
    let photo: EffectPhoto
    let importing: Bool
    let choose: () -> Void
    let exit: () -> Void
    @State private var confirmingExit = false

    private static let engine = HibiscusPrintEngine()
    @State private var effect = PrintEffect.newsprint
    @State private var palettes: [PrintEffect: PrintPalette] = [:]
    @State private var choosingInk = false
    @State private var strengths: [PrintEffect: Double] = [:]
    @State private var plate: CGImage?
    @State private var plateKey: Recipe?
    @State private var samples: [PrintEffect: (inks: PrintPalette, image: CGImage)] = [:]
    @State private var export: Destination?
    @State private var file: PhotoExportFile?
    @State private var sharedLivePhoto: PHLivePhoto?
    @State private var renderedLive: (key: Recipe, result: EffectLivePhoto)?
    @State private var playingLive = false
    @State private var message: String?

    private enum Destination { case save, share, play }
    private struct Recipe: Hashable {
        let effect: PrintEffect
        let inks: PrintPalette
        // Other effects can blend their finished plate interactively in SwiftUI.
        let fill: Double
    }

    private func thumbnailKey(_ style: PrintEffect) -> Recipe {
        Recipe(effect: style, inks: palettes[style] ?? style.defaultPalette, fill: 1)
    }

    private var recipe: Recipe {
        Recipe(effect: effect, inks: palettes[effect] ?? effect.defaultPalette,
               fill: effect.usesSpatialIntensity ? strength.wrappedValue : 1)
    }

    private var visiblePlate: CGImage? {
        if plateKey == recipe { return plate }
        if effect.usesSpatialIntensity, plateKey?.effect == effect { return plate }
        guard recipe.fill == 1, let sample = samples[effect], sample.inks == recipe.inks else { return nil }
        return sample.image
    }
    private var strength: Binding<Double> {
        Binding(get: { strengths[effect, default: 1] }, set: { strengths[effect] = $0 })
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { confirmingExit = true } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .hibiscusGlass(interactive: true, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Exit editing")
                .disabled(export != nil || importing)
                .alert("Exit editing?", isPresented: $confirmingExit) {
                    Button("Keep Editing", role: .cancel) {}
                    Button("Exit", role: .destructive, action: exit)
                } message: {
                    Text("Unsaved edits will be discarded. Your original photo will be kept.")
                }
                Spacer()
                if export == .play || (photo.motion != nil && export != nil) {
                    ProgressView("Loading Live Photo…").controlSize(.small)
                } else if export != nil || importing {
                    ProgressView().controlSize(.small)
                }
                if photo.motion != nil {
                    Button { export = .play } label: {
                        Image(systemName: "livephoto").frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play Live Photo")
                    .disabled(export != nil || importing || plateKey != recipe)
                }
                Menu {
                    Button { export = .save } label: {
                        Label(photo.motion != nil ? "Save Live Photo" : "Save Photo", systemImage: "square.and.arrow.down")
                    }
                    Button { export = .share } label: { Label("Share", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 44, height: 44)
                        .hibiscusGlass(interactive: true, in: Circle())
                }
                .buttonStyle(.plain)
                .menuOrder(.fixed)
                .accessibilityLabel("Export effect")
                .disabled(plateKey != recipe || export != nil || importing)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)

            GeometryReader { proxy in
                if proxy.size.height < 340 && proxy.size.width > proxy.size.height {
                    HStack(spacing: 12) {
                        photograph
                        controls.frame(width: min(360, proxy.size.width * 0.44))
                    }
                } else {
                    VStack(spacing: 14) {
                        photograph
                        controls
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.bottom, 8)
        .task(id: recipe) {
            let selection = recipe
            guard let bitmap = photo.preview.cgImage else { return }
            do {
                let result = try await Self.engine.preview(bitmap, effect: selection.effect, inks: selection.inks, intensity: selection.fill)
                try Task.checkCancellation()
                guard selection == recipe else { return }
                plate = result
                plateKey = selection
            } catch {
                if !Task.isCancelled { message = LanguageManager.text("This effect could not be rendered.") }
            }
        }
        .task(id: palettes) {
            guard let bitmap = photo.preview.cgImage else { return }
            for style in PrintEffect.allCases {
                let key = thumbnailKey(style)
                guard !Task.isCancelled else { return }
                if samples[style]?.inks == key.inks { continue }
                if let sample = try? await Self.engine.preview(bitmap, effect: style, inks: key.inks, maxDimension: 600),
                   !Task.isCancelled { samples[style] = (key.inks, sample) }
            }
        }
        .task(id: export) {
            guard let export else { return }
            await exportPhoto(to: export)
        }
        .onChange(of: currentRender) {
            playingLive = false
            renderedLive = nil
        }
        .sheet(item: $file, onDismiss: { sharedLivePhoto = nil }) { item in
            PhotoShareSheet(file: item, livePhoto: sharedLivePhoto) { _, error in
                if error != nil { message = LanguageManager.text("This photo could not be shared.") }
                file = nil
            }
        }
        .overlay(alignment: .top) {
            if let message {
                StatusPill(message: message)
                    .onTapGesture { self.message = nil }
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { self.message = nil }
                    }
            }
        }
    }

    private var currentRender: Recipe {
        Recipe(effect: effect, inks: recipe.inks, fill: strength.wrappedValue)
    }

    private var photograph: some View {
        Group {
            if playingLive, let renderedLive {
                HibiscusLivePhotoView(livePhoto: renderedLive.result.preview) { playingLive = false }
                    .background(.black)
                    .allowsHitTesting(false)
            } else {
                ZStack {
                    Color.white
                    Image(uiImage: photo.preview).resizable()
                    if let visiblePlate {
                        Image(decorative: visiblePlate, scale: 1).resizable()
                            .opacity(effect.usesSpatialIntensity ? 1 : strength.wrappedValue)
                    }
                }
                .drawingGroup(opaque: true, colorMode: .nonLinear)
            }
        }
        .aspectRatio(photo.preview.size, contentMode: .fit)
        .overlay {
            if visiblePlate == nil { ProgressView().accessibilityLabel("Rendering effect") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if export == nil && !importing && !playingLive { choose() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Text(LocalizedStringKey(effect.rawValue))) photograph")
        .accessibilityHint("Tap to replace the photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if export == nil && !importing && !playingLive { choose() } }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            PaperCarousel(finishes: PrintEffect.allCases, thumbnails: samples.mapValues(\.image),
                name: { $0.rawValue }, label: "Effect", fallback: photo.preview,
                selection: Binding(get: { PrintEffect.allCases.firstIndex(of: effect) ?? 0 },
                                   set: { effect = PrintEffect.allCases[$0] }))
                .frame(height: 128)
            Menu {
                Picker("Effect", selection: $effect) {
                    ForEach(PrintEffect.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
            } label: { Text(LocalizedStringKey(effect.rawValue)).font(.headline).frame(minHeight: 44) }
            .padding(.top, -12)
            HStack(spacing: 10) {
                Slider(value: strength, in: 0...1)
                    .tint(effect.stockColor)
                    .accessibilityLabel(effect == .ascii ? Text("Character fill") : Text("Intensity"))
                    .accessibilityValue(strength.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                if !effect.palettes.isEmpty { inkMenu }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
        }
        .disabled(export != nil || importing)
    }

    private var inkMenu: some View {
        Button { choosingInk = true } label: {
            swatch(recipe.inks)
                .frame(minWidth: 48, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ink colors")
        .accessibilityValue(Text(LocalizedStringKey(recipe.inks.rawValue)))
        .popover(isPresented: $choosingInk) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(effect.palettes, id: \.self) { palette in
                        Button {
                            palettes[effect] = palette
                            choosingInk = false
                        } label: {
                            HStack(spacing: 12) {
                                swatch(palette)
                                Text(LocalizedStringKey(palette.rawValue))
                                Spacer(minLength: 4)
                                if recipe.inks == palette { Image(systemName: "checkmark") }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(recipe.inks == palette ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(idealWidth: 250, idealHeight: min(330, CGFloat(effect.palettes.count * 44)))
            .presentationCompactAdaptation(.popover)
        }
    }

    private func swatch(_ palette: PrintPalette) -> some View {
        let pair = palette.colors
        return Group {
            if palette == .photoColors {
                LinearGradient(colors: [.orange, .pink, .indigo, .teal], startPoint: .leading, endPoint: .trailing)
            } else {
                HStack(spacing: 0) {
                    Color(red: pair.dark.red, green: pair.dark.green, blue: pair.dark.blue)
                    Color(red: pair.light.red, green: pair.light.green, blue: pair.light.blue)
                }
            }
        }
        .frame(width: 40, height: 22)
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.35), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private func exportPhoto(to destination: Destination) async {
        let selected = currentRender
        let intensity = selected.fill
        defer { export = nil }
        do {
            if destination == .save {
                let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                try Task.checkCancellation()
                guard permission == .authorized || permission == .limited else {
                    message = LanguageManager.text("Allow photo access in Settings to save this photo.")
                    return
                }
            }
            if photo.motion != nil {
                let result: EffectLivePhoto
                if let renderedLive, renderedLive.key == selected {
                    result = renderedLive.result
                } else {
                    result = try await EffectLivePhoto.render(photo, engine: Self.engine, effect: selected.effect,
                                                             palette: selected.inks, intensity: intensity)
                    try Task.checkCancellation()
                    renderedLive = (selected, result)
                }
                switch destination {
                case .play: playingLive = true
                case .share: sharedLivePhoto = result.preview; file = result.file
                case .save:
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, fileURL: result.file.url, options: nil)
                        request.addResource(with: .pairedVideo, fileURL: result.motionURL, options: nil)
                    }
                    if !Task.isCancelled { message = LanguageManager.text("Saved to Photos.") }
                }
                return
            }
            guard destination != .play else { return }
            let item = try PhotoExportFile.temporary(filename: "Hibiscus-\(selected.effect.rawValue).png")
            try await Self.engine.export(photo.data, effect: selected.effect, inks: selected.inks, intensity: intensity, to: item.url)
            try Task.checkCancellation()
            if destination == .share {
                file = item
            } else {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: item.url, options: nil)
                }
                if !Task.isCancelled { message = LanguageManager.text("Saved to Photos.") }
            }
        } catch {
            if !Task.isCancelled {
                message = destination == .play ? LanguageManager.text("This Live Photo could not be played.")
                    : LanguageManager.text("This photo could not be exported.")
            }
        }
    }
}

private extension PrintEffect {
    var stockColor: Color {
        switch self {
        case .archive: Color(red: 0.82, green: 0.74, blue: 0.63)
        case .fade: Color(white: 0.75)
        case .chromaticDrift: .pink
        case .halftone: Color(red: 0.47, green: 0.76, blue: 0.79)
        case .ascii: Color(red: 0.53, green: 0.94, blue: 0.65)
        case .cyanotype: .cyan
        case .engraving: Color(white: 0.82)
        case .solarized: .orange
        case .newsprint: Color(red: 0.87, green: 0.85, blue: 0.74)
        case .magazine: Color(red: 0.31, green: 0.82, blue: 0.90)
        case .photocopy: Color(white: 0.91)
        case .risograph: Color(red: 1, green: 0.49, blue: 0.63)
        case .duotone: Color(red: 0.96, green: 0.67, blue: 0.37)
        case .fiber: Color(red: 0.80, green: 0.81, blue: 0.72)
        case .warm: Color(red: 0.90, green: 0.72, blue: 0.54)
        }
    }
}
