import Foundation
import AVFoundation
import Testing
@testable import VideoEditorCore

@Test func trimAndConstantSpeedHaveExpectedDuration() {
    var edit = VideoEdit(duration: 20)
    edit.start = 2
    edit.end = 17
    #expect(abs(edit.outputDuration - 15) < 0.00001)
    edit.points = [SpeedPoint(time: 5, speed: 10)]
    #expect(abs(edit.outputDuration - 1.5) < 0.00001)
    #expect(edit.segments.first?.start == 2)
    #expect(abs(edit.segments.last!.start + edit.segments.last!.duration - 17) < 0.00001)
}

@Test func speedCurveJoinsPointsSmoothlyWithoutOvershooting() {
    var edit = VideoEdit(duration: 10)
    edit.points = [SpeedPoint(time: 2, speed: 1), SpeedPoint(time: 8, speed: 10)]
    #expect(edit.speed(at: 0) == 1)
    #expect(edit.speed(at: 10) == 10)
    #expect(edit.speed(at: 5) == 5.5)
    #expect(edit.speed(at: 2.0001) - 1 < 0.000001)
    #expect(10 - edit.speed(at: 7.9999) < 0.000001)
    for i in 0...1000 { #expect((1...10).contains(edit.speed(at: Double(i) / 100))) }
    #expect(edit.outputDuration > 1 && edit.outputDuration < 10)
    #expect(SpeedPoint(time: 0, speed: 100).speed == 10)
    #expect(SpeedPoint(time: 0, speed: 0).speed == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"] != nil))
@MainActor func realVideoAndAudioExportMatchesDuration() async throws {
    let input = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"]!)
    let original = try Data(contentsOf: input)
    let sourceAudioCount = try await AVURLAsset(url: input).loadTracks(withMediaType: .audio).count
    for mode in 0..<3 {
        var edit = VideoEdit(duration: 6)
        edit.start = 0.5
        edit.end = 5.5
        edit.points = mode == 2
            ? [SpeedPoint(time: 0.5, speed: 1), SpeedPoint(time: 2, speed: 10), SpeedPoint(time: 4, speed: 1)]
            : (mode == 1 ? [SpeedPoint(time: 0, speed: 10)] : [])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("editor-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await VideoEditorMedia.export(url: input, edit: edit, to: output) { _ in }
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - edit.outputDuration) < 0.06)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == sourceAudioCount)
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: duration / 2, preferredTimescale: 600))
        #expect(frame.image.width == 640)
        #expect(try Data(contentsOf: output).count > 1000)
    }
    #expect(try Data(contentsOf: input) == original)
}
