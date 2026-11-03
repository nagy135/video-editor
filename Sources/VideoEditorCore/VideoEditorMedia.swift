import AVFoundation

@MainActor
public enum VideoEditorMedia {
    public static func composition(url: URL, edit: VideoEdit) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        let tracks = try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio)
        let segments = edit.segments
        for source in tracks {
            try Task.checkCancellation()
            guard let target = composition.addMutableTrack(withMediaType: source.mediaType,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            if source.mediaType == .video { target.preferredTransform = try await source.load(.preferredTransform) }
            let available = try await source.load(.timeRange)
            var cursor = CMTime.zero
            for (index, segment) in segments.enumerated() {
                if index % 100 == 0 {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                let range = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 60000),
                                        duration: CMTime(seconds: segment.duration, preferredTimescale: 60000))
                let output = CMTime(seconds: segment.outputDuration, preferredTimescale: 60000)
                // ScreenCaptureKit audio can start late or end before the video.
                // Fill those gaps rather than failing or shifting audio in time.
                let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
                if intersection == range {
                    try target.insertTimeRange(range, of: source, at: cursor)
                } else {
                    target.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
                    if intersection.isValid && intersection.duration > .zero {
                        let insertion = cursor + intersection.start - range.start
                        target.removeTimeRange(CMTimeRange(start: insertion, duration: intersection.duration))
                        try target.insertTimeRange(intersection, of: source, at: insertion)
                    }
                }
                target.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: output)
                cursor = cursor + output
            }
        }
        return composition
    }

    public static func export(url: URL, edit: VideoEdit, to destination: URL,
                       sessionReady: (AVAssetExportSession) -> Void) async throws {
        let composition = try await composition(url: url, edit: edit)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let track = composition.tracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        // Retimed tracks can imply hundreds of frames per second. Render to a
        // fixed cadence so ramps remain encodable even at the 10× limit.
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]
        session.videoComposition = videoComposition
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: edit.outputDuration, preferredTimescale: 60000))
        session.audioTimePitchAlgorithm = .varispeed
        sessionReady(session)
        try Task.checkCancellation()
        try await session.export(to: destination, as: .mp4)
    }
}
