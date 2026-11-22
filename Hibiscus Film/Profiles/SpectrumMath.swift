// Spectrum adaptations of Fotufilm, Copyright 2026 MUAStudio Inc., Apache-2.0.
// Modified for Matrix 2026-11-13: immutable validated types, explicit integration
// units/base density, bounded numeric domains and no Halide/data/LUT dependencies.
// Modified for Hibiscus Film: iOS integration and localized diagnostics.
// Upstream revision, symbols and changes: ProfileSources/SpectrumNotices/ADOPTION.md.
import Foundation

nonisolated enum SpectrumError: Error, LocalizedError {
    case invalidSamples, invalidCurve, invalidResources, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidSamples: LanguageManager.text("Invalid wavelength-domain samples.")
        case .invalidCurve: LanguageManager.text("Invalid film density response.")
        case .invalidResources: LanguageManager.text("Incompatible or undersized film profile resources.")
        case .unavailable: LanguageManager.text("The film processing kernels are unavailable.")
        }
    }
}

/// Stable numerical primitives, not a serialized Film Profile or RGB reconstruction model.
nonisolated enum SpectrumMath {
    static let version = 1
    static let bandCount = 81
    static let stepNM: Float = 5
    static let wavelengths = (0..<bandCount).map { Float(380 + 5 * $0) }
    static let maximumLayers = 8

    static func softplus(_ x: Float) -> Float {
        if x > 20 { return x }
        if x < -20 { return exp(x) }
        return log1p(exp(x))
    }

    /// Trapezoidal quadrature over 380...780 nm. Response is not silently normalized.
    static func integrate(_ radiance: SpectrumSamples, against response: SpectrumSamples) -> Float {
        var result: Float = 0
        for i in 0..<bandCount {
            let weight: Float = i == 0 || i == bandCount - 1 ? 0.5 : 1
            result += radiance.values[i] * response.values[i] * weight * stepNM
        }
        return result
    }

    /// Amounts are image dye density ABOVE base/fog, never total record density.
    /// The separately supplied base is included exactly once. Capture-to-dye mixing
    /// belongs to the profile compiler; capture-layer and dye counts need not match.
    static func transmission(amounts: [Float], dyes: [SpectrumSamples], base: SpectrumSamples,
                             neutralDensity: Float = 0) throws -> SpectrumSamples {
        guard (1...maximumLayers).contains(amounts.count), amounts.count == dyes.count,
              amounts.allSatisfy({ $0.isFinite && (0...32).contains($0) }),
              neutralDensity.isFinite, (0...32).contains(neutralDensity) else { throw SpectrumError.invalidSamples }
        return try SpectrumSamples((0..<bandCount).map { band in
            var density = base.values[band] + neutralDensity
            for dye in dyes.indices { density += amounts[dye] * dyes[dye].values[band] }
            return pow(10, -density)
        })
    }
}

/// Nonnegative radiance, sensitivity, absorption or receiver samples. The semantic
/// domain belongs to the caller; all share the same explicit wavelength grid.
nonisolated struct SpectrumSamples: Hashable, Sendable {
    let values: [Float]
    init(_ values: [Float]) throws {
        guard values.count == SpectrumMath.bandCount,
              values.allSatisfy({ $0.isFinite && (0...1_000_000).contains($0) }) else { throw SpectrumError.invalidSamples }
        self.values = values
    }
}

/// One additive speed population in a Hurter–Driffield density response.
nonisolated struct SpectrumPopulation: Hashable, Sendable {
    let gamma, toe, toeWidth, shoulder, shoulderWidth: Float
    init(gamma: Float, toe: Float, toeWidth: Float, shoulder: Float, shoulderWidth: Float) throws {
        guard [gamma,toe,toeWidth,shoulder,shoulderWidth].allSatisfy(\.isFinite),
              (0...10).contains(gamma), (-32...32).contains(toe), (-32...32).contains(shoulder),
              shoulder > toe, (0.001...4).contains(toeWidth), (0.001...4).contains(shoulderWidth),
              gamma * (shoulder - toe) <= 32 else { throw SpectrumError.invalidCurve }
        self.gamma = gamma; self.toe = toe; self.toeWidth = toeWidth
        self.shoulder = shoulder; self.shoulderWidth = shoulderWidth
    }
    var range: Float { gamma * (shoulder - toe) }
    func density(_ x: Float) -> Float {
        // Prevent inf-inf and loss of the shoulder difference at extreme finite inputs.
        if x >= shoulder + 64 * max(toeWidth,shoulderWidth) { return range }
        if x <= toe - 64 * max(toeWidth,shoulderWidth) { return 0 }
        let t = toeWidth * SpectrumMath.softplus((x - toe) / toeWidth)
        let s = shoulderWidth * SpectrumMath.softplus((x - shoulder) / shoulderWidth)
        return gamma * min(max(t - s,0),shoulder - toe)
    }
    var packed: [Float] { [gamma,toe,toeWidth,shoulder,shoulderWidth] }
}

