import SwiftUI

struct ExposureSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    // Keep zero at the midpoint even when the lens has asymmetric EV limits.
    private var position: Binding<Double> {
        Binding {
            let extent = value < 0 ? -range.lowerBound : range.upperBound
            return extent > 0 ? value / extent : 0
        } set: { position in
            value = position * (position < 0 ? -range.lowerBound : range.upperBound)
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "minus").accessibilityHidden(true)
            GeometryReader { proxy in
                track
                    .labelsHidden()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        if abs(tap.location.x - proxy.size.width / 2) <= 12 { value = 0 }
                    })
                    .accessibilityValue("\(value.formatted(.number.precision(.fractionLength(1)))) EV")
                    .accessibilityAction(named: "Reset to 0 EV") { value = 0 }
                    .disabled(range.lowerBound == range.upperBound)
            }
            Image(systemName: "plus").accessibilityHidden(true)
        }
        .font(.caption)
        .frame(height: 44)
    }

    @ViewBuilder
    private var track: some View {
        if #available(iOS 26.0, *) {
            Slider(value: position, in: -1...1, neutralValue: 0) {
                Text("Exposure compensation")
            } ticks: {
                SliderTick(0)
            }
        } else {
            Slider(value: position, in: -1...1) { Text("Exposure compensation") }
                .overlay {
                    if value != 0 {
                        Circle().fill(.secondary).frame(width: 5, height: 5)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }
    }
}
