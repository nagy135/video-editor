import AppKit
import Testing
import VideoEditorCore
@testable import VideoEditor

@MainActor
struct OutputVolumeTests {
    @Test func volumeAndMuteApplyLiveAndShareUndoHistory() {
        let model = VideoEditorModel(url: URL(fileURLWithPath: "/missing/clip.mp4"))
        defer { model.close() }
        model.loading = false
        model.edit = VideoEdit(duration: 12)
        model.playing = true
        model.setOutputVolume(0.4)
        #expect(model.playing)
        #expect(model.player.volume == 0.4)
        model.toggleOutputMute()
        #expect(model.edit.audioMuted)
        #expect(model.player.volume == 0)
        model.toggleOutputMute()
        #expect(!model.edit.audioMuted)
        #expect(model.player.volume == 0.4)
        model.undoEdit()
        #expect(model.player.volume == 0)
        model.undoEdit()
        #expect(model.player.volume == 0.4)
        model.undoEdit()
        #expect(model.player.volume == 0)
        #expect(model.edit.audioMuted)
        #expect(!model.canUndo)
    }

    @Test func sliderGestureCoalescesAndSpeakerButtonRestoresZeroVolume() throws {
        _ = NSApplication.shared
        let model = VideoEditorModel(url: URL(fileURLWithPath: "/missing/clip.mp4"))
        defer { model.close() }
        model.loading = false
        model.edit = VideoEdit(duration: 12)
        model.beginEdit()
        for volume in [0.8, 0.5, 0.2, 0] { model.setOutputVolume(volume, continuous: true) }
        model.endEdit(pausePlayback: false)
        let view = VideoTimelineView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 136)
        view.refreshViewport()
        let slider = try #require(view.subviews.flatMap(\.subviews).compactMap { $0 as? NSSlider }.first)
        let button = try #require(view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.toolTip == "Unmute output audio" })
        #expect(slider.isHidden)
        #expect(slider.doubleValue == 0)
        button.performClick(nil)
        #expect(model.player.volume == 1)
        model.undoEdit()
        #expect(model.player.volume == 0)
        model.undoEdit()
        #expect(model.player.volume == 0)
        #expect(model.edit.audioMuted)
        #expect(!model.canUndo)
    }
    @Test func mutedDefaultAndHoverSliderDoNotReserveTimelineSpace() throws {
        _ = NSApplication.shared
        let model = VideoEditorModel(url: URL(fileURLWithPath: "/missing/clip.mp4"))
        defer { model.close() }
        model.loading = false
        model.edit = VideoEdit(duration: 12)
        #expect(model.edit.audioMuted)
        #expect(model.edit.effectiveAudioVolume == 0)
        let view = VideoTimelineView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 136)
        view.refreshViewport()
        let slider = try #require(view.subviews.flatMap(\.subviews).compactMap { $0 as? NSSlider }.first)
        let control = try #require(slider.superview)
        let button = try #require(control.subviews.compactMap { $0 as? NSButton }.first)
        let scroller = try #require(view.subviews.compactMap { $0 as? NSScroller }.first)
        let timelineFrame = scroller.frame
        #expect(timelineFrame.minX == 38)
        #expect(control.frame.maxX < timelineFrame.minX)
        #expect(slider.isHidden)
        let hover = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        control.mouseEntered(with: hover)
        #expect(slider.isHidden)
        button.performClick(nil)
        #expect(!model.edit.audioMuted)
        #expect(!slider.isHidden)
        #expect(scroller.frame == timelineFrame)
        control.mouseExited(with: hover)
        #expect(slider.isHidden)
        #expect(control.frame.maxX < timelineFrame.minX)
        control.mouseEntered(with: hover)
        #expect(!slider.isHidden)
        button.performClick(nil)
        #expect(model.edit.audioMuted)
        #expect(slider.isHidden)
    }

}
