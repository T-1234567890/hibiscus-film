// SPDX-License-Identifier: MPL-2.0
// Photo and editor layout adapted from Hibiscus GradeView.
import PhotosUI
import SwiftUI

struct GradeScreen: View {
    @EnvironmentObject private var discovery: DiscoveryPreferences
    @Environment(FilmSession.self) private var film
    @State private var selection: PhotosPickerItem?
    @State private var picking = false
    @State private var library = false
    @State private var fullscreen = false
    @State private var comparing = false
    @State private var accentPicker = false
    @State private var surface: PadSurface = .style
    @State private var renderer = GradeRenderer()
    @State private var preview: CGImage?
    @State private var original: CGImage?
    @State private var message: String?
    @State private var loading = false
    @State private var saving = false
    @State private var undo: [Edit] = []
    @State private var redo: [Edit] = []
    @State private var startingEdit: Edit?

    private struct Edit: Equatable { var stock: Stock; var recipe: Recipe }
    private struct Request: Equatable { var revision: Int; var edit: Edit }
    private var current: Edit { Edit(stock: film.active, recipe: film.recipe) }
    private var accent: Color { film.recipe.accentBase.color }
    private var strength: Binding<Double> {
        Binding(get: { surface == .style ? film.recipe.strength : film.recipe.accentStrength }, set: {
            if surface == .style { film.recipe.strength = $0 } else { film.recipe.accentStrength = $0 }
        })
    }

