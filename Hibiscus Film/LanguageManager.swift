// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus iOS language manager.

import Combine
import Foundation
import SwiftUI

nonisolated enum AppLanguageMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: Self { self }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "System Default"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    nonisolated static let preferenceKey = "settings.general.language"

    @Published var mode: AppLanguageMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.preferenceKey)
            refreshLanguage()
        }
    }
    @Published private(set) var effectiveLanguage: AppLanguageMode

    var locale: Locale { Locale(identifier: effectiveLanguage.rawValue) }

    private let defaults: UserDefaults
    private let appBundle: Bundle

    init(defaults: UserDefaults = .standard, appBundle: Bundle = .main) {
        self.defaults = defaults
        self.appBundle = appBundle
        let selected = Self.savedMode(in: defaults)
        mode = selected
        effectiveLanguage = Self.resolve(selected, preferredLanguages: Locale.preferredLanguages)
    }

    func refreshSystemLanguage() {
        if mode == .system { refreshLanguage() }
    }

    func string(_ key: String) -> String {
        Self.localized(key, language: effectiveLanguage, bundle: appBundle)
    }

    // Capture and profile errors can be formatted off the main actor.
    nonisolated static func text(_ key: String) -> String {
        let language = resolve(savedMode(in: .standard), preferredLanguages: Locale.preferredLanguages)
        return localized(key, language: language, bundle: .main)
    }

    nonisolated static func resolve(_ mode: AppLanguageMode, preferredLanguages: [String]) -> AppLanguageMode {
        guard mode == .system else { return mode }
        for identifier in preferredLanguages {
            let language = Locale.Language(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
            switch language.languageCode?.identifier {
            case "en": return .english
            case "zh" where language.script?.identifier == "Hans": return .simplifiedChinese
            default: continue
            }
        }
        return .english
    }

    private func refreshLanguage() {
        let language = Self.resolve(mode, preferredLanguages: Locale.preferredLanguages)
        if effectiveLanguage != language { effectiveLanguage = language }
    }

    nonisolated private static func savedMode(in defaults: UserDefaults) -> AppLanguageMode {
        let saved = defaults.string(forKey: preferenceKey)
        switch saved {
        case "english": return .english
        case "simplifiedChinese": return .simplifiedChinese
        default: return saved.flatMap(AppLanguageMode.init(rawValue:)) ?? .system
        }
    }

    nonisolated private static func localized(_ key: String, language: AppLanguageMode, bundle: Bundle) -> String {
        guard let url = bundle.url(forResource: language.rawValue, withExtension: "lproj"),
              let localization = Bundle(url: url) else { return key }
        return localization.localizedString(forKey: key, value: key, table: nil)
    }
}
