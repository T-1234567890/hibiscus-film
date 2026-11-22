import SwiftUI
import UniformTypeIdentifiers

struct FilmLibrary: View {
    @Environment(FilmSession.self) private var film
    @Environment(\.dismiss) private var dismiss
    var choosingForExport = false
    var choosingBase: ((Stock) -> Void)?
    var willSelect: ((Stock) -> Void)?
    var didSelect: (() -> Void)?
    @State private var visibleStockIDs: [String] = []
    @State private var query = ""
    @State private var filter = "All stocks"
    @State private var detail: Stock?
    @State private var importing = false
    @State private var exporting = false
    @State private var document: HSpecFileDocument?
    @State private var filename = ""
    @State private var spectralExport: Stock?
    @State private var exchangeMessage: String?
    private var libraryStocks: [Stock] {
        if choosingForExport { return film.stocks.filter(\.canExportHSpec) }
        if choosingBase != nil { return film.stocks.filter(\.canRender) }
        return film.stocks
    }
    private var matches: [Stock] {
        libraryStocks.filter { stock in
            (filter == "All stocks" || (filter == "Hibiscus Originals" && stock.isHibiscusOriginal) || filter == stock.family || (filter == "Favorites" && film.favorites.contains(stock.id)) || (filter == "Custom" && stock.custom)) &&
            (query.isEmpty || "\(stock.name) \(stock.family) \(LanguageManager.text(stock.family))".localizedCaseInsensitiveContains(query))
        }.sorted { first, second in
            let order = first.name.localizedStandardCompare(second.name)
            if order == .orderedSame { return first.id < second.id }
            return order == .orderedAscending
        }
    }

