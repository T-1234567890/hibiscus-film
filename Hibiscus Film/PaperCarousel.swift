import SwiftUI

struct PaperCarousel<Item: Hashable>: View {
    let finishes: [Item]
    let thumbnails: [Item: CGImage]
    let name: (Item) -> String
    let label: LocalizedStringKey
    let fallback: UIImage
    @Binding var selection: Int
    @State private var displacement: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let side = min(222, proxy.size.height * 0.86, proxy.size.width * 0.42)
            // Leave the outer edge of each neighboring sheet beyond the viewport.
            let stride = max(1, proxy.size.width / 2 - side * 0.265)
            let angleStep = 0.52
            let radius = stride / sin(angleStep)
            ZStack {
                ForEach(finishes.indices, id: \.self) { index in
                    let delta = distance(to: index) + displacement
                    let distance = abs(delta)
                    let prominence = max(0, 1 - distance)
                    let angle = Double(delta) * angleStep
                    let shape = RoundedRectangle(cornerRadius: side * 0.12, style: .continuous)
                    Group {
                        if let thumb = thumbnails[finishes[index]] {
                            Image(decorative: thumb, scale: 1).resizable()
                        } else { Image(uiImage: fallback).resizable() }
                    }
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.75) }
                    .contentShape(shape)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 3)
                    .scaleEffect(0.72 + 0.28 * prominence)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(delta) * 9))
                    .opacity((0.48 + 0.52 * prominence) * max(0, min(1, 2 - distance)))
                    .offset(x: radius * sin(angle), y: side * (0.18 * (1 - cos(angle)) / (1 - cos(angleStep)) - 0.05))
                    .zIndex(2 - Double(distance))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in displacement = max(-1, min(1, drag.translation.width / stride)) }
                .onEnded { drag in
                    let movement = drag.predictedEndTranslation.width / stride
                    let step: Int
                    if abs(drag.translation.width) < 7 && abs(drag.translation.height) < 10 {
                        let x = drag.location.x - proxy.size.width / 2
                        step = abs(x) > side / 2 ? (x > 0 ? 1 : -1) : 0
                    } else {
                        step = abs(movement) > 0.16 ? (movement < 0 ? 1 : -1) : 0
                    }
                    settle(on: wrapped(selection + step))
                })
            .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Text(LocalizedStringKey(name(finishes[selection]))))
        .accessibilityAdjustableAction { settle(on: wrapped(selection + ($0 == .increment ? 1 : -1))) }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func wrapped(_ index: Int) -> Int { (index + finishes.count) % finishes.count }

    private func distance(to index: Int) -> CGFloat {
        let half = finishes.count / 2
        return CGFloat(wrapped(index - selection + half) - half)
    }

    private func settle(on index: Int) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.12)) {
            selection = index
            displacement = 0
        }
    }
}
