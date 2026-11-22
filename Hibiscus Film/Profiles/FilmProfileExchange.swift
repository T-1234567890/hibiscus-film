import CryptoKit
import Foundation
import UniformTypeIdentifiers
import SwiftUI

nonisolated enum FilmProfileFiles {
    static let bundle = Bundle.main.url(forResource: "FilmProfiles", withExtension: "bundle")!
    static let pack = bundle.appendingPathComponent("Fotufilm", isDirectory: true)
    static let hibiscus = bundle.appendingPathComponent("Hibiscus", isDirectory: true)
    static let imported = URL.applicationSupportDirectory.appendingPathComponent("ImportedFilmProfiles", isDirectory: true)
    static func baseArchive(_ file: String) -> URL {
        pack.appendingPathComponent("Adapted/").appendingPathComponent(file).appendingPathExtension("hspec")
    }
}

nonisolated struct FilmProfileExchange {
    struct Item { let stock: Stock }
    private struct CatalogRow: Decodable {
        let id, file, name, family, notes: String
        let iso: Int?
        let manufacturer: String?
        let swatch: UInt32
        let hasArchive: Bool
    }
    struct EditorSettings: Codable {
        let summary, author, filmFormat: String
        let grainCharacter: String?
        let defaults: [String: Double]
    }
    private struct Legacy: Decodable {
        let format, name, author, family, summary, filmFormat, stock: String
        let id: UUID
        let version, profileVersion, iso: Int
        let spectral: SpectrumProfile.Specification?
        let manufacturer, previewStyle: String?
        let illustrative, permitsExport: Bool
        let sensitivity, response, color, tone: [Double]
        let defaults: [String: Double]
        let grainCharacter: String?
    }
    static let shared: [Item] = {
        func catalog(_ folder: URL) throws -> [Item] {
            let url = folder.appendingPathComponent("catalog.json")
            return try JSONDecoder().decode([CatalogRow].self, from: Data(contentsOf: url)).map { row in
                var stock = Stock(id: row.id, name: row.name, iso: row.iso, swatch: row.swatch, family: row.family,
                                  notes: row.notes, style: row.family == "Monochrome" ? .silver : .moss)
                stock.recipe.fotufilmID = row.file
                stock.manufacturer = row.manufacturer
                stock.archiveFile = row.hasArchive ? row.file : nil
                if stock.isHibiscusOriginal {
                    stock.recipe.strength = 100
                    stock.recipe.accentStrength = 0
                }
                return Item(stock: stock)
            }
        }
        do { return try catalog(FilmProfileFiles.hibiscus) + catalog(FilmProfileFiles.pack) }
        catch { preconditionFailure("Invalid bundled film catalog: \(error)") }
    }()

    // Only document exchange needs to decode and compare full spectral archives.
    private static let references = shared.compactMap { item -> (stock: Stock, specification: SpectrumProfile.Specification)? in
        if item.stock.isHibiscusOriginal,
           let recipe = try? KitchenRecipe.starting(from: item.stock),
           let profile = try? KitchenSpectrum.profile(recipe) {
            return (item.stock, profile.specification)
        }
        guard let file = item.stock.archiveFile,
              let bytes = try? Data(contentsOf: FilmProfileFiles.baseArchive(file)),
              let document = try? HSpecArchive.decode(bytes) else { return nil }
        return (item.stock, document.profile.specification)
    }

    static func inspect(_ bytes: Data) throws -> Stock {
        guard bytes.count <= HSpecArchive.maximumBytes else { throw SpectrumProfile.Failure.invalid }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var item: Stock
        if bytes.starts(with: HSpecArchive.magic),
           !((try HSpecArchive.read(bytes)).contains { $0.type == 2 }) {
            let document = try HSpecArchive.decode(bytes)
            let s = document.profile.specification
            let editor = try document.extensions.first { $0.type == 0x4D415458 }.map {
                try PropertyListDecoder().decode(EditorSettings.self, from: $0.data)
            }
            if let editor {
                guard [editor.summary, editor.author, editor.filmFormat].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else {
                    throw SpectrumProfile.Failure.invalid
                }
                try validateDefaults(editor.defaults, grain: editor.grainCharacter)
            }
            // Only equivalent spectral data can select the corresponding original negative.
            // Names and UUIDs alone also match revised or independently edited profiles.
            let matches = references.filter { reference in
                var a = reference.specification
                a.id = s.id; a.name = s.name; a.family = s.family; a.revision = s.revision
                a.iso = s.iso; a.provenance = s.provenance
                return a == s
            }
            // Some negatives share spectral curves but have different native grain and halation.
            let base = matches.first { $0.specification.id == s.id } ?? (matches.count == 1 ? matches.first : nil)
            item = Stock(id: digest, name: s.name, iso: s.iso, family: s.family,
                         notes: editor?.summary ?? s.provenance.map(\.notice).joined(separator: "\n"), style: s.family == "Monochrome" ? .silver : .moss)
            item.swatch = base?.stock.swatch
            if let base { item.recipe = base.stock.recipe }
            if editor?.defaults.isEmpty == false { item.notes += "\nEditor adjustments are retained in the file. The Fotufilm Engine renders the base negative." }
            if !document.extensions.filter({ $0.type != 0x4D415458 }).isEmpty {
                item.notes += "\nOptional extension data is preserved on export."
            }
        } else {
            let legacy: Legacy
            if bytes.starts(with: HSpecArchive.magic) {
                let chunks = try HSpecArchive.read(bytes)
                guard chunks.count == 1, let c = chunks.first, c.type == 2, c.flags == 1,
                      c.data.starts(with: Data("bplist00".utf8)) else { throw SpectrumProfile.Failure.invalid }
                legacy = try PropertyListDecoder().decode(Legacy.self, from: c.data)
            } else {
                guard bytes.count <= 262144 else { throw SpectrumProfile.Failure.invalid }
                legacy = try JSONDecoder().decode(Legacy.self, from: bytes)
            }
            guard legacy.spectral == nil else { throw SpectrumProfile.Failure.unsupported }
            guard ["Garden 160", "Amber 400", "Pacific 50", "Daylight 100", "Panchro 125", "Midnight 800"].contains(legacy.stock),
                  legacy.previewStyle.map({ legacySwatchNames.contains($0) || OriginalStyle(rawValue: $0) != nil }) ?? true,
                  legacy.manufacturer.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1024 }) ?? true,
                  legacy.format == "HSpec", legacy.version == 1, legacy.profileVersion > 0, legacy.illustrative,
                  (1...204800).contains(legacy.iso),
                  [legacy.name,legacy.author,legacy.family,legacy.summary,legacy.filmFormat].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1024 }),
                  [legacy.sensitivity,legacy.response,legacy.color,legacy.tone].allSatisfy({ (2...256).contains($0.count) && $0.allSatisfy { (0...1).contains($0) } }) else { throw SpectrumProfile.Failure.invalid }
            try validateDefaults(legacy.defaults, grain: legacy.grainCharacter)
            item = Stock(id: digest, name: legacy.name, iso: legacy.iso, family: legacy.family, notes: legacy.summary, style: .pure)
            item.permitsProfileExport = legacy.permitsExport
        }
        item.custom = true
        item.importedArchive = digest
        if item.recipe.fotufilmID == nil { item.notes += "\nArchived for exchange. This profile has no matching Fotufilm negative." }
        return item
    }

    // Matrix v1 accepts these photographic and retired swatch hints in illustrative files.
    private static let legacySwatchNames: Set<String> = [
        "Clear", "Sunday", "Veranda", "Keepsake", "Daybreak", "Cool Day", "Porcelain",
        "Velvet", "Studio", "Petal", "Silhouette", "Warm Portrait", "Canopy", "Meadow",
        "Alpine", "Shore", "Red Earth", "Rainforest", "Coast", "Afternoon", "Boardwalk",
        "Golden", "Oasis", "Summer", "Metro", "Marquee", "Afterhours", "Voltage",
        "Wet Streets", "City Lights", "Platinum", "Linework", "High Key", "Deep Black", "Contour",
        "Newsprint", "Linen", "Pearl", "Clay", "Ochre", "Lagoon", "Mist",
        "Glacier", "Reef", "Abyss", "Sodium", "Nocturne", "Graphite", "Sepia",
        "Chalk", "Copper", "Cobalt", "Carbon", "Amber", "Titanium", "Jade"
    ]

    private static func validateDefaults(_ defaults: [String: Double], grain: String?) throws {
        let ranges: [String: ClosedRange<Double>] = ["Exposure offset": -3...3, "Grain": 0...100,
            "Grain size": 0...100, "Texture": 0...100, "Halation": 0...100, "Highlight roll-off": 0...100,
            "Shadow response": -100...100, "Color separation": 0...100, "Color response": -100...100, "Tonal response": -100...100]
        guard ["Fine", "Irregular", "Clustered"].contains(grain ?? "Fine"),
              defaults.allSatisfy({ ranges[$0.key]?.contains($0.value) == true }) else { throw SpectrumProfile.Failure.invalid }
    }

    static func exportsSpectralProjection(_ stock: Stock) -> Bool {
        guard stock.importedArchive == nil, let id = stock.recipe.fotufilmID else { return false }
        return stock.isHibiscusOriginal || KitchenRecipe.url(id) != nil
    }

    static func export(_ stock: Stock) throws -> Data {
        if let url = url(for: stock) { return try Data(contentsOf: url) }
        guard exportsSpectralProjection(stock) else { throw SpectrumProfile.Failure.unsupported }
        return try KitchenSpectrum.encode(KitchenRecipe.starting(from: stock))
    }

    static func url(for stock: Stock, importedDirectory: URL = FilmProfileFiles.imported) -> URL? {
        if let key = stock.importedArchive { return importedDirectory.appendingPathComponent(key + ".hspec") }
        return stock.archiveFile.map(FilmProfileFiles.baseArchive)
    }

    static func load(_ url: URL, into importedDirectory: URL = FilmProfileFiles.imported) throws -> Stock {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: HSpecArchive.maximumBytes + 1) ?? Data()
        let stock = try inspect(bytes)
        try FileManager.default.createDirectory(at: importedDirectory, withIntermediateDirectories: true)
        try bytes.write(to: Self.url(for: stock, importedDirectory: importedDirectory)!, options: .atomic)
        return stock
    }
}

struct HSpecFileDocument: FileDocument {
    static let type = UTType(filenameExtension: "hspec") ?? .data
    static var readableContentTypes: [UTType] { [type] }
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw SpectrumProfile.Failure.invalid }
        bytes = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}
