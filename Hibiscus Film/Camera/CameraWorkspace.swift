import SwiftUI

enum CameraHingePose { case ordinary, partial, flat }

extension View {
    @ViewBuilder
    func observeCameraHinge(_ pose: Binding<CameraHingePose>) -> some View {
        if #available(iOS 27.1, *) {
            onHingeChange { _, context in
                switch context.hinge?.status {
                case .partiallyOpen: pose.wrappedValue = .partial
                case .fullyOpen: pose.wrappedValue = .flat
                default: pose.wrappedValue = .ordinary
                }
            }
        } else { self }
    }
}

// All rectangles use local safe-area coordinates.
struct CameraWorkspace {
    enum Mode { case portrait, duoWide, waistLevel }
    let mode: Mode
    let finder: CGRect
    let controls: CGRect
    let lens: CGPoint
    let gradingCenter: CGPoint
    let padSize: CGFloat
    let verticalDivision: CGRect?
    static let shutterDiameter: CGFloat = 72
    static let navigationSpace = "cameraTabNavigation"
    // Shutter coordinates belong to the tab container, which includes its navigation bar.
    let navigationShutter: CGRect?

    static func division(in proxy: GeometryProxy, pose: CameraHingePose) -> CGRect? {
        guard #available(iOS 27.1, *), pose == .partial else { return nil }
        return proxy.reservedRegions(kind: .division).map(\.frame).first {
            ($0.width > $0.height && $0.width >= proxy.size.width * 0.8) ||
            ($0.height > $0.width && $0.height >= proxy.size.height * 0.8)
        }
    }

    init(cameraFrame: CGRect, navigationSize: CGSize, portraitRatio: CGFloat, fold: CGRect?, pose: CameraHingePose = .ordinary,
         exposureVisible: Bool = false) {
        let size = cameraFrame.size
        let bounds = CGRect(origin: .zero, size: size)
        let crease = fold?.intersection(bounds)
        if let crease, !crease.isNull, crease.height > crease.width,
           crease.minX >= 180, size.width - crease.maxX >= 220 {
            verticalDivision = crease
        } else {
            verticalDivision = nil
        }

        let finderArea: CGRect
        if let crease, !crease.isNull, crease.width > crease.height,
           crease.minY >= 130, size.height - crease.maxY >= 150 {
            mode = .waistLevel
            controls = CGRect(x: 0, y: 0, width: size.width, height: crease.minY)
            let navigationHeight = max(0, navigationSize.height - cameraFrame.maxY)
            let diameter = min(Self.shutterDiameter + 4, max(60, navigationHeight))
            // On a wide Duo the trailing corner sits beside the centered tabs.
            // Narrow windows reserve their own row above the tab bar.
            let bottom = navigationSize.width >= 440 ? navigationSize.height : cameraFrame.maxY
            let shutter = CGRect(x: cameraFrame.maxX - diameter - 14,
                                 y: bottom - diameter - 4, width: diameter, height: diameter)
            navigationShutter = shutter
            let finderBottom = min(size.height, shutter.minY - cameraFrame.minY - 4)
            finderArea = CGRect(x: 0, y: crease.maxY, width: size.width,
                                height: max(0, finderBottom - crease.maxY))
        } else if verticalDivision != nil || (pose != .ordinary && size.width > size.height) {
            navigationShutter = nil
            mode = .duoWide
            let closedHeight: CGFloat = Self.shutterDiameter + (verticalDivision == nil ? 80 : 28)
            let deck = min(size.height, closedHeight + (exposureVisible ? 50 : 0))
            controls = CGRect(x: 0, y: size.height - deck, width: size.width, height: deck)
            finderArea = CGRect(x: 0, y: 0, width: size.width, height: controls.minY)
        } else {
            navigationShutter = nil
            mode = .portrait
            finderArea = bounds
            let deck = min(size.height, Self.shutterDiameter + (exposureVisible ? 130 : 80))
            controls = CGRect(x: 0, y: size.height - deck, width: size.width, height: deck)
        }

        if (mode == .waistLevel || verticalDivision != nil) && portraitRatio != 1 {
            // Give the live feed the whole viewing surface in a folded posture.
            // The Metal preview aspect-fills it; the capture keeps the selected ratio.
            finder = finderArea
        } else {
            let ratio = mode != .portrait && finderArea.width > finderArea.height ? 1 / portraitRatio : portraitRatio
            let width = min(finderArea.width, finderArea.height * ratio)
            let height = width / ratio
            let x = finderArea.midX - width / 2
            let y = mode == .portrait ? max(0, (bounds.height - (Self.shutterDiameter + 80) - height) / 2) : finderArea.midY - height / 2
            finder = CGRect(x: x, y: y, width: width, height: height)
        }
        if mode == .waistLevel {
            lens = CGPoint(x: finder.midX, y: finder.minY + 24)
        } else {
            lens = CGPoint(x: finder.midX, y: min(finder.maxY, controls.minY - 18))
        }

        let editingArea = mode == .waistLevel ? controls : bounds
        let availablePadWidth = verticalDivision.map { min($0.minX - 16, size.width - $0.maxX - 66) }
            ?? (editingArea.width - 76) / 2
        padSize = max(1, min(190, availablePadWidth, editingArea.height - 46))
        let editorHeight = padSize + 22
        let centerY = mode == .waistLevel ? controls.maxY - editorHeight / 2 - 8 :
            min(bounds.maxY - 8 - editorHeight / 2, finder.maxY - 32 + editorHeight / 2)
        // Center the gap between pads over a vertical fold. The strength slider
        // and its 8-point spacing add 52 points on the right of the pair.
        gradingCenter = CGPoint(x: verticalDivision.map { $0.midX + 26 } ?? editingArea.midX, y: centerY)
    }
}
