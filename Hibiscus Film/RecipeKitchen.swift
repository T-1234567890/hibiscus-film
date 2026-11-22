import CoreImage
import FotufilmCore
import PhotosUI
import SwiftUI

struct RecipeKitchen: View {
    @Environment(FilmSession.self) private var film
    @Environment(\.dismiss) private var dismiss
    @State private var draft: KitchenRecipe?
    @State private var baseline: KitchenRecipe?
    @State private var startingStock: Stock?
    @State private var addingRecipe = false
    @State private var choosingBase = false
    private enum CurveKind: Hashable { case response, sensitivity }
    @State private var kind = CurveKind.response
    @State private var channel = -1
    @State private var undo: [KitchenRecipe] = []
    @State private var revision = 0
    @State private var picker: PhotosPickerItem?
    @State private var photo: EffectPhoto?
    @State private var proof: CGImage?
    @State private var proofFailed = false
    @State private var message: String?
    @State private var confirmingSpectralExport = false
    @State private var exporting = false
    @State private var document: HSpecFileDocument?
    nonisolated private static let context = CIContext()

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            preview
                            TextField("Recipe name", text: Binding(get: { draft.definition.name }, set: { self.draft?.definition.name = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Picker("Curve", selection: $kind) {
                                Text("Response").tag(CurveKind.response)
                                Text("Sensitivity").tag(CurveKind.sensitivity)
                            }
                            .pickerStyle(.segmented)
                            Picker("Color record", selection: $channel) {
                                Text("All records").tag(-1)
                                if draft.definition.isMonochrome != true {
                                    Text("Red").tag(0)
                                    Text("Green").tag(1)
                                    Text("Blue").tag(2)
                                }
                            }
                            .pickerStyle(.segmented)
                            graph(draft.definition)
                            grainControls(draft.definition)
                            Button("Save Recipe", action: save)
                                .buttonStyle(.borderedProminent)
                                .disabled(draft.definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(20)
                    }
                } else {
                    Button { addingRecipe = true } label: {
                        VStack(spacing: 16) {
                            Image(systemName: "plus.circle").font(.largeTitle).accessibilityHidden(true)
                            Text("Add Recipe").font(.headline)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Recipe Kitchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if draft != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Add Recipe", systemImage: "plus") { addingRecipe = true }
                            Button("Undo", systemImage: "arrow.uturn.backward") {
                                if let previous = undo.popLast() { draft = previous; revision += 1 }
                            }.disabled(undo.isEmpty)
                            Button("Reset Recipe", systemImage: "arrow.counterclockwise") {
                                guard let baseline else { return }
                                remember()
                                let name = draft?.definition.name
                                draft = baseline
                                if let name { draft?.definition.name = name }
                                revision += 1
                            }
                            Button("Export .hspec File", systemImage: "square.and.arrow.up") {
                                confirmingSpectralExport = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Recipe Actions")
                    }
                }
            }
            .confirmationDialog("Add Recipe", isPresented: $addingRecipe, titleVisibility: .visible) {
                Button("Blank Recipe") { load { try KitchenRecipe.blank() } }
                Button("Choose Base Stock") { choosingBase = true }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $choosingBase) {
                FilmLibrary(choosingBase: { stock in load(from: stock) })
            }
            .confirmationDialog("Export .hspec File", isPresented: $confirmingSpectralExport, titleVisibility: .visible) {
                Button("Export .hspec File", action: prepareExport)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This .hspec file includes the portable spectral recipe. Grain, halation, and other settings outside the current HSpec format stay with the saved recipe on this device.")
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: HSpecFileDocument.type,
                          defaultFilename: draft?.definition.name) { result in
                if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                    message = error.localizedDescription
                }
            }
            .alert("Recipe Kitchen", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .task(id: picker) {
                guard let picker else { return }
                do {
                    let selected = try await EffectPhoto.load(picker)
                    try Task.checkCancellation()
                    proof = nil
                    photo = selected
                    revision += 1
                } catch { if !Task.isCancelled { message = LanguageManager.text("This photo could not be opened.") } }
                if !Task.isCancelled { self.picker = nil }
            }
            .task(id: revision) {
                guard var recipe = draft, let photo = photo?.preview.cgImage else { return }
                proofFailed = false
                if recipe.definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { recipe.definition.name = "Untitled" }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    let result = try await Self.render(photo, recipe: recipe)
                    try Task.checkCancellation()
                    proof = result
                } catch { if !Task.isCancelled { proofFailed = true } }
            }
        }
    }

