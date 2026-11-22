// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus iOS camera.
import SwiftUI

extension Color {
    static let hibiscusAccent = Color(red: 138 / 255, green: 175 / 255, blue: 163 / 255)
}
import UIKit

extension UIImage {
    static let hibiscusAppIcon: UIImage? = {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        return files.reversed().lazy.compactMap { UIImage(named: $0) }.first
    }()
}

struct PhotoFitView: View {
    let image: UIImage

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct StatusPill: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .hibiscusGlass(tint: .black.opacity(0.35), in: Capsule())
            .padding()
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
            ))
    }
}

