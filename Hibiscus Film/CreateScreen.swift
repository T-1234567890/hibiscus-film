import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct EffectPhoto: Hashable {
    let id = UUID()
    let data: Data
    let preview: UIImage
    var motion: PhotoExportFile?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func decode(_ data: Data, maxDimension: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return bitmap
    }

    static func isLivePhoto(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .livePhoto) }
    }

    @concurrent static func load(_ item: PhotosPickerItem, preservingMotion: Bool = false) async throws -> Self {
        if preservingMotion, isLivePhoto(item) {
            guard let livePhoto = try await item.loadTransferable(type: PHLivePhoto.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try await EffectLivePhoto.load(livePhoto)
        }
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        return try Self(data: data, preview: UIImage(cgImage: decode(data, maxDimension: 1600)))
    }
}

struct CreateScreen: View {
    var body: some View { EffectsScreen().toolbar(.hidden, for: .navigationBar) }
}

struct ChoosePhotoPrompt: View {
    var loading = false
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Choose a photo to start")
                .font(.title3.weight(.semibold))
            Button(action: choose) {
                if loading {
                    ProgressView().accessibilityLabel("Loading photo")
                } else {
                    Text("Choose Photo")
                }
            }
            .hibiscusGlassButtonStyle(tint: .white)
            .foregroundStyle(.black)
            .disabled(loading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
