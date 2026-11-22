import AVFoundation

nonisolated enum LivePhotoTiming {
    private static let stillImageTime = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")

    static func read(in asset: AVAsset) async throws -> CMTime? {
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.contains(where: { description in
                let keys = CMMetadataFormatDescriptionGetIdentifiers(description) as? [String] ?? []
                return keys.contains(stillImageTime.rawValue)
            }) else { continue }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let metadata = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            defer { reader.cancelReading() }
            while let group = metadata.nextTimedMetadataGroup() {
                if group.items.contains(where: { $0.identifier == stillImageTime }) {
                    return group.timeRange.start
                }
            }
        }
        return nil
    }

    /// Write a new timing-only track. A source track may also contain transforms
    /// for the untouched still, which do not describe a newly cropped image.
    static func write(at time: CMTime, duration: CMTime, to url: URL) async throws {
        guard time.isNumeric, duration.isNumeric, duration > .zero else { throw CocoaError(.coderInvalidValue) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let dataType = kCMMetadataBaseDataType_SInt8 as String
        let spec = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: stillImageTime.rawValue,
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: dataType]
        var description: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw CocoaError(.coderInvalidValue) }

        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        guard writer.canAdd(input) else { throw CocoaError(.coderInvalidValue) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let item = AVMutableMetadataItem()
        item.identifier = stillImageTime
        item.value = 0 as NSNumber
        item.dataType = dataType
        let markerDuration = min(CMTime(value: 1, timescale: 30), duration)
        let markerTime = min(max(.zero, time), duration - markerDuration)
        let group = AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: markerTime, duration: markerDuration))
        guard input.isReadyForMoreMediaData, adaptor.append(group) else {
            writer.cancelWriting()
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Pair one developed video and one audio stream with a clean still marker.
    /// Video remains compressed during this pass.
    static func pair(source: URL, rendered: URL, to destination: URL, identifier: String,
                     fallbackTime: CMTime? = nil) async throws {
        let original = AVURLAsset(url: source)
        let developed = AVURLAsset(url: rendered)
        guard let video = try await developed.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let videoRange = try await video.load(.timeRange)
        let recordedTime = try? await read(in: original)
        guard let displayTime = recordedTime ?? fallbackTime, displayTime.isNumeric else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let timingURL = destination.deletingPathExtension().appendingPathExtension("timing.mov")
        defer { try? FileManager.default.removeItem(at: timingURL) }
        try await write(at: displayTime - videoRange.start, duration: videoRange.duration, to: timingURL)
        let timingAsset = AVURLAsset(url: timingURL)
        guard let timing = try await timingAsset.loadTracks(withMediaType: .metadata).first else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let marker = composition.addMutableTrack(withMediaType: .metadata, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.coderInvalidValue) }
        try picture.insertTimeRange(videoRange, of: video, at: .zero)
        picture.preferredTransform = try await video.load(.preferredTransform)
        let timingRange = try await timing.load(.timeRange)
        try marker.insertTimeRange(timingRange, of: timing, at: timingRange.start)
        if let audio = try await developed.loadTracks(withMediaType: .audio).first {
            let range = CMTimeRangeGetIntersection(try await audio.load(.timeRange), otherRange: videoRange)
            if range.isValid, !range.isEmpty,
               let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try sound.insertTimeRange(range, of: audio, at: range.start - videoRange.start)
            }
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = identifier as NSString
        export.metadata = [item]
        try await export.export(to: destination, as: .mov)
    }
}
