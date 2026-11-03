import AVFoundation

/// Peak envelope in source time, decoded off the UI thread with bounded memory.
public struct AudioWaveform: Sendable {
    public let peaks: [Float]
    public let interval: Double

    public static func load(url: URL) async throws -> AudioWaveform? {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else { return nil }
        let interval = max(0.01, duration / 600_000)
        var peaks = [Float](repeating: 0, count: Int(ceil(duration / interval)))
        for track in tracks {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 8_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            defer { reader.cancelReading() }
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                var samples = [Float](repeating: 0, count: count)
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw CocoaError(.fileReadCorruptFile) }
                let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                guard start.isFinite else { continue }
                for (index, sample) in samples.enumerated() where sample.isFinite {
                    let bin = Int(floor((start + Double(index) / 8_000) / interval))
                    if peaks.indices.contains(bin) { peaks[bin] = max(peaks[bin], abs(sample)) }
                }
            }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        }
        let scale = max(0.05, peaks.max() ?? 1)
        return AudioWaveform(peaks: peaks.map { min(1, $0 / scale) }, interval: interval)
    }
}
