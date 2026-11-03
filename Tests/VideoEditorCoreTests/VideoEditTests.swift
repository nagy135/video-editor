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
    for mode in 0..<4 {
        var edit = VideoEdit(duration: 6)
        edit.start = 0.5
        edit.end = 5.5
        edit.points = mode >= 2
            ? [SpeedPoint(time: 0.5, speed: 1), SpeedPoint(time: 2, speed: 10), SpeedPoint(time: 4, speed: 1)]
            : (mode == 1 ? [SpeedPoint(time: 0, speed: 10)] : [])
        if mode == 3 {
            edit.cuts = [VideoCut(start: 0, end: 1), VideoCut(start: 2, end: 3),
                         VideoCut(start: 2.5, end: 4), VideoCut(start: 5, end: 6)]
        }
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

@Test func overlappingCutsRemoveTheirUnionAndUndoIndividually() {
    var edit = VideoEdit(duration: 10)
    let first = VideoCut(start: 2, end: 5)
    let second = VideoCut(start: 4, end: 7)
    edit.cuts = [first, second]
    #expect(edit.retainedRanges == [0..<2, 7..<10])
    #expect(abs(edit.outputDuration - 5) < 0.00001)
    #expect(edit.segments.count == 2)
    #expect(edit.segments.last?.start == 7)
    #expect(edit.nextPlayableTime(at: 3) == 7)
    #expect(edit.nextPlayableTime(at: 8) == 8)
    #expect(edit.nextPlayableTime(at: 10) == nil)
    edit.cuts.removeAll { $0.id == first.id }
    #expect(edit.retainedRanges == [0..<4, 7..<10])
    #expect(abs(edit.outputDuration - 7) < 0.00001)
    edit.cuts.removeAll()
    #expect(abs(edit.outputDuration - 10) < 0.00001)
}

@Test func cutsRespectTrimAndSpeedAndAllowEmptyOutput() {
    var edit = VideoEdit(duration: 20)
    edit.start = 3
    edit.end = 17
    edit.points = [SpeedPoint(time: 0, speed: 2)]
    edit.cuts = [VideoCut(start: 0, end: 5), VideoCut(start: 10, end: 20)]
    #expect(edit.retainedRanges == [5..<10])
    #expect(abs(edit.outputDuration - 2.5) < 0.00001)
    edit.cuts.append(VideoCut(start: 4, end: 12))
    #expect(edit.segments.isEmpty)
    #expect(edit.outputDuration == 0)
    #expect(edit.nextPlayableTime(at: 0) == nil)
}

@Test func splitStartsWithoutRemovingFramesAndTrimsAwayOnBothSides() {
    var edit = VideoEdit(duration: 10)
    edit.cuts = [VideoCut(start: 5, end: 5)]
    #expect(edit.retainedRanges == [0..<5, 5..<10])
    #expect(abs(edit.outputDuration - 10) < 0.00001)
    edit.cuts[0].trimLeft(to: 3, duration: 10)
    edit.cuts[0].trimRight(to: 7, duration: 10)
    #expect(edit.retainedRanges == [0..<3, 7..<10])
    #expect(abs(edit.outputDuration - 6) < 0.00001)
    edit.cuts[0].trimLeft(to: 8, duration: 10)
    edit.cuts[0].trimRight(to: 2, duration: 10)
    #expect(edit.cuts[0].start == 5)
    #expect(edit.cuts[0].end == 5)
    #expect(abs(edit.outputDuration - 10) < 0.00001)
    edit.cuts[0].trimLeft(to: -4, duration: 10)
    edit.cuts[0].trimRight(to: 20, duration: 10)
    #expect(edit.retainedRanges.isEmpty)
}

@Test func continuousPreviewMapsJoinsBackToSourceTime() {
    var edit = VideoEdit(duration: 10)
    edit.start = 1
    edit.end = 9
    edit.cuts = [VideoCut(start: 2, end: 2), VideoCut(start: 3, end: 5),
                 VideoCut(start: 4, end: 6), VideoCut(start: 8, end: 10)]
    #expect(edit.playbackTime(atSourceTime: 1) == 0)
    #expect(edit.playbackTime(atSourceTime: 2) == 1)
    #expect(edit.playbackTime(atSourceTime: 4) == 2)
    #expect(edit.playbackTime(atSourceTime: 6) == 2)
    #expect(edit.sourceTime(atPlaybackTime: 2) == 6)
    #expect(edit.sourceTime(atPlaybackTime: 3) == 7)
    #expect(edit.sourceTime(atPlaybackTime: 4) == 8)
    for time in [1.0, 2.0, 2.5, 6.0, 7.5] {
        #expect(abs(edit.sourceTime(atPlaybackTime: edit.playbackTime(atSourceTime: time)) - time) < 0.00001)
    }
}
