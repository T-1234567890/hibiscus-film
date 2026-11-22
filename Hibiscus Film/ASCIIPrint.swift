import CoreImage
import CoreText
import Foundation

nonisolated enum ASCIIPrint {
    // Render the system monospace outlines once. Sorting by actual ink coverage
    // gives the shader a portable light-to-heavy ramp without shipping a font.
    private static let glyphSize = CGSize(width: 24, height: 36)
    private static let characters = Array(".:-=+*#%@".utf16)
    private struct Resources {
        let atlas: CIImage
        let kernel: CIKernel

        init() throws {
            guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
                throw CocoaError(.fileNoSuchFile)
            }
            kernel = try CIKernel(functionName: "filmASCII", fromMetalLibraryData: Data(contentsOf: url, options: .mappedIfSafe))
            let font = CTFontCreateWithName("Menlo-Regular" as CFString, 30, nil)
            let width = Int(glyphSize.width), height = Int(glyphSize.height)
            let gray = CGColorSpaceCreateDeviceGray()
            var tiles: [(coverage: Int, pixels: [UInt8])] = []
            for var character in characters {
                var glyph: CGGlyph = 0
                guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { continue }
                var pixels = [UInt8](repeating: 0, count: width * height)
                try pixels.withUnsafeMutableBytes { bytes in
                    guard let canvas = CGContext(data: bytes.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)
                    else { throw CocoaError(.coderInvalidValue) }
                    canvas.setFillColor(gray: 1, alpha: 1)
                    var baseline = CGPoint(x: 3, y: 8)
                    CTFontDrawGlyphs(font, &glyph, &baseline, 1, canvas)
                }
                tiles.append((pixels.reduce(0) { $0 + Int($1) }, pixels))
            }
            guard tiles.count == characters.count else { throw CocoaError(.coderInvalidValue) }
            tiles.sort { $0.coverage < $1.coverage }
            let stride = width * tiles.count
            var bitmap = Data(capacity: stride * height)
            for row in 0..<height {
                for tile in tiles { bitmap.append(contentsOf: tile.pixels[row * width..<(row + 1) * width]) }
            }
            atlas = CIImage(bitmapData: bitmap, bytesPerRow: stride, size: CGSize(width: stride, height: height),
                            format: .L8, colorSpace: nil)
        }
    }
    private static let resources = Result { try Resources() }

    static func render(_ photo: CIImage, palette: PrintPalette, fill: Double) throws -> CIImage {
        guard fill > 0 else { return photo }
        let resources = try resources.get()
        let bounds = photo.extent
        let unit = max(bounds.width, bounds.height) / 102
        let columns = max(1, (bounds.width / unit).rounded())
        let rows = max(1, (bounds.height / (unit * glyphSize.height / glyphSize.width)).rounded())
        let pitch = CGSize(width: bounds.width / columns, height: bounds.height / rows)
        let grid = CGRect(x: 0, y: 0, width: columns, height: rows)
        let cells = photo.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: 1 / pitch.height, kCIInputAspectRatioKey: pitch.height / pitch.width
        ]).cropped(to: grid)
        let atlas = resources.atlas
        let inks = palette.colors
        guard let output = resources.kernel.apply(extent: bounds, roiCallback: { input, rect in
            switch input {
            case 1:
                return rect.applying(.init(scaleX: 1 / pitch.width, y: 1 / pitch.height))
                    .insetBy(dx: -2, dy: -2).intersection(grid)
            case 2: return atlas.extent
            default: return rect
            }
        }, arguments: [photo, cells, atlas, CIVector(x: pitch.width, y: pitch.height),
                       CIVector(x: columns, y: rows), CIVector(x: glyphSize.width, y: glyphSize.height),
                       Double(characters.count), 1 - pow(fill, 0.68), palette == .photoColors ? 1.0 : 0.0, inks.dark, inks.light])
        else { throw CocoaError(.coderInvalidValue) }
        return output
    }
}