/// Shape-preserving Hermite interpolation adapted from Fotufilm's sampled curve.
/// Retains measured local extrema; constant tails join with zero endpoint slope.
nonisolated struct SpectrumSampledCurve: Hashable, Sendable {
    let exposure, density, slopes: [Float]
    init(exposure: [Float], density: [Float]) throws {
        guard (2...1024).contains(exposure.count), exposure.count == density.count,
              exposure.allSatisfy({ $0.isFinite && (-32...32).contains($0) }),
              density.allSatisfy({ $0.isFinite && (0...32).contains($0) }),
              zip(exposure,exposure.dropFirst()).allSatisfy({ $1 - $0 >= 0.00001 }) else { throw SpectrumError.invalidCurve }
        self.exposure = exposure; self.density = density
        var slopes = [Float](repeating:0,count:density.count)
        for i in 1..<(density.count - 1) {
            let h0 = Double(exposure[i]) - Double(exposure[i-1])
            let h1 = Double(exposure[i+1]) - Double(exposure[i])
            let d0 = (Double(density[i]) - Double(density[i-1])) / h0
            let d1 = (Double(density[i+1]) - Double(density[i])) / h1
            if d0 * d1 > 0 {
                let w0 = 2 * h1 + h0, w1 = h1 + 2 * h0
                slopes[i] = Float((w0 + w1) / (w0 / d0 + w1 / d1))
            }
        }
        guard slopes.allSatisfy(\.isFinite) else { throw SpectrumError.invalidCurve }
        self.slopes = slopes
    }
    func value(_ x: Float) -> Float {
        if x <= exposure[0] { return density[0] }
        if x >= exposure.last! { return density.last! }
        var low = 0, high = exposure.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if exposure[mid] <= x { low = mid } else { high = mid }
        }
        let h = exposure[high] - exposure[low], t = min(max((x - exposure[low]) / h,0),1)
        let delta = density[high] - density[low], a = h * slopes[low], b = h * slopes[high]
        return density[low] + t * (a + t * (3 * delta - 2 * a - b + t * (-2 * delta + a + b)))
    }
}

/// A validated immutable response, reusable by CPU reference and Metal profile compilation.
/// Internal GPU layout is versioned with SpectrumMath; it is NOT the HSpec file format.
nonisolated struct SpectrumResponse: Hashable, Sendable {
    private let base: Float
    private let populations: [SpectrumPopulation]
    private let sampled: SpectrumSampledCurve?
    init(base: Float, populations: [SpectrumPopulation]) throws {
        guard base.isFinite, (0...16).contains(base), (1...4).contains(populations.count),
              base + populations.reduce(0,{ $0 + $1.range }) <= 32 else { throw SpectrumError.invalidCurve }
        self.base = base; self.populations = populations; sampled = nil
    }
    init(sampled: SpectrumSampledCurve) {
        base = 0; populations = []; self.sampled = sampled
    }
    func density(logExposure: Float) throws -> Float {
        guard logExposure.isFinite else { throw SpectrumError.invalidCurve }
        return sampled?.value(logExposure) ?? (base + populations.reduce(0,{ $0 + $1.density(logExposure) }))
    }
    var packed: [Float] {
        if let sampled {
            return [1,0,0,Float(sampled.exposure.count)] + sampled.exposure.indices.flatMap {
                [sampled.exposure[$0],sampled.density[$0],sampled.slopes[$0]]
            }
        }
        return [0,base,Float(populations.count),0] + populations.flatMap(\.packed)
    }
}
