import AVFoundation
import Foundation
import Testing
import VideoEditorCore
@testable import VideoEditor

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"] != nil))
@MainActor
struct PlaybackTests {
    @MainActor private final class JumpCounter { var count = 0 }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(predicate())
    }

    @Test func playbackCrossesSplitsAndFractionalTrimmedGaps() async throws {
        let model = VideoEditorModel(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"]!))
        defer { model.close() }
        await model.load()
        model.edit.cuts = [VideoCut(start: 1, end: 1),
                           VideoCut(start: 2, end: 3.123456789),
                           VideoCut(start: 4, end: 4)]
        model.togglePlayback()
        try await waitUntil { model.player.currentTime().seconds > 0.25 && model.player.rate > 0 }
        #expect(model.player.currentItem?.asset is AVComposition)
        let jumps = JumpCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: model.player.currentItem, queue: .main
        ) { _ in
            Task { @MainActor in jumps.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // Cross an untouched seam, a gap whose end is not on the seek time grid,
        // and another seam. Playback must still be active after the final split.
        try await waitUntil { model.position > 4.2 }
        #expect(model.playing)
        #expect(model.player.rate > 0)
        #expect(jumps.count == 0)
        #expect(model.player.currentTime().seconds < model.position - 1)
        try await waitUntil { !model.playing }
        #expect(abs(model.position - model.edit.end) < 0.001)
    }

    @Test func editCancelsPendingPlaybackAndNextPlayUsesNewCuts() async throws {
        let model = VideoEditorModel(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"]!))
        defer { model.close() }
        await model.load()
        model.playFromStart()
        model.edit.cuts = [VideoCut(start: 2, end: 3)]
        model.changed()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.playing)
        #expect(model.player.rate == 0)
        model.playFromStart()
        try await waitUntil { model.player.rate > 0 }
        #expect(abs(model.player.currentItem!.duration.seconds - 5) < 0.001)
    }

    @Test func playFromStartRestartsAtFirstRetainedFrameAndPauseStaysPaused() async throws {
        let model = VideoEditorModel(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"]!))
        defer { model.close() }
        await model.load()
        model.edit.cuts = [VideoCut(start: 0, end: 0.8123456789)]
        model.seek(4)
        try await waitUntil { model.player.currentTime().seconds >= 4 }
        model.playFromStart()
        try await waitUntil {
            model.position >= 0.8123456789
                && model.player.currentTime().seconds < 1 && model.player.rate > 0
        }
        #expect(model.playing)
        model.pause()
        model.seek(3)
        try await waitUntil { abs(model.player.currentTime().seconds - 3) < 0.01 }
        #expect(!model.playing)
        #expect(model.player.rate == 0)
    }
}
