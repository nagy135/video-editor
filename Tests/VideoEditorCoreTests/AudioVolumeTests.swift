import AVFoundation
import Foundation
import Testing
@testable import VideoEditorCore

extension MediaExportTests {
@Test(.enabled(if: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"] != nil))
@MainActor func outputVolumeIsAppliedAndMuteRemovesAudioTrack() async throws {
    let input = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"]!)
    let hasAudio = try await !AVURLAsset(url: input).loadTracks(withMediaType: .audio).isEmpty
    var levels: [Double] = []
    let configurations: [(Float, Bool)] = [(1, false), (0.25, false), (0, false), (1, true)]
    for (volume, muted) in configurations {
        var edit = VideoEdit(duration: 6)
        edit.start = 1
        edit.end = 3
        edit.audioVolume = volume
        edit.audioMuted = muted
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("volume-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await VideoEditorMedia.export(url: input, edit: edit, to: output) { _ in }
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.06)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if edit.effectiveAudioVolume == 0 || !hasAudio {
            #expect(tracks.isEmpty)
        } else {
            let track = try #require(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            let pcm = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(pcm)
            #expect(reader.startReading())
            var energy = 0.0
            var sampleCount = 0
            while let sample = pcm.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                var values = [Float](repeating: 0, count: count)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                #expect(status == kCMBlockBufferNoErr)
                energy += values.reduce(0.0) { $0 + Double($1) * Double($1) }
                sampleCount += count
            }
            #expect(reader.status == .completed)
            #expect(sampleCount > 0)
            levels.append(sqrt(energy / Double(max(1, sampleCount))))
        }
    }
    if hasAudio {
        #expect(levels[0] > 0.01)
        #expect(abs(levels[1] / levels[0] - 0.25) < 0.025)
    }
}

}
