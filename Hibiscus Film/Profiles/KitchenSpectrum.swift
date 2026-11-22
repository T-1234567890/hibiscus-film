import CryptoKit
import Foundation
import FotufilmCore

/// Projects the supported spectral fields into Matrix's existing HSpec v2 model.
nonisolated enum KitchenSpectrum {
    static func profile(_ recipe: KitchenRecipe) throws -> SpectrumProfile {
        let definition = recipe.definition
        let film = definition.stock
        let spectral = film.spectralProfile
        let count = definition.curves.count
        let mono = definition.isMonochrome == true
        let identity = (0..<count).map { row in (0..<count).map { Float(row == $0 ? 1 : 0) } }
        let names = ["Red", "Green", "Blue"]
        let layers = try definition.curves.enumerated().map { index, curve in
            let spectrum = spectral.layerSensitivity[index]
            guard let peak = spectrum.max(), peak > 0 else { throw SpectrumProfile.Failure.invalid }
            let response: SpectrumProfile.Response
            if let sampled = curve.sampled {
                var previous: Float = 0
                let density = sampled.density.map { value in
                    previous = max(previous, value - curve.dMin)
                    return previous
                }
                response = .init(exposure: sampled.logExposure, density: density)
            } else {
                let primary = SpectrumProfile.Population(gamma: curve.gamma, toe: curve.toe, toeWidth: curve.toeWidth,
                                                         shoulder: curve.shoulder, shoulderWidth: curve.shoulderWidth)
                let additional = curve.secondary.map {
                    SpectrumProfile.Population(gamma: $0.gamma, toe: $0.toe, toeWidth: $0.toeWidth,
                                               shoulder: $0.shoulder, shoulderWidth: $0.shoulderWidth)
                }
                response = .init(populations: [primary] + (additional.map { [$0] } ?? []))
            }
            return SpectrumProfile.Layer(name: names[index], sensitivity: spectrum.map { $0 / peak },
                                         response: response, logSpeed: 0)
        }
        let white = SpectrumMath.wavelengths.map { value in
            let wavelength = Double(value)
            return 1 / (pow(wavelength / 550, 5) * expm1(1.438776877e7 / (wavelength * 6000)))
        }
        let peak = white.max()!
        let hash = SHA256.hash(data: Data(("Hibiscus Film: " + definition.id).utf8)).map { $0 }
        let id = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                             hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
        var provenance = recipe.provenance
        provenance[0].notice += " HSpec spectral projection for Matrix. Sensitivities are peak-normalized, sampled responses are made nondecreasing and above base, and absorption is nonnegative. Uses identity dye mixing, a 6000 K scan and Matrix response. Fotufilm grain, halation, native illumination and other engine-specific stages are omitted."
        return try SpectrumProfile(.init(id: id, revision: 1, name: definition.name,
            family: mono ? "Monochrome" : "Color negative", iso: recipe.iso, provenance: provenance,
            layers: layers, dyes: spectral.imageDyeDensity.map { $0.map { max(0, $0) } },
            baseDensity: spectral.minimumDensity ?? Array(repeating: 0, count: 81),
            mixing: identity, inhibition: identity.map { $0.map { _ in 0 } },
            scanningIlluminant: white.map { Float($0 / peak) }, positiveGamma: 1))
    }

    static func encode(_ recipe: KitchenRecipe) throws -> Data {
        let profile = try profile(recipe)
        let settings = FilmProfileExchange.EditorSettings(
            summary: recipe.notes.isEmpty ? recipe.definition.name : recipe.notes,
            author: recipe.provenance[0].author, filmFormat: recipe.definition.nativeFormatID ?? "Any",
            grainCharacter: nil, defaults: [:])
        let metadata = try HSpecArchive.propertyList(settings)
        return try HSpecArchive.encode(.init(profile: profile, extensions: [.init(type: 0x4D415458, data: metadata)]))
    }
}