    private var safeChannel: Int { max(0, channel) }

    private func graph(_ definition: FilmStockDefinition) -> some View {
        switch kind {
        case .response:
            let curve = definition.curves[safeChannel].curve
            let domain: ClosedRange<Float> = -2.25...2.25
            let highest = (0...80).map {
                curve.density(logExposure: domain.lowerBound + Float($0) / 80 * 4.5)
            }.max() ?? 1
            return RecipeCurveGraph(domain: domain, anchors: [-1.8, -1.2, -0.6, 0, 0.6, 1.2, 1.8],
               xLabel: "Log exposure", yLabel: "Optical density", ceiling: max(1, highest * 1.15),
               value: { curve.density(logExposure: $0) }, begin: remember, update: changeCurve)
        case .sensitivity:
            let samples = definition.spectral.profile.floored(at: definition.sensitivityFloor ?? 0).layerSensitivity[safeChannel]
            return RecipeCurveGraph(domain: 380...780, anchors: [415, 460, 505, 550, 595, 640, 685, 730],
               xLabel: "Wavelength (nm)", yLabel: "Relative sensitivity", ceiling: max(1, (samples.max() ?? 1) * 1.10),
               value: { wavelength in
                   let index = (wavelength - 380) / 5
                   let low = min(80, max(0, Int(index)))
                   let high = min(80, low + 1)
                   return samples[low] + (samples[high] - samples[low]) * (index - Float(low))
               }, begin: remember, update: changeSensitivity)
        }
    }

