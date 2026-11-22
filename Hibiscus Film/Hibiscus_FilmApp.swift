//
//  Hibiscus_FilmApp.swift
//  Hibiscus Film
//
//  Created by Zhengyang Hu on 11/22/26.
//

import SwiftUI

@main
struct Hibiscus_FilmApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var languageManager = LanguageManager.shared

    init() {
        UserDefaults.standard.register(defaults: [CameraService.autoSaveKey: CameraService.defaultAutoSave])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(languageManager)
                .environment(\.locale, languageManager.locale)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { languageManager.refreshSystemLanguage() }
                }
        }
    }
}
