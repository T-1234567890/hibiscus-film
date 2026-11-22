// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus iOS camera.
import SwiftUI

nonisolated enum CameraAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case standard = "4:3"
    case square = "1:1"
    case hpan = "HPan0.5"

    var id: Self { self }

    /// Width divided by height for a portrait camera viewport.
    var portraitRatio: CGFloat {
        switch self {
        case .standard: 3.0 / 4.0
        case .square: 1
        case .hpan: HPan.portraitRatio
        }
    }
}

nonisolated enum CaptureResolution: Int, CaseIterable {
    case automatic = 0
    case twelve = 12
    case twentyFour = 24
    case fortyEight = 48
    case maximum = -1

    static let preferenceKey = "defaultCaptureResolution"

    static func choices(native: [Int], format: CaptureFormatOption) -> [Int] {
        if format == .processed, native.contains(where: { $0 > 24 }), !native.contains(24) {
            return (native + [24]).sorted()
        }
        return native
    }

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .maximum: "Maximum"
        default: "\(rawValue) MP"
        }
    }

    static func preferred(in supported: [Int], requested: Int?, setting: Self) -> Int? {
        guard let first = supported.min() else { return nil }
        if let requested, supported.contains(requested) { return requested }
        switch setting {
        case .maximum: return supported.max()
        case .automatic: return [24, 12].first { supported.contains($0) } ?? first
        default:
            return supported.min { a, b in
                let deltaA = abs(a - setting.rawValue), deltaB = abs(b - setting.rawValue)
                return deltaA == deltaB ? a < b : deltaA < deltaB
            }
        }
    }
}

nonisolated enum CaptureFlashMode: String, CaseIterable, Identifiable, Sendable {
    case on = "On"
    case off = "Off"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        }
    }
}

nonisolated enum CaptureFormatOption: String, CaseIterable, Identifiable, Sendable {
    case processed = "HEIF"
    case raw = "RAW + JPEG"

    static let preferenceKey = "defaultCaptureFormat"
    var id: Self { self }

    func supported(rawAvailable: Bool) -> Self {
        rawAvailable ? self : .processed
    }
}

nonisolated enum CaptureMotionOption: String, CaseIterable, Identifiable, Sendable {
    case photo = "Photo"
    case livePhoto = "Live Photo"

    var id: Self { self }
}

