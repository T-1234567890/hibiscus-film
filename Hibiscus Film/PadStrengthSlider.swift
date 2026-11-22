// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus Matrix Color Pad.
import SwiftUI

/// A pad-height strength control: full strength at the colored end, zero at the neutral end.
struct PadStrengthSlider: View {
  let title: String
  @Binding var value: Double
  let tint: Color
  @Environment(\.accessibilityReduceMotion) private var reduced
  @State private var dragging = false

  private func assign(_ proposed: Double) {
    guard proposed.isFinite else { return }
    value = min(100, max(0, proposed))
  }

  var body: some View {
    GeometryReader { geo in
      let diameter = ControlDot.padThumb
      let travel = max(1, geo.size.height - diameter - 4)
      ZStack(alignment: .top) {
        Capsule().fill(LinearGradient(
          colors: [tint, tint.mix(with: Color(white: 0.53), by: 0.55), Color(white: 0.53)],
          startPoint: .top, endPoint: .bottom))
          .frame(width: 24)
        PadThumb()
          .offset(y: 2 + (1 - min(100, max(0, value)) / 100) * travel)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
          dragging = true
          assign((1 - (event.location.y - diameter / 2 - 2) / travel) * 100)
        }.onEnded { _ in dragging = false })
        .animation(dragging || reduced ? nil : .smooth(duration: 0.18), value: value)
        .animation(reduced ? nil : .smooth(duration: 0.2), value: tint)
    }.frame(width: 44)
      .accessibilityLabel(title)
      .accessibilityValue("\(Int(value.rounded())) percent")
      .accessibilityAdjustableAction { assign(value + ($0 == .increment ? 1 : -1)) }
      .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { key in
        let direction: Double = key.key == .upArrow || key.key == .rightArrow ? 1 : -1
        assign(value + direction * (key.modifiers.contains(.shift) ? 10 : 1))
        return .handled
      }
      .help(title + ": drag up to increase, down to decrease")
      .onDisappear { if dragging { dragging = false } }
  }
}
