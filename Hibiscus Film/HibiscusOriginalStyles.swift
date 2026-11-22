// SPDX-License-Identifier: MPL-2.0
// Adapted from Hibiscus LookModels.swift and ImageRenderer.swift, revision
// 1a409d2c54f0ea984d42876ad603615bab7987c0. See NOTICE.md and LICENSE.
// Legacy identifiers remain decodable for saved Film user recipes.

import CoreImage
import SwiftUI

nonisolated enum OriginalStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case pure = "Pure"
    case air = "Air"
    case glow = "Glow"
    case soft = "Soft"
    case rich = "Rich"
    case chrome = "Chrome"
    case fade = "Fade"
    case ember = "Ember"
    case blush = "Blush"
    case moss = "Moss"
    case tide = "Tide"
    case dusk = "Dusk"
    case cinema = "Cinema"
    case neon = "Neon"
    case silver = "Silver"
    case ink = "Ink"

    var id: Self { self }

    var tint: Color {
        switch self {
        case .pure: Color(white: 0.78)
        case .air: Color(red: 0.67, green: 0.83, blue: 0.92)
        case .glow: Color(red: 0.96, green: 0.75, blue: 0.48)
        case .soft: Color(red: 0.84, green: 0.75, blue: 0.82)
        case .rich: Color(red: 0.52, green: 0.22, blue: 0.26)
        case .chrome: Color(red: 0.22, green: 0.61, blue: 0.84)
        case .fade: Color(red: 0.68, green: 0.64, blue: 0.51)
        case .ember: Color(red: 0.92, green: 0.38, blue: 0.17)
        case .blush: Color(red: 0.94, green: 0.53, blue: 0.57)
        case .moss: Color(red: 0.42, green: 0.53, blue: 0.28)
        case .tide: Color(red: 0.10, green: 0.62, blue: 0.70)
        case .dusk: Color(red: 0.39, green: 0.33, blue: 0.68)
        case .cinema: Color(red: 0.18, green: 0.52, blue: 0.48)
        case .neon: Color(red: 0.78, green: 0.15, blue: 0.67)
        case .silver: Color(white: 0.66)
        case .ink: Color(white: 0.20)
        }
    }
}

nonisolated enum HibiscusOriginalStyles {
    static func splitTone(_ image: CIImage, shadow: CIColor, highlight: CIColor, amount: Double, placement: Double) -> CIImage {
        let extent = image.extent
        let shadowColor = CIImage(color: shadow).cropped(to: extent)
        let highlightColor = CIImage(color: highlight).cropped(to: extent)
        let pivot = max(-0.45, min(0.45, placement))
        let highlightMask = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputBrightnessKey: -pivot * 0.18,
            kCIInputContrastKey: 1.32
        ])
        let shadowMask = highlightMask.applyingFilter("CIColorInvert")
        let shadowed = shadowColor.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        let shadowBlend = shadowed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: shadowMask])
        let highlighted = highlightColor.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: shadowBlend])
        let toned = highlighted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: shadowBlend, kCIInputMaskImageKey: highlightMask]).cropped(to: extent)
        return dissolve(image, toned, amount: amount)
    }


    // Matrix uses an alpha-preserving interpolation, including translucent photographs.
    private static func dissolve(_ background: CIImage, _ foreground: CIImage, amount: Double) -> CIImage {
        background.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: foreground, kCIInputTimeKey: max(0,min(1,amount))
        ]).cropped(to: background.extent)
    }
}