    var body: some View {
        ZStack {
            if matches.isEmpty {
                Text("No matching stocks")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { stock in
                                Button {
                                    if choosingForExport { prepareExport(stock) }
                                    else if let choosingBase { choosingBase(stock); dismiss() }
                                    else if stock.canRender { select(stock) }
                                    else { detail = stock }
                                } label: {
                                    HStack(spacing: 12) {
                                        StockStyleMark(stock: stock, size: 36)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stock.name).font(.body.weight(.medium))
                                            Text(LocalizedStringKey(stock.isHibiscusOriginal ? "Hibiscus Originals" : stock.canRender ? stock.family : "Archive only")).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if !choosingForExport && stock.id == film.active.id {
                                            Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 56)
                                    .contentShape(Rectangle())
                                }
                                .id(stock.id)
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(!choosingForExport && stock.id == film.active.id ? .isSelected : [])
                                .contextMenu {
                                    if !choosingForExport && choosingBase == nil {
                                        if stock.canExportHSpec {
                                            Button("Export .hspec File") { prepareExport(stock) }
                                        }
                                        Button("Profile details") { detail = stock }
                                        Button(film.favorites.contains(stock.id) ? "Remove from Favorites" : "Add to Favorites") {
                                            if !film.favorites.insert(stock.id).inserted { film.favorites.remove(stock.id) }
                                        }
                                    }
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .onScrollTargetVisibilityChange(idType: String.self) { ids in visibleStockIDs = ids }
                    .contentMargins(.top, 20, for: .scrollContent)
                    .contentMargins(.bottom, 64, for: .scrollContent)
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear { if !choosingForExport && choosingBase == nil { reader.scrollTo(film.active.id, anchor: .center) } }
                }
            }
        }
        .task(id: visibleStockIDs, priority: .utility) {
            guard !choosingForExport else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let visible = Set(visibleStockIDs)
            for stock in matches where stock.id != film.active.id && visible.contains(stock.id) {
                guard !Task.isCancelled else { return }
                if let id = stock.recipe.fotufilmID { await FotufilmRenderer.shared.prepare(id) }
            }
        }
        .overlay(alignment: .bottom) {
            searchBar
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .top) {
            if choosingForExport {
                Text("Select a Profile to Export")
                    .font(.headline)
                    .padding(.top, 16)
            }
        }
        .tint(.primary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fileImporter(isPresented: $importing, allowedContentTypes: [HSpecFileDocument.type, .json]) { result in
            do {
                let stock = try FilmProfileExchange.load(result.get())
                if !film.custom.contains(where: { $0.id == stock.id }) { film.custom.append(stock) }
                detail = stock
            } catch { report(error) }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: HSpecFileDocument.type,
                      defaultFilename: filename) { result in
            switch result {
            case .success: if choosingForExport { dismiss() }
            case .failure(let error): report(error)
            }
        }
        .confirmationDialog("Export .hspec File",
            isPresented: Binding(get: { spectralExport != nil }, set: { if !$0 { spectralExport = nil } }),
            titleVisibility: .visible, presenting: spectralExport) { stock in
                Button("Export .hspec File") { writeExport(stock) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This .hspec file includes the portable spectral recipe. Grain, halation, and other settings outside the current HSpec format stay with the saved recipe on this device.")
            }
        .alert("Film profile", isPresented: Binding(get: { exchangeMessage != nil }, set: { if !$0 { exchangeMessage = nil } })) {
            Button("OK") { exchangeMessage = nil }
        } message: { Text(exchangeMessage ?? "") }
        .sheet(item: $detail) { stock in
            VStack(spacing: 14) {
                StockStyleMark(stock: stock, size: 108)
                Text(stock.name).font(.headline)
                if stock.canRender {
                    Text("Fotufilm Engine").foregroundStyle(.secondary)
                }
                if stock.isHibiscusOriginal || stock.custom || !stock.canRender {
                    Text(verbatim: stock.notes.components(separatedBy: "\n").map(LanguageManager.text).joined(separator: "\n")).foregroundStyle(.secondary)
                }
                if stock.canRender { Button("Load film") { select(stock) }.hibiscusGlassButtonStyle() }
            }.padding(24).presentationDetents([.medium])
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search film stocks", text: $query).submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search")
            }
            Menu {
                if !choosingForExport && choosingBase == nil { Button("Import HSpec…") { importing = true } }
                Picker("Collection", selection: $filter) {
                    ForEach(["All stocks", "Hibiscus Originals"] + Set(libraryStocks.map(\.family)).sorted() + ["Favorites", "Custom"], id: \.self) {
                        Text(LocalizedStringKey($0))
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.body)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Filter film stocks")
            .accessibilityValue(Text(LocalizedStringKey(filter)))
        }.padding(.leading, 16).padding(.trailing, 4).frame(height: 48).hibiscusGlass(in: Capsule())
    }

    private func prepareExport(_ stock: Stock) {
        guard stock.canExportHSpec else { return }
        if FilmProfileExchange.exportsSpectralProjection(stock) { spectralExport = stock }
        else { writeExport(stock) }
    }

    private func writeExport(_ stock: Stock) {
        do {
            document = try HSpecFileDocument(bytes: FilmProfileExchange.export(stock))
            filename = stock.name
            exporting = true
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        if (error as NSError).code != NSUserCancelledError { exchangeMessage = error.localizedDescription }
    }

    private func select(_ stock: Stock) {
        willSelect?(stock)
        film.load(stock)
        didSelect?()
        dismiss()
    }
}

private extension Stock {
    var canExportHSpec: Bool { permitsProfileExport != false && (FilmProfileExchange.url(for: self) != nil || FilmProfileExchange.exportsSpectralProjection(self)) }
}

struct HSpecSettingsSection: View {
    let effectsPhoto: CGImage?
    @Environment(AppPurchases.self) private var purchases
    @Environment(FilmSession.self) private var film
    @State private var importing = false
    @State private var choosingProfile = false
    @State private var newProfile = false
    @State private var message: String?

    var body: some View {
        Section {
            Button("Import") { importing = true }
                .fileImporter(isPresented: $importing, allowedContentTypes: [HSpecFileDocument.type, .json]) { result in
                    do {
                        let stock = try FilmProfileExchange.load(result.get())
                        if !film.custom.contains(where: { $0.id == stock.id }) { film.custom.append(stock) }
                        message = String(format: LanguageManager.text("Imported “%@” into the profile library."), stock.name)
                    } catch {
                        if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                    }
                }
                .alert("Import HSpec", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("OK") { message = nil }
                } message: { Text(message ?? "") }

            Button("Export .hspec File") { choosingProfile = true }
                .sheet(isPresented: $choosingProfile) { FilmLibrary(choosingForExport: true) }

            Button("Recipe Kitchen") { newProfile = true }
                .sheet(isPresented: $newProfile) {
                    if purchases.canUseCreativePack {
                        RecipeKitchen()
                    } else {
                        CreativePackPaywall(photo: effectsPhoto)
                    }
                }
        } header: {
            Text("HSpec Compatibility")
        } footer: {
            Text("HSpec exchanges the base film recipe. Pad adjustments are saved on this device.")
        }
    }
}