    private var preview: some View {
        PhotosPicker(selection: $picker, matching: .images) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.quaternary)
                if let photo {
                    Group {
                        if let proof { Image(decorative: proof, scale: 1).resizable() }
                        else { Image(uiImage: photo.preview).resizable() }
                    }
                    .scaledToFit()
                } else {
                    Label("Choose Preview Photo", systemImage: "photo")
                }
            }
            .frame(height: 204)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose Preview Photo")
        .overlay(alignment: .bottom) {
            if proofFailed { Text("This photograph could not be rendered.").font(.caption).padding(6).background(.regularMaterial, in: Capsule()) }
        }
    }

    private func grainControls(_ definition: FilmStockDefinition) -> some View {
        VStack(spacing: 12) {
            control("Grain", value: Double(definition.grainStrength), range: 0...0.12) { $0.grainStrength = Float($1) }
            control("Grain size", value: Double(definition.grainSizeMM), range: 0.001...0.06) { $0.grainSizeMM = Float($1) }
            control("Halation", value: Double(definition.halationLookScale ?? 1), range: 0...4) { $0.halationLookScale = Float($1) }
            let peak = definition.halationStrength.max() ?? 0
            control("Halation return", value: Double(peak), range: 0...max(0.15, Double(peak))) { definition, value in
                let original = undo.last?.definition.halationStrength ?? definition.halationStrength
                let maximum = original.max() ?? 0
                let weights = maximum > 0 ? original.map { $0 / maximum }
                    : (definition.isMonochrome == true ? [1, 1, 1] : [1, 0.25, 0.08])
                definition.halationStrength = weights.map { $0 * Float(value) }
            }
        }
    }

    private func control(_ title: LocalizedStringKey, value: Double, range: ClosedRange<Double>,
                         change: @escaping (inout FilmStockDefinition, Double) -> Void) -> some View {
        // Include the exact imported value in the range before the user makes an edit.
        let bounds = min(range.lowerBound, value)...max(range.upperBound, value)
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline)
            Slider(value: Binding(get: { value }, set: { newValue in
                guard var recipe = draft else { return }
                change(&recipe.definition, newValue)
                draft = recipe
                revision += 1
            }), in: bounds, onEditingChanged: { if $0 { remember() } })
            .accessibilityLabel(Text(title))
        }
    }

    private func remember() {
        guard let draft else { return }
        if undo.count == 32 { undo.removeFirst() }
        undo.append(draft)
    }

    private func changeCurve(at x: Float, to density: Float) {
        guard var recipe = draft, let start = undo.last else { return }
        let delta = density - start.definition.curves[safeChannel].curve.density(logExposure: x)
        let indices = channel == -1 ? Array(recipe.definition.curves.indices) : [safeChannel]
        for index in indices {
            var curve = start.definition.curves[index]
            let exposures = curve.sampled?.logExposure ?? (0...128).map { -4 + Float($0) / 16 }
            let measured = curve.sampled?.density ?? exposures.map { curve.curve.density(logExposure: $0) }
            let ceiling = max(8, measured.max() ?? 0)
            var edited = zip(exposures, measured).map { exposure, original in
                let t = max(0, 1 - abs(exposure - x) / 0.64)
                return max(curve.dMin, min(ceiling, original + delta * t * t * (3 - 2 * t)))
            }
            if !edited.isEmpty { edited[0] = curve.dMin }
            guard let sampled = try? SampledCharacteristicCurve(logExposure: exposures, density: edited) else { return }
            curve.sampled = sampled
            recipe.definition.curves[index] = curve
        }
        recipe.definition.schemaVersion = max(2, recipe.definition.schemaVersion)
        draft = recipe
        revision += 1
    }

    private func changeSensitivity(at wavelength: Float, to target: Float) {
        guard var recipe = draft, let original = undo.last?.definition else { return }
        let spectral = original.spectral.profile.floored(at: original.sensitivityFloor ?? 0)
        var rows = spectral.layerSensitivity
        let index = Int((wavelength - 380) / 5)
        let delta = target - rows[safeChannel][index]
        let indices = channel == -1 ? Array(rows.indices) : [safeChannel]
        for record in indices {
            let floor = max(0.00001, (rows[record].max() ?? 1) * (original.sensitivityFloor ?? 0))
            for i in max(0, index - 10)...min(index + 10, 80) {
                let t = 1 - Float(abs(i - index)) / 10
                rows[record][i] = min(10000, max(floor, rows[record][i] + delta * t * t * (3 - 2 * t)))
            }
        }
        if let base = spectral.minimumDensity {
            recipe.definition.spectral = .separatedBase(layerSensitivity: rows, imageDyeDensity: spectral.imageDyeDensity, minimumDensity: base)
        } else {
            recipe.definition.spectral = .samples(layerSensitivity: rows, imageDyeDensity: spectral.imageDyeDensity)
        }
        // The original floor is already incorporated into the authored samples.
        recipe.definition.sensitivityFloor = nil
        draft = recipe
        revision += 1
    }

    private func load(from stock: Stock) {
        load(stock: stock) { try KitchenRecipe.starting(from: stock) }
    }

    private func load(stock: Stock? = nil, _ make: () throws -> KitchenRecipe) {
        do {
            let recipe = try make()
            draft = recipe
            baseline = recipe
            startingStock = stock
            undo.removeAll()
            channel = -1
            kind = .response
            proof = nil
            revision += 1
        } catch { message = error.localizedDescription }
    }

    private func validDraft() throws -> KitchenRecipe {
        guard var recipe = draft else { throw SpectrumProfile.Failure.invalid }
        recipe.definition.name = recipe.definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try recipe.validate()
        return recipe
    }

    private func save() {
        do {
            let recipe = try validDraft()
            var saved = try recipe.save()
            if let base = startingStock, let native = base.recipe.fotufilmID, KitchenRecipe.url(native) != nil,
               let index = film.custom.firstIndex(where: { $0.id == base.id }) {
                saved.id = base.id
                film.custom[index] = saved
                film.refreshStock(saved)
            } else { film.custom.append(saved) }
            startingStock = saved
            baseline = recipe
            message = LanguageManager.text("Recipe saved to the Film Library.")
        } catch { message = error.localizedDescription }
    }

    private func prepareExport() {
        do {
            document = try HSpecFileDocument(bytes: KitchenSpectrum.encode(validDraft()))
            exporting = true
        } catch { message = error.localizedDescription }
    }

    @concurrent private static func render(_ bitmap: CGImage, recipe: KitchenRecipe) async throws -> CGImage {
        try recipe.validate()
        let photo = CIImage(cgImage: bitmap)
        let scale = min(1, 640 / max(photo.extent.width, photo.extent.height))
        let reference = photo.transformed(by: .init(scaleX: scale, y: scale))
        try Task.checkCancellation()
        let image = try FotufilmRenderer.shared.process(reference, stock: recipe.definition.stock, realtime: false)
        guard let rendered = context.createCGImage(image, from: image.extent) else { throw FotufilmRenderer.Failure.image }
        return rendered
    }
}

