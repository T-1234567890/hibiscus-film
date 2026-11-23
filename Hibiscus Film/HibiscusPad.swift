// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus grading pad.

import SwiftUI

enum ControlDot {
    static let handle: CGFloat = 16
    static let padThumb: CGFloat = 22
}

struct PadThumb: View {
    var body: some View {
        Circle().fill(.white.opacity(0.72))
            .frame(width: ControlDot.padThumb, height: ControlDot.padThumb)
            .overlay { Circle().strokeBorder(.white.opacity(0.32), lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum PadSurface: String, CaseIterable {
  case style = "Style"
  case accent = "Accent"
}

struct HibiscusPad: View {
  let kind: PadSurface
  let tint: Color
  let point: CGPoint
  let onChange: (CGPoint) -> Void
  let editing: (Bool) -> Void
  var onReset: (() -> Void)? = nil
  @State private var dragging = false
  @Environment(\.accessibilityReduceMotion) private var reduced

  private var field: some View {
    GeometryReader { proxy in
      let marker: CGFloat = ControlDot.padThumb
      let inset = marker / 2
      let travelX = max(1, proxy.size.width - marker)
      let travelY = max(1, proxy.size.height - marker)
      ZStack {
        // The original translucent gradient stops blend against this opaque surface.
        Color(white: 0.56)
        padBackground
        DottedPaletteGrid()
        PadThumb()
          .position(x: inset + point.x * travelX, y: inset + point.y * travelY)
      }
      .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 4).onChanged { value in
          if !dragging {
            dragging = true
            editing(true)
          }
          move(
            (value.location.x - inset) / travelX,
            (value.location.y - inset) / travelY)
        }.onEnded { _ in
          dragging = false
          editing(false)
        }
      )
      .simultaneousGesture(
        SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture()).onEnded { result in
          switch result {
          case .first: reset()
          case .second(let tap): move((tap.location.x - inset) / travelX, (tap.location.y - inset) / travelY)
          }
        }
      )
    }
  }

  var body: some View {
    field.aspectRatio(1, contentMode: .fit)
      .accessibilityLabel(kind == .style ? Text("Style Color Pad") : Text("Accent Color Pad"))
      .accessibilityValue(
        "\(kind == .style ? Text("Color") : Text("Hue shift")) \(Int((point.x * 200 - 100).rounded())), \(kind == .style ? Text("Tone") : Text("Placement")) \(Int((100 - point.y * 200).rounded()))"
      )
      .accessibilityAction(named: "Reset pad") { reset() }
      .help(
        kind == .style
          ? "Drag to adjust color and tone. Double-tap to reset."
          : "Drag to shift hue and place the accent in shadows or highlights. Double-tap to reset."
      )
      .accessibilityAdjustableAction {
        move(point.x + ($0 == .increment ? 0.005 : -0.005), point.y)
      }
      .onDisappear {
        if dragging { dragging = false; editing(false) }
      }
  }

  private func reset() {
    withAnimation(reduced ? nil : .snappy(duration: 0.2)) {
      if let onReset { onReset() } else { move(0.5, 0.5) }
    }
  }
  private func move(_ x: Double, _ y: Double) {
    onChange(CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y))))
  }

    @ViewBuilder
    private var padBackground: some View {
        switch kind {
        case .style:
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.56), tint.opacity(0.76), tint],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                RadialGradient(
                    colors: [tint.mix(with: .orange, by: 0.28).opacity(0.54), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 150
                )
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.78), location: 0),
                        .init(color: .clear, location: 0.42),
                        .init(color: .black.opacity(0.88), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        case .accent:
            let base = tint
            ZStack {
                LinearGradient(
                    colors: [base.mix(with: .blue, by: 0.42), base, base.mix(with: .orange, by: 0.38)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.72), location: 0),
                        .init(color: .clear, location: 0.40),
                        .init(color: .black.opacity(0.86), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

private struct DottedPaletteGrid: View {
    var body: some View {
        Canvas { context, size in
            let columns = 11
            let rows = 11
            let inset = size.width * 0.09
            let usableWidth = size.width - inset * 2
            let usableHeight = size.height - inset * 2

            for row in 0..<rows {
                for column in 0..<columns {
                    let x = inset + usableWidth * CGFloat(column) / CGFloat(columns - 1)
                    let y = inset + usableHeight * CGFloat(row) / CGFloat(rows - 1)
                    let radius: CGFloat = row > 7 ? 1.65 : 1.35
                    let opacity = 0.36 + Double(row) / Double(rows - 1) * 0.42
                    let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    context.fill(dot, with: .color(.white.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
