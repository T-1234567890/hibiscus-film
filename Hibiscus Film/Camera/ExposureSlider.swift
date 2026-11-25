import SwiftUI

struct ExposureSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    private static let neutralDetent = 0.07

    private var position: Binding<Double> {
        Binding {
            Self.sliderPosition(for: value, in: range)
        } set: { position in
            let exposure = Self.exposureValue(for: position, in: range)
            if exposure != value { value = exposure }
        }
    }

    // Give zero a small capture zone while keeping both sides continuous and full-range.
    private static func sliderPosition(for exposure: Double, in range: ClosedRange<Double>) -> Double {
        let endpoint = exposure < 0 ? range.lowerBound : range.upperBound
        guard exposure != 0, endpoint != 0 else { return 0 }
        let progress = min(1, max(0, exposure / endpoint))
        let distance = neutralDetent + progress * (1 - neutralDetent)
        return exposure < 0 ? -distance : distance
    }

    private static func exposureValue(for position: Double, in range: ClosedRange<Double>) -> Double {
        let distance = abs(position)
        guard distance > neutralDetent else { return 0 }
        let progress = (min(distance, 1) - neutralDetent) / (1 - neutralDetent)
        return progress * (position < 0 ? min(0, range.lowerBound) : max(0, range.upperBound))
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "minus").accessibilityHidden(true)
            GeometryReader { proxy in
                track
                    .labelsHidden()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .overlay {
                        if value != 0 {
                            Circle().fill(.secondary)
                                .frame(width: 5, height: 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
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
        .sensoryFeedback(.selection, trigger: value == 0) { _, isNeutral in isNeutral }
    }

    @ViewBuilder
    private var track: some View {
        if #available(iOS 26.0, *) {
            Slider(value: position, in: -1...1, neutralValue: 0) {
                Text("Exposure compensation")
            }
        } else {
            Slider(value: position, in: -1...1) { Text("Exposure compensation") }
        }
    }
}
