import Foundation

/// Immutable, validated production model. This is deliberately distinct from illustrative HSpec v1.
nonisolated struct SpectrumProfile: Sendable, Equatable {
    static let modelVersion = 2
    struct Provenance: Codable, Sendable, Equatable {
        enum Kind: String, Codable { case authored, measured, derived }
        var kind: Kind
        var author, license, source, notice: String
    }
    struct Population: Codable, Sendable, Equatable {
        var gamma, toe, toeWidth, shoulder, shoulderWidth: Float
        func compile() throws -> SpectrumPopulation {
            try SpectrumPopulation(gamma:gamma,toe:toe,toeWidth:toeWidth,shoulder:shoulder,shoulderWidth:shoulderWidth)
        }
    }
    struct Response: Codable, Sendable, Equatable {
        // Exactly one form. Base/fog belongs exclusively to the profile's baseDensity.
        var populations: [Population] = []
        var exposure: [Float] = []
        var density: [Float] = []
        func compile() throws -> SpectrumResponse {
            if !populations.isEmpty {
                guard exposure.isEmpty, density.isEmpty else { throw Failure.invalid }
                return try SpectrumResponse(base:0,populations:populations.map { try $0.compile() })
            }
            guard density.first == 0, zip(density,density.dropFirst()).allSatisfy({ $1 >= $0 }) else { throw Failure.invalid }
            return try SpectrumResponse(sampled:SpectrumSampledCurve(exposure:exposure,density:density))
        }
    }
    struct Layer: Codable, Sendable, Equatable {
        var name: String
        var sensitivity: [Float]
        var response: Response
        /// Log10 relative speed. Neutral 18% is reference exposure zero before this offset.
        var logSpeed: Float
    }
    struct Specification: Codable, Sendable, Equatable {
        var model = SpectrumProfile.modelVersion
        var id: UUID
        var revision: Int
        var name, family: String
        var iso: Int // Descriptive box speed; never secretly applied as an exposure multiplier.
        var provenance: [Provenance]
        var layers: [Layer]
        var dyes: [[Float]]
        var baseDensity: [Float]
        /// Dye-major matrix [dye][capture layer]; nonnegative rows summing to <= 1.
        var mixing: [[Float]]
        /// Layer-major inhibition: d[i] / (1 + sum(inhibition[i][j] * d[j])).
        var inhibition: [[Float]]
        var scanningIlluminant: [Float]
        var positiveGamma: Float
    }
    enum Failure: Error, LocalizedError {
        case invalid, unsupported, legacy
        var errorDescription: String? {
            switch self {
            case .invalid: LanguageManager.text("Invalid HSpec profile or configuration.")
            case .unsupported: LanguageManager.text("This HSpec profile requires a newer model or HSpec reader.")
            case .legacy: LanguageManager.text("Illustrative HSpec v1 is not a spectral profile. Keep it in the legacy Film library.")
            }
        }
    }
    let specification: Specification
    let responses: [SpectrumResponse]
    init(_ s: Specification) throws {
        guard (1...Self.modelVersion).contains(s.model) else { throw Failure.unsupported }
        func text(_ v: String, _ limit: Int = 1024) -> Bool { !v.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && v.utf8.count <= limit }
        func samples(_ v: [Float], maximum: Float) -> Bool {
            v.count == 81 && v.allSatisfy { $0.isFinite && (0...maximum).contains($0) }
        }
        func matrix(_ m: [[Float]], rows: Int, columns: Int) -> Bool {
            m.count == rows && m.allSatisfy { row in
                row.count == columns && row.allSatisfy { $0.isFinite && (0...1).contains($0) } && row.reduce(0,+) <= 1.000001
            }
        }
        let n = s.layers.count, d = s.dyes.count
        guard (1...1_000_000).contains(s.revision), text(s.name), text(s.family), (1...204800).contains(s.iso),
              (1...32).contains(s.provenance.count), s.provenance.allSatisfy({ text($0.author) && text($0.license) && text($0.source,4096) && text($0.notice,4096) }),
              (1...8).contains(n), (1...8).contains(d),
              s.layers.allSatisfy({ text($0.name) && samples($0.sensitivity,maximum:1) && $0.sensitivity.max()! > 0.0001 && $0.logSpeed.isFinite && (-4...4).contains($0.logSpeed) }),
              s.dyes.allSatisfy({ samples($0,maximum:4) && $0.max()! > 0.0001 }),
              samples(s.baseDensity,maximum:4), samples(s.scanningIlluminant,maximum:100), s.scanningIlluminant.max()! > 0.0001,
              matrix(s.mixing,rows:d,columns:n), s.mixing.allSatisfy({ $0.reduce(0,+) > 0 }),
              matrix(s.inhibition,rows:n,columns:n),
              s.positiveGamma.isFinite, (0.25...4).contains(s.positiveGamma) else { throw Failure.invalid }
        let responses = try s.layers.map { try $0.response.compile() }
        guard try responses.allSatisfy({ try $0.density(logExposure:0) > 0.00001 }) else { throw Failure.invalid }
        self.specification = s; self.responses = responses
    }
}

/// Versioned immutable per-render settings, independent of SwiftUI and source ownership.
nonisolated struct SpectrumConfiguration: Sendable, Hashable {
    let exposureStops, strength: Float
    init(exposureStops: Float = 0, strength: Float = 1) throws {
        guard exposureStops.isFinite, (-16...16).contains(exposureStops), strength.isFinite, (0...1).contains(strength) else { throw SpectrumProfile.Failure.invalid }
        self.exposureStops = exposureStops; self.strength = strength
    }
}
