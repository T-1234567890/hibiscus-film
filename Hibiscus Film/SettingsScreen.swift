import Photos
import SwiftUI

struct SettingsScreen: View {
    let effectsPhoto: CGImage?
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var discovery: DiscoveryPreferences
    @EnvironmentObject private var remoteContent: RemoteContentManager
    @Environment(FilmSession.self) private var session
    @EnvironmentObject private var languageManager: LanguageManager
    @AppStorage(FilmSession.defaultStockPreferenceKey) private var defaultID = Stock.classicDefault.id
    @AppStorage(CaptureFormatOption.preferenceKey) private var captureFormat = CaptureFormatOption.processed
    @AppStorage(CaptureResolution.preferenceKey) private var resolution = CaptureResolution.automatic
    @AppStorage("defaultLive") private var defaultLive = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CameraService.autoSaveKey) private var autoSave = CameraService.defaultAutoSave
    @AppStorage(CameraAutoSaveFormat.preferenceKey) private var autoSaveFormat = CameraAutoSaveFormat.photo
    @State private var requestingPhotoAccess = false
    @State private var showPhotoPermissionAlert = false
    @State private var showingSupport = false
    @State private var showingSupporterPack = false
    var body: some View {
        @Bindable var session = session
        Form {
            Section {
                Button {
                    showingSupport = true
                } label: {
                    SettingsRow(title: "Support Hibiscus", subtitle: "Help keep independent development going.")
                }

                Button {
                    showingSupporterPack = true
                } label: {
                    SettingsRow(title: "Supporter Pack", subtitle: "Recipe Kitchen and seven additional Effects")
                }
            }

            Section("General") {
                NavigationLink {
                    List(AppLanguageMode.allCases) { option in
                        Button { languageManager.mode = option } label: {
                            HStack {
                                Text(option.titleKey).foregroundStyle(.primary)
                                Spacer()
                                if languageManager.mode == option { Image(systemName: "checkmark") }
                            }.contentShape(Rectangle())
                        }
                    }
                    .navigationTitle(languageManager.string("Language"))
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Text("Language")
                        Spacer()
                        Text(languageManager.mode.titleKey).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Camera") {
                Toggle(isOn: $session.lockFocus) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fixed Focus")
                        Text("Keep the lens at its current focus distance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Default Film Stock", selection: $defaultID) {
                    ForEach(session.stocks.filter(\.canRender)) { Text($0.name).tag($0.id) }
                }
                .onChange(of: defaultID) {
                    if let stock = session.stocks.first(where: { $0.id == defaultID }) { session.load(stock) }
                }
                Picker("Film Expiration", selection: Binding(get: { session.expiration }, set: session.setExpiration)) {
                    Text("Off").tag(FilmExpiration.off)
                    Text("Random").tag(FilmExpiration.random)
                }
                Picker("Default Capture Format", selection: $captureFormat) {
                    ForEach(CaptureFormatOption.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                }
                .onChange(of: captureFormat) {
                    if captureFormat == .processed { session.live = defaultLive }
                }
                Picker("Default Capture Resolution", selection: $resolution) {
                    ForEach(CaptureResolution.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                Picker("Default Live Photo", selection: $defaultLive) {
                    Text("Off").tag(false)
                    Text("On").tag(true)
                }
                .disabled(captureFormat == .raw)
                .onChange(of: defaultLive) { session.live = defaultLive }
                Toggle(isOn: Binding(get: { autoSave }, set: setAutoSave)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto Save Captures")
                        Text("Automatically save photos after capture.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(requestingPhotoAccess)
                Picker("Auto Save Format", selection: $autoSaveFormat) {
                    ForEach(CameraAutoSaveFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
            }

            HSpecSettingsSection(effectsPhoto: effectsPhoto)

            Section("More Apps") {
                Toggle(isOn: $discovery.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Discovery Pop-up")
                        Text("Occasionally show more projects after exporting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    MoreAppsView {
                        discovery.recordOpen()
                    }
                    .onAppear {
                        discovery.recordOpen()
                    }
                } label: {
                    SettingsRow(
                        title: "More Apps",
                        subtitle: "Explore more from 1234567890.dev"
                    )
                }

                if let discordURL = remoteContent.discordURL {
                    Button {
                        discovery.recordOpen()
                        openURL(discordURL)
                    } label: {
                        SettingsRow(
                            title: "Discord",
                            subtitle: "Join the community",
                            showsExternalLinkIndicator: true
                        )
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                }
            }

            Section("About") {
                HStack(spacing: 14) {
                    if let icon = UIImage.hibiscusAppIcon {
                        Image(uiImage: icon).resizable().scaledToFit()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hibiscus Film").font(.headline)
                        Text(verbatim: "Film. Print. Repeat.").foregroundStyle(.secondary)
                        Text(versionText).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                externalRow("Hibiscus Film on GitHub", "Star the project or contribute.", HibiscusLinks.repository)
                externalRow("Original Hibiscus on GitHub", "iPhone camera and color grading.", HibiscusLinks.originalRepository)
                externalRow("Open Chroma Index", "Support open digital color.", HibiscusLinks.openChromaIndex)
                externalRow("Privacy", "View Privacy Policy", HibiscusLinks.privacy)
                externalRow("Terms of Service", "View Terms of Service", HibiscusLinks.terms)
                NavigationLink {
                    LegalNoticeScreen()
                } label: {
                    SettingsRow(title: "Legal Notice", subtitle: "Trademarks, acknowledgements, and licenses")
                }
            }
        }
        .task { remoteContent.refreshInBackground() }
        .sheet(isPresented: $showingSupport) { SupportHibiscus() }
        .sheet(isPresented: $showingSupporterPack) { SupporterPackPaywall(photo: effectsPhoto) }
        .onAppear { refreshPhotoPermission() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { refreshPhotoPermission() }
        }
        .alert("Allow saving to Photos", isPresented: $showPhotoPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Hibiscus Film to add photos in Settings, then turn on automatic saving.")
        }
        .navigationTitle(languageManager.string("Settings"))
        .navigationBarTitleDisplayMode(.large)
        .tint(Color.accentColor)
        .preferredColorScheme(.dark)
    }

    private func externalRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ url: URL) -> some View {
        Link(destination: url) {
            SettingsRow(title: title, subtitle: subtitle, showsExternalLinkIndicator: true)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private func setAutoSave(_ enabled: Bool) {
        guard enabled else {
            autoSave = false
            return
        }
        requestingPhotoAccess = true
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            autoSave = status == .authorized || status == .limited
            requestingPhotoAccess = false
            showPhotoPermissionAlert = !autoSave
        }
    }

    private func refreshPhotoPermission() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .denied || status == .restricted { autoSave = false }
    }

    private var versionText: LocalizedStringKey {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (\(build))"
    }
}

private struct LegalNoticeScreen: View {
    var body: some View {
        Form {
            Section("Trademarks") {
                Text("Hibiscus Film uses manufacturer and film stock names only to identify the photographic materials each profile models. All trademarks belong to their respective owners. These references do not imply affiliation with, sponsorship by, or endorsement from the manufacturers.")
            }
            Section("Acknowledgements") {
                Text("Fotufilm by MUAStudio Inc. provides the film simulation engine and stock profiles. Halide powers the engine’s image processing.")
                Text("Film Frame draws inspiration from SpektraLab’s Film Edge.")
            }
            Section("Licenses and source notices") {
                document("Mozilla Public License 2.0", Bundle.main.url(forResource: "MPL-2.0", withExtension: "txt"))
                document("Fotufilm Engine", "EngineNotices/NOTICE")
                document("Apache License 2.0", "EngineNotices/LICENSE")
                document("Film profile credits and adaptations", "Fotufilm/NOTICE.md")
                document("Additional film profile sources", "Fotufilm/native-additions.json")
                document("Creative Commons BY-SA 4.0", "Fotufilm/LICENSE.txt")
                document("Halide license and notices", "EngineNotices/HALIDE-LICENSE.txt")
                document("Fotufilm contributors and datasets", "EngineNotices/THIRD_PARTY_NOTICES.md")
                document("Source and adaptation credits", "SpectrumNotices/ADOPTION.md")
                document("Inter font license", FilmFrame.fontResources?.appendingPathComponent("Inter-OFL.txt"))
                document("JetBrains Mono font license", FilmFrame.fontResources?.appendingPathComponent("JetBrainsMono-OFL.txt"))
            }
        }
        .navigationTitle("Legal Notice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func document(_ title: LocalizedStringKey, _ path: String) -> some View {
        document(title, FilmProfileFiles.bundle.appendingPathComponent(path))
    }

    private func document(_ title: LocalizedStringKey, _ url: URL?) -> some View {
        NavigationLink(title) {
            ScrollView {
                Text(verbatim: url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? LanguageManager.text("This notice could not be opened."))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
