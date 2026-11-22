// SPDX-License-Identifier: MPL-2.0
// Adapted from the Hibiscus iOS camera.
import Foundation
import Photos
import CoreLocation

/// Retains the original DNG until PhotoKit has completed every save attempt.
/// A rejected RAW/processed pair must not prevent saving the RAW itself.
nonisolated enum RAWPhotoLibrarySaver {
    enum SavedRepresentation: Sendable {
        case paired, separate, rawOnly
    }

    static func save(
        rawData: Data,
        companionFile: URL?,
        frameFile: URL?,
        date: Date?,
        location: CLLocation?,
        completion: @escaping @Sendable (Bool, SavedRepresentation, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Hibiscus-RAW-\(UUID().uuidString)", isDirectory: true)
            let file = directory.appendingPathComponent("Hibiscus.dng")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try rawData.write(to: file, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                completion(false, .rawOnly, diagnostic(error))
                return
            }

            @Sendable func finish(_ success: Bool, representation: SavedRepresentation, error: Error?) {
                try? FileManager.default.removeItem(at: directory)
                completion(success, representation, error.map(diagnostic))
            }

            @Sendable func saveRAWOnly() {
                saveAsset(file: file, companion: nil, frame: nil, date: date, location: location) { success, error in
                    finish(success, representation: .rawOnly, error: error)
                }
            }

            saveAsset(file: file, companion: companionFile, frame: frameFile, date: date, location: location) { success, error in
                if success || (companionFile == nil && frameFile == nil) {
                    let representation: SavedRepresentation = companionFile != nil ? .paired : frameFile != nil ? .separate : .rawOnly
                    finish(success, representation: representation, error: error)
                    return
                }
                guard let companionFile else {
                    saveRAWOnly()
                    return
                }
#if DEBUG
                if let error {
                    print("[Hibiscus Camera] RAW pair rejected: \(diagnostic(error)); retrying as separate assets")
                }
#endif
                // performChanges is transactional: a failed pair created no
                // asset, so retrying as separate originals cannot duplicate it.
                // Do not move/delete the file until this attempt also finishes.
                saveAsset(file: file, companion: companionFile, frame: frameFile, date: date, location: location,
                          separateCompanion: true) { success, error in
                    if success {
                        finish(true, representation: .separate, error: nil)
                        return
                    }
                    // Preserve the DNG if even an independent JPEG cannot be
                    // saved. Never report the missing processed photo as saved.
                    saveRAWOnly()
                }
            }
        }
    }

    private static func saveAsset(
        file: URL, companion: URL?, frame: URL?, date: Date?, location: CLLocation?,
        separateCompanion: Bool = false,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = date
            request.location = location
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            options.shouldMoveFile = false
            // Let PhotoKit identify the captured DNG from its file contents.
            request.addResource(with: .photo, fileURL: file, options: options)
            if let companion {
                if separateCompanion {
                    let processed = PHAssetCreationRequest.forAsset()
                    processed.creationDate = date
                    processed.location = location
                    processed.addResource(with: .photo, fileURL: companion, options: nil)
                } else {
                    request.addResource(with: .alternatePhoto, fileURL: companion, options: nil)
                }
            }
            if let frame {
                let framed = PHAssetCreationRequest.forAsset()
                framed.creationDate = date
                framed.location = location
                framed.addResource(with: .photo, fileURL: frame, options: nil)
            }
        } completionHandler: { success, error in
            completion(success, error)
        }
    }

    private static func diagnostic(_ error: Error) -> String {
        let error = error as NSError
        // A shareable diagnostic, without paths, coordinates, or photo metadata.
        return "\(error.domain) (\(error.code))"
    }
}
