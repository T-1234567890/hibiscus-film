// SPDX-License-Identifier: MPL-2.0
// Discovery preferences adapted from Hibiscus AppPreferences.
import Combine
import Foundation

@MainActor
final class DiscoveryPreferences: ObservableObject {
    private let defaults: UserDefaults
    private let dismissedKey = "state.discovery.exploreMoreDismissedAt"
    private let openedKey = "state.discovery.exploreMoreOpenedAt"
    private static let enabledKey = "settings.discovery.exploreMoreAfterExport"
    private var openedDuringPresentation = false
    @Published var isPresented = false
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled && !oldValue {
                defaults.removeObject(forKey: dismissedKey)
                defaults.removeObject(forKey: openedKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    @discardableResult
    func presentAfterExport(at date: Date = Date()) -> Bool {
        guard enabled, !isPresented else { return false }
        if let dismissal = defaults.object(forKey: dismissedKey) as? Date,
           date < dismissal.addingTimeInterval(7 * 24 * 60 * 60) { return false }
        if let opened = defaults.object(forKey: openedKey) as? Date,
           date < opened.addingTimeInterval(20 * 24 * 60 * 60) { return false }
        openedDuringPresentation = false
        isPresented = true
        return true
    }

    func recordOpen() {
        if isPresented { openedDuringPresentation = true }
        defaults.set(Date(), forKey: openedKey)
        defaults.removeObject(forKey: dismissedKey)
    }

    func didDismiss() {
        if !openedDuringPresentation { defaults.set(Date(), forKey: dismissedKey) }
        openedDuringPresentation = false
    }
}
