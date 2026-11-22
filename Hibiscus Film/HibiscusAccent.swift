// SPDX-License-Identifier: MPL-2.0
// Adapted for macOS from the Hibiscus open-source project. See NOTICE.md and LICENSE.

import Foundation

import SwiftUI

nonisolated struct AccentRGB: Codable, Hashable, Sendable {
  var red: Double, green: Double, blue: Double
  static let neutralGray = Self(red: 0.5, green: 0.5, blue: 0.5)
  var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
  func shifted(_ shift: Double) -> Color {
    shiftedRGB(shift).color
  }
  func shiftedRGB(_ shift: Double) -> Self {
    let hsv = AccentAnalyzer.rgbToHSB(red: red, green: green, blue: blue)
    let h = (hsv.hue + shift + 1).truncatingRemainder(dividingBy: 1) * 6
    let s = min(0.68, hsv.saturation * 0.86)
    let v = min(0.78, max(0.32, hsv.brightness))
    func channel(_ offset: Double) -> Double {
      let k = (offset + h).truncatingRemainder(dividingBy: 6)
      return v * (1 - s * max(0, min(1, min(k, 4 - k))))
    }
    return Self(red: channel(5), green: channel(3), blue: channel(1))
  }
}

nonisolated enum AccentAnalyzer {
  static func rgbToHSB(red: Double, green: Double, blue: Double) -> (
    hue: Double, saturation: Double, brightness: Double
  ) {
    let maxValue = max(red, green, blue)
    let minValue = min(red, green, blue)
    let delta = maxValue - minValue
    let saturation = maxValue == 0 ? 0 : delta / maxValue
    var hue = 0.0
    if delta > 0 {
      if maxValue == red {
        hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
      } else if maxValue == green {
        hue = (blue - red) / delta + 2
      } else {
        hue = (red - green) / delta + 4
      }
      hue /= 6
      if hue < 0 { hue += 1 }
    }
    return (hue, saturation, maxValue)
  }

}

nonisolated struct PadAccent: Codable, Hashable, Sendable {
  var manual: AccentRGB?
  var x = 0.5
  var y = 0.5
  var strength = 0.52

  var isValid: Bool {
    let values = [x, y, strength] + (manual.map { [$0.red, $0.green, $0.blue] } ?? [])
    return values.allSatisfy { (0...1).contains($0) }
  }

  // Preserve the original hue displacement, tonal placement and independent final blend.
  func tones(base: AccentRGB) -> (shadow: AccentRGB, highlight: AccentRGB, pivot: Double) {
    let hueShift = (x - 0.5) * 0.24
    let placement = 0.5 - y
    let adjusted = base.shiftedRGB(hueShift)
    let companion = adjusted.shiftedRGB(placement >= 0 ? -0.09 : 0.09)
    return (
      placement < 0 ? adjusted : companion, placement >= 0 ? adjusted : companion,
      min(0.45, max(-0.45, placement))
    )
  }
}