private struct RecipeCurveGraph: View {
    let domain: ClosedRange<Float>
    let anchors: [Float]
    let xLabel: LocalizedStringKey
    let yLabel: LocalizedStringKey
    let ceiling: Float
    let value: (Float) -> Float
    let begin: () -> Void
    let update: (Float, Float) -> Void
    @State private var dragging: Int?
    @State private var dragCeiling: Float?
    private var span: Float { domain.upperBound - domain.lowerBound }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(yLabel).font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                let ceiling = dragCeiling ?? self.ceiling
                func point(_ x: Float) -> CGPoint {
                    CGPoint(x: 15 + CGFloat((x - domain.lowerBound) / span) * (size.width - 30),
                            y: 15 + CGFloat(1 - value(x) / ceiling) * (size.height - 30))
                }
                for i in 0...4 {
                    let f = CGFloat(i) / 4
                    var line = Path()
                    line.move(to: CGPoint(x: 15, y: 15 + f * (size.height - 30)))
                    line.addLine(to: CGPoint(x: size.width - 15, y: 15 + f * (size.height - 30)))
                    context.stroke(line, with: .color(.secondary.opacity(0.22)), lineWidth: 1)
                }
                var path = Path()
                path.move(to: point(domain.lowerBound))
                for step in 1...120 { path.addLine(to: point(domain.lowerBound + Float(step) / 120 * span)) }
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                for index in anchors.indices {
                    let center = point(anchors[index])
                    let radius: CGFloat = index == dragging ? 8 : 6
                    let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(dot, with: .color(.accentColor))
                    context.stroke(dot, with: .color(.primary.opacity(0.6)), lineWidth: 1)
                }
            }
            .frame(height: 224)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                GeometryReader { proxy in
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let ceiling = dragCeiling ?? self.ceiling
                            if dragging == nil {
                                let index = anchors.indices.min { left, right in
                                    func distance(_ index: Int) -> CGFloat {
                                        let x = CGFloat((anchors[index] - domain.lowerBound) / span) * (proxy.size.width - 30) + 15
                                        return abs(x - drag.startLocation.x)
                                    }
                                    return distance(left) < distance(right)
                                }
                                dragging = index
                                dragCeiling = ceiling
                                begin()
                            }
                            guard let dragging else { return }
                            update(anchors[dragging], ceiling * Float(1 - (drag.location.y - 15) / (proxy.size.height - 30)))
                        }
                        .onEnded { _ in dragging = nil; dragCeiling = nil })
                }
            }
            .accessibilityLabel(Text(yLabel))
            .accessibilityHint("Adjusts the center of the selected response curve.")
            .accessibilityAdjustableAction { direction in
                begin()
                let center = anchors[anchors.count / 2]
                update(center, value(center) + ceiling * (direction == .increment ? 0.05 : -0.05))
            }
            Text(xLabel).font(.caption).foregroundStyle(.secondary)
        }
    }
}
