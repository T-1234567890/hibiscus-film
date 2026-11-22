import Photos
import SwiftUI

nonisolated final class PhotoExportFile: Identifiable, Sendable {
    let url: URL
    private init(url: URL) { self.url = url }

    static func temporary(filename: String) throws -> PhotoExportFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PhotoExportFile(url: directory.appendingPathComponent(filename))
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct PhotoShareSheet: UIViewControllerRepresentable {
    var file: PhotoExportFile? = nil
    var livePhoto: PHLivePhoto? = nil
    let onCompletion: @MainActor (Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any] = livePhoto.map { [$0] } ?? file.map { [$0.url] } ?? []
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            Task { @MainActor in onCompletion(completed, error) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
