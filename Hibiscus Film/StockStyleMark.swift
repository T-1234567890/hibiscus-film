// Adapted from the layered studio sample in Hibiscus Matrix’s StyleMatrix.swift.
import SwiftUI

extension Stock {
    var tint: Color {
        let pigment = swatch ?? Stock.collection.first { $0.recipe.fotufilmID == recipe.fotufilmID }?.swatch
        guard let pigment else { return style.tint }
        return Color(.sRGB, red: Double((pigment >> 16) & 255) / 255,
                     green: Double((pigment >> 8) & 255) / 255, blue: Double(pigment & 255) / 255)
    }
}

struct StockStyleMark: View {
    let stock: Stock
    let size: CGFloat

    var body: some View {
        let pigment = stock.tint
        ZStack {
            Image("StyleBody").resizable().colorMultiply(pigment)
            Image("StyleBounce").resizable().colorMultiply(pigment.mix(with: .white, by: 0.35))
            Image("StyleGlaze").resizable()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
