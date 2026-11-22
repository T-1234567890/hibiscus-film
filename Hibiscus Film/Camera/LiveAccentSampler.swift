// SPDX-License-Identifier: MPL-2.0
// Color scoring adapted from Hibiscus AccentAnalyzer.
import CoreImage
import Synchronization
import Vision

// submit is called exclusively on the camera video queue. A slow analysis drops
// samples instead of retaining more camera buffers or delaying preview delivery.
nonisolated final class LiveAccentSampler: @unchecked Sendable {
    private let worker = DispatchQueue(label: "dev.hibiscus.accent", qos: .utility)
    private let isAnalyzing = Atomic<Bool>(false)
    private var nextSample = 0.0
    private let analyzer = SceneAccentAnalyzer()

    func submit(_ image: CIImage, generation: UUID, deliver: @escaping @Sendable (AccentRGB) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextSample, !isAnalyzing.exchange(true, ordering: .relaxed) else { return }
        nextSample = now + 0.125
        worker.async { [self] in
            defer { isAnalyzing.store(false, ordering: .relaxed) }
            autoreleasepool {
                if let color = analyzer.sample(image, generation: generation, time: now) { deliver(color) }
            }
        }
    }
}

// All mutable image-analysis state is confined to the sampling worker.
nonisolated final class SceneAccentAnalyzer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private var generation: UUID?
    private var lastFaceUpdate = -Double.infinity
    private var faceRects: [CGRect] = []
    private var filtered: AccentRGB?
    private var previousCandidate: AccentRGB?

    func sample(_ image: CIImage, generation: UUID, time: Double) -> AccentRGB? {
        if self.generation != generation {
            self.generation = generation
            filtered = nil
            previousCandidate = nil
            lastFaceUpdate = -.infinity
        }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let refreshFaces = time - lastFaceUpdate >= 1
        let scale = min(1, (refreshFaces ? 256 : 80) / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let bitmap = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: space) else { return nil }
        if refreshFaces {
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: bitmap, orientation: .up).perform([request])
            faceRects = request.results?.map(\.boundingBox) ?? []
            lastFaceUpdate = time
        }
        let width = max(1, Int((extent.width * 80 / max(extent.width, extent.height)).rounded()))
        let height = max(1, Int((extent.height * 80 / max(extent.width, extent.height)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let canvas = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            canvas.interpolationQuality = .medium
            canvas.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let candidate = Self.dominantColor(pixels, width: width, height: height, faceRects: faceRects)
        defer { previousCandidate = candidate }
        guard let old = filtered else {
            filtered = candidate
            return candidate
        }
        func distance(_ a: AccentRGB, _ b: AccentRGB) -> Double {
            max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
        }
        let delta = distance(old, candidate)
        guard delta >= 0.018 else { return nil }
        // Require a second observation for a large cut. A single passing object
        // or exposure transient should not recolor the shot.
        if delta > 0.25, let previousCandidate, distance(previousCandidate, candidate) > 0.18 { return nil }
        let weight = delta > 0.25 ? 0.80 : 0.52
        let result = AccentRGB(red: old.red + (candidate.red - old.red) * weight,
                               green: old.green + (candidate.green - old.green) * weight,
                               blue: old.blue + (candidate.blue - old.blue) * weight)
        filtered = result
        return result
    }
    private struct Bucket {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weight = 0.0
        var count = 0
    }

    static func dominantColor(_ pixels: [UInt8], width: Int, height: Int, faceRects: [CGRect]) -> AccentRGB {
        // Fixed bins avoid per-pixel hashing and give tied colors a stable order.
        var buckets = [Bucket](repeating: Bucket(), count: 18 * 4 * 4)
        var saturationTotal = 0.0
        var validCount = 0

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let r = Double(pixels[index]) / 255
                let g = Double(pixels[index + 1]) / 255
                let b = Double(pixels[index + 2]) / 255
                let hsb = AccentAnalyzer.rgbToHSB(red: r, green: g, blue: b)

                guard hsb.brightness > 0.10, hsb.brightness < 0.94, hsb.saturation > 0.10 else { continue }
                validCount += 1
                saturationTotal += hsb.saturation

                let nx = (Double(x) + 0.5) / Double(width)
                let ny = (Double(y) + 0.5) / Double(height)
                let centerDistance = hypot(nx - 0.5, ny - 0.5) / 0.707
                let centerWeight = 1.18 - min(1, centerDistance) * 0.28
                let luminanceWeight = 1 - abs(hsb.brightness - 0.55) * 0.78
                let saturationWeight = 0.35 + pow(hsb.saturation, 0.82)
                let edgeWeight = localContrast(pixels: pixels, x: x, y: y, width: width, height: height, r: r, g: g, b: b)
                let inFace = faceRects.contains { $0.contains(CGPoint(x: nx, y: 1 - ny)) }
                let faceWeight = inFace ? 0.42 : 1.0
                let skinLike = (hsb.hue < 0.12 || hsb.hue > 0.97) && hsb.saturation < 0.72
                let skinWeight = skinLike ? 0.78 : 1.0
                let weight = centerWeight * luminanceWeight * saturationWeight * edgeWeight * faceWeight * skinWeight

                let hueBin = min(17, Int(hsb.hue * 18))
                let satBin = min(3, Int(hsb.saturation * 4))
                let lightBin = min(3, Int(hsb.brightness * 4))
                let key = (hueBin * 4 + satBin) * 4 + lightBin
                buckets[key].red += r * weight
                buckets[key].green += g * weight
                buckets[key].blue += b * weight
                buckets[key].weight += weight
                buckets[key].count += 1
            }
        }

        guard validCount > width * height / 35,
              saturationTotal / Double(max(1, validCount)) > 0.16 else {
            return .neutralGray
        }

        let minimumPopulation = max(5, validCount / 220)
        var winner: Bucket?
        var bestScore = 0.0
        for bucket in buckets where bucket.count >= minimumPopulation {
            let score = bucket.weight * log2(Double(bucket.count) + 2)
            if score > bestScore {
                bestScore = score
                winner = bucket
            }
        }

        guard let winner, winner.weight > 0 else { return .neutralGray }
        return AccentRGB(
            red: min(1, max(0, winner.red / winner.weight)),
            green: min(1, max(0, winner.green / winner.weight)),
            blue: min(1, max(0, winner.blue / winner.weight))
        )
    }

    private static func localContrast(
        pixels: [UInt8], x: Int, y: Int, width: Int, height: Int,
        r: Double, g: Double, b: Double
    ) -> Double {
        let sampleX = min(width - 1, x + 3)
        let sampleY = min(height - 1, y + 3)
        let index = (sampleY * width + sampleX) * 4
        let rr = Double(pixels[index]) / 255
        let gg = Double(pixels[index + 1]) / 255
        let bb = Double(pixels[index + 2]) / 255
        let difference = abs(r - rr) + abs(g - gg) + abs(b - bb)
        return 0.92 + min(0.65, difference * 0.55)
    }

}
