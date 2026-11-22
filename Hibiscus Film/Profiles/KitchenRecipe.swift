import CryptoKit
import Foundation
import FotufilmCore

/// Native base material and attribution. Local Color Pad state lives in Recipe.
nonisolated struct KitchenRecipe: Codable, Sendable {
    var definition: FilmStockDefinition
    var iso: Int
    var notes: String
    var provenance: [SpectrumProfile.Provenance]

    static let directory = FilmProfileFiles.imported.appendingPathComponent("Kitchen", isDirectory: true)

    static func url(_ id: String, in directory: URL = directory) -> URL? {
        guard id.hasPrefix("kitchen-"), UUID(uuidString: String(id.dropFirst(8))) != nil else { return nil }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    func validate() throws {
        try definition.validate()
        guard (1...204800).contains(iso), notes.utf8.count <= 4096, (1...32).contains(provenance.count),
              provenance.allSatisfy({ [$0.author, $0.license, $0.source, $0.notice].allSatisfy {
                  !$0.isEmpty && $0.utf8.count <= 4096
              } }) else { throw SpectrumProfile.Failure.invalid }
    }

    static func starting(from stock: Stock) throws -> Self {
        guard let id = stock.recipe.fotufilmID else { throw SpectrumProfile.Failure.unsupported }
        if let url = url(id) { return try read(url) }
        let definition = try FotufilmRenderer.definition(id)
        let original = id.hasPrefix("hibiscus-")
        let credit = SpectrumProfile.Provenance(
            kind: original ? .authored : .derived,
            author: original ? "Hibiscus Film" : "Fotufilm / MUAStudio Inc.",
            license: "CC-BY-SA-4.0",
            source: original ? "Hibiscus Film Originals" : "https://github.com/DhaliwalX/fotufilm-engine/blob/d534fc99c7eee10a839d3bc4ae26501c286b32a0/Sources/FotufilmCore/Stocks/\(id).json",
            notice: original ? "Independently authored synthetic profile. No measured emulsion is claimed."
                : "Copyright 2026 MUAStudio Inc. Adapted in Hibiscus Film Recipe Kitchen. CC BY-SA 4.0 https://creativecommons.org/licenses/by-sa/4.0/.")
        return Self(definition: definition, iso: stock.iso ?? 100, notes: stock.notes, provenance: [credit])
    }

    static func blank() throws -> Self {
        guard let daylight = Stock.collection.first(where: { $0.id == "hibiscus-daylight100" }) else {
            throw SpectrumProfile.Failure.invalid
        }
        var recipe = try starting(from: daylight)
        recipe.definition.name = ""
        recipe.definition.grainStrength = 0
        recipe.definition.halationStrength = [0, 0, 0]
        recipe.notes = ""
        return recipe
    }

    static func read(_ url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: HSpecArchive.maximumBytes + 1) ?? Data()
        guard data.count <= HSpecArchive.maximumBytes else { throw SpectrumProfile.Failure.invalid }
        let recipe = try JSONDecoder().decode(Self.self, from: data)
        try recipe.validate()
        return recipe
    }

    func save(in directory: URL = directory) throws -> Stock {
        var saved = self
        let id = "kitchen-" + UUID().uuidString.lowercased()
        saved.definition.id = id
        saved.definition.name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try saved.validate()
        guard let file = Self.url(id, in: directory) else { throw SpectrumProfile.Failure.invalid }
        let bytes = try JSONEncoder().encode(saved)
        guard bytes.count <= HSpecArchive.maximumBytes else { throw SpectrumProfile.Failure.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
        let mono = saved.definition.isMonochrome == true
        return Stock(id: id, name: saved.definition.name, iso: iso, family: mono ? "Monochrome" : "Color negative",
                     notes: notes, style: mono ? .silver : .moss, recipe: Recipe(fotufilmID: id, strength: 100, accentStrength: 0), custom: true)
    }
}
