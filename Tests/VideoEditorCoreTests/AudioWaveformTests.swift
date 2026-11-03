import Foundation
import AVFoundation
import Testing
@testable import VideoEditorCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"] != nil))
func waveformPreservesSourceTimeAndHandlesMissingAudio() async throws {
    let input = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"]!)
    let waveform = try await AudioWaveform.load(url: input)
    if input.lastPathComponent == "silent.mp4" {
        #expect(waveform == nil)
    } else {
        let waveform = try #require(waveform)
        let duration = try await AVURLAsset(url: input).load(.duration).seconds
        #expect(abs(Double(waveform.peaks.count) * waveform.interval - duration) <= waveform.interval)
        #expect(waveform.peaks.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        #expect(waveform.peaks.max() == 1)
        if input.lastPathComponent == "delayed-audio.mp4" {
            #expect(waveform.peaks.prefix(50).allSatisfy { $0 == 0 })
            #expect(waveform.peaks[100..<200].contains { $0 > 0.5 })
        }
    }
}
