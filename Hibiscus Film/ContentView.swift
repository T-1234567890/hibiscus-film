import SwiftUI

private enum FilmTab: Hashable { case camera, effects, settings }

struct ContentView: View {
    @EnvironmentObject private var languageManager: LanguageManager
    @State private var camera: CameraService?
    @State private var cameraPreparationFailed = false
    @State private var cameraAttempt = 0
    @State private var navigationShutter: CGRect?
    @State private var tab = FilmTab.camera
    @State private var effectsPhoto: CGImage?
    @State private var session = FilmSession()
    @StateObject private var remoteContent = RemoteContentManager()
    @StateObject private var discovery = DiscoveryPreferences()
    var body: some View {
        GeometryReader { space in
            TabView(selection: $tab) {
                Tab(languageManager.string("Camera"), systemImage: "camera", value: FilmTab.camera) {
                    if let camera {
                        CameraScreen(camera: camera, isActive: tab == .camera, navigationSize: space.size,
                                     navigationShutter: $navigationShutter)
                    } else {
                        ZStack {
                            Color(white: 0.065).ignoresSafeArea()
                            if cameraPreparationFailed {
                                VStack(spacing: 12) {
                                    Text("Camera preview unavailable")
                                    Button("Try Again") { cameraAttempt += 1 }
                                }
                            } else {
                                ProgressView("Preparing camera…")
                            }
                        }
                    }
                }
                Tab(languageManager.string("Effects"), systemImage: "square.stack.3d.up", value: FilmTab.effects) {
                    NavigationStack { CreateScreen(previewPhoto: $effectsPhoto) }
                }
                Tab(languageManager.string("Settings"), systemImage: "gearshape", value: FilmTab.settings) {
                    NavigationStack { SettingsScreen(effectsPhoto: effectsPhoto) }
                }
            }
            .overlay(alignment: .topLeading) {
                if tab == .camera, let camera, let frame = navigationShutter {
                    CameraShutterButton(camera: camera, diameter: frame.width)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: navigationShutter != nil)
            .frame(width: space.size.width, height: space.size.height)
        }
        .coordinateSpace(name: CameraWorkspace.navigationSpace)
        .onChange(of: tab) { previous, selected in
            if previous == .camera && selected != .camera { camera?.dismissCapturePreview() }
        }
        .task(id: cameraAttempt) {
            guard camera == nil else { return }
            cameraPreparationFailed = false
            let prepared = await CameraService.prepare()
            guard !Task.isCancelled else { return }
            camera = prepared
            cameraPreparationFailed = prepared == nil
        }
        .accessibilityHidden(discovery.isPresented)
        .overlay {
            if discovery.isPresented {
                PostExportDiscoveryView(onClose: {
                    discovery.isPresented = false
                    discovery.didDismiss()
                }, onOpenEcosystemLink: discovery.recordOpen)
            }
        }
        .environmentObject(remoteContent)
        .environmentObject(discovery)
        .environment(session)
        .preferredColorScheme(.dark)
    }
}