    var body: some View {
        GeometryReader { proxy in
            let available = max(1, proxy.size.height - 34)
            let height = min(available * 0.53, max(280, available - 368), 438)
            if film.source == nil {
                ChoosePhotoPrompt { picking = true }
                    .padding(.bottom, 34)
            } else {
                VStack(spacing: 0) {
                    photoArea.frame(height: height)
                    ScrollView { editor(width: proxy.size.width) }
                        .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background {
            ZStack {
                Color(white: 0.075)
                if film.source != nil {
                    RadialGradient(colors: [film.active.tint.opacity(0.13), .clear], center: .top, startRadius: 30, endRadius: 520)
                }
            }.ignoresSafeArea()
        }
        .overlay { if loading || saving { ProgressView().padding().hibiscusGlass(in: Circle()) } }
        .tint(.white).navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $picking, selection: $selection, matching: .images)
        .sheet(isPresented: $library) {
            FilmLibrary(willSelect: { _ in beginEdit() }, didSelect: { finishEdit() })
        }
        .sheet(isPresented: $accentPicker, onDismiss: finishEdit) {
            VStack(spacing: 16) {
                Text("Accent").font(.headline)
                Slider(value: Binding(get: { film.recipe.hue }, set: { film.recipe.automaticAccent = false; film.recipe.hue = $0 }), in: 0...1)
                    .tint(accent).accessibilityLabel("Accent hue")
                Button("Done") { accentPicker = false }.hibiscusGlassButtonStyle()
            }.padding(24).presentationDetents([.height(180)])
        }
        .fullScreenCover(isPresented: $fullscreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button("Done") { fullscreen = false }.hibiscusGlassButtonStyle().padding()
            }
        }
        .task(id: selection) { await importSelection() }
        .task(id: film.revision) {
            undo.removeAll(); redo.removeAll(); startingEdit = nil
            guard let source = film.source else { return }
            let image = await renderer.render(source: source, revision: film.revision, style: nil, recipe: film.recipe)
            if !Task.isCancelled { original = image }
        }
        .task(id: Request(revision: film.revision, edit: current)) {
            guard let source = film.source else { return }
            let image = await renderer.render(source: source, revision: film.revision, style: film.active.style, recipe: film.recipe)
            if !Task.isCancelled {
                preview = image
                if image == nil { message = LanguageManager.text("This photograph could not be rendered.") }
            }
        }
        .alert("Grade", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    private var photoArea: some View {
        ZStack(alignment: .topTrailing) {
            Color(uiColor: .secondarySystemBackground)
            if let image = comparing ? original : preview {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Color.clear.contentShape(Rectangle())
                .gesture(LongPressGesture(minimumDuration: 0.38).sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in if case .second(true, _) = value { comparing = true } }
                    .onEnded { _ in comparing = false }
                    .exclusively(before: TapGesture().onEnded { fullscreen = true }))
                .accessibilityLabel("Photograph").accessibilityAddTraits(.isButton)
                .accessibilityAction { fullscreen = true }
            Menu {
                Button("Change Photo") { picking = true }
                Button("View Fullscreen") { fullscreen = true }
                Button("Save Graded Photo") { Task { await save() } }.disabled(preview == nil || saving)
                if film.isCapture { Button("Save Original to Photos") { Task { await save(original: true) } }.disabled(saving) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 20) }
                .hibiscusGlassButtonStyle().accessibilityLabel("Photo actions").padding(12)
        }
    }

    private func editor(width: CGFloat) -> some View {
        let padSize = max(1, (width - 40) / 2)
        return VStack(spacing: 11) {
            HStack(spacing: 10) {
                historyButton("Undo", symbol: "arrow.uturn.backward", enabled: !undo.isEmpty) {
                    guard let edit = undo.popLast() else { return }
                    redo.append(current); restore(edit)
                }
                Button { library = true } label: {
                    HStack(spacing: 6) {
                        StockStyleMark(stock: film.active, size: 22)
                        Text(film.active.name)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }.font(.subheadline.weight(.semibold)).padding(.horizontal, 13).frame(height: 34)
                        .hibiscusGlass(interactive: true, in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel("Film Library, " + film.active.name)
                historyButton("Redo", symbol: "arrow.uturn.forward", enabled: !redo.isEmpty) {
                    guard let edit = redo.popLast() else { return }
                    undo.append(current); restore(edit)
                }
            }.frame(height: 36)
            HStack(alignment: .top, spacing: 12) {
                padColumn(.style, size: padSize)
                padColumn(.accent, size: padSize)
            }.padding(.horizontal, 14)
            VStack(spacing: 5) {
                HStack {
                    Text("Strength").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(strength.wrappedValue))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: strength, in: 0...100, onEditingChanged: { $0 ? beginEdit() : finishEdit() })
                    .tint(surface == .style ? film.active.tint : accent).accessibilityLabel("Strength")
            }.padding(.horizontal, 14).padding(.vertical, 9)
                .hibiscusGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 14).padding(.top, 6)
        }.padding(.top, 26).padding(.bottom, 10)
    }

    private func padColumn(_ kind: PadSurface, size: CGFloat) -> some View {
        let style = kind == .style
        return VStack(spacing: 6) {
            HibiscusPad(kind: kind, tint: style ? film.active.tint : accent,
                       point: style ? film.recipe.point : film.recipe.accentPoint,
                       onChange: { point in
                           let discrete = startingEdit == nil
                           if discrete { beginEdit() }
                           surface = kind
                           if style { film.recipe.point = point } else { film.recipe.accentPoint = point }
                           if discrete { finishEdit() }
                       }, editing: { active in
                           surface = kind
                           active ? beginEdit() : finishEdit()
                       }).frame(width: size, height: size)
            ZStack {
                (style ? Text(verbatim: film.active.name) : Text("Accent")).font(.caption.weight(.medium))
                if !style {
                    Button { surface = .accent; beginEdit(); accentPicker = true } label: {
                        Circle().fill(accent).frame(width: ControlDot.handle, height: ControlDot.handle)
                            .overlay { Circle().stroke(.primary.opacity(0.24), lineWidth: 0.5) }
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).offset(x: 38).accessibilityLabel("Select accent color")
                }
            }.frame(height: 44).foregroundStyle(.secondary)
        }.frame(width: size)
    }

    private func historyButton(_ label: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                .hibiscusGlass(interactive: true, in: Circle())
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
    }
    private func beginEdit() { if startingEdit == nil { startingEdit = current } }
    private func finishEdit() {
        if let startingEdit, startingEdit != current { undo.append(startingEdit); redo.removeAll() }
        startingEdit = nil
    }
    private func restore(_ edit: Edit) { film.load(edit.stock); film.recipe = edit.recipe }

    private func importSelection() async {
        guard let selection else { return }
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
            try Task.checkCancellation()
            film.setSource(CameraImage(data: data, movie: nil), captured: false)
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }

    private func save(original: Bool = false) async {
        guard let source = film.source, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let data: Data
            if original { data = source.data }
            else {
                guard let rendered = await renderer.export(source: source, style: film.active.style, recipe: film.recipe) else { throw CocoaError(.fileWriteUnknown) }
                data = rendered
            }
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else { message = LanguageManager.text("Allow access to add photos in Settings."); return }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                if original, let movie = source.movie { request.addResource(with: .pairedVideo, fileURL: movie, options: nil) }
            }
            if original || !discovery.presentAfterExport() {
                message = LanguageManager.text("Saved to Photos.")
            }
        } catch { message = error.localizedDescription }
    }
}
