import AppKit
import Testing
import VideoEditorCore
@testable import VideoEditor

@MainActor
struct SegmentEditingTests {
    private func model() -> VideoEditorModel {
        let model = VideoEditorModel(url: URL(fileURLWithPath: "/missing/clip.mp4"))
        model.edit = VideoEdit(duration: 12)
        model.loading = false
        return model
    }

    @Test func deletionAndSplitsShareChronologicalUndoAndRestoreSelection() {
        let model = model()
        defer { model.close() }
        model.position = 4
        model.addCut()
        model.position = 8
        model.addCut()
        let splitEdit = model.edit
        model.selectSegment(at: 6)
        #expect(model.selectedSegment == 4..<8)
        model.deleteSelectedSegment()
        #expect(model.edit.retainedRanges == [0..<4, 8..<12])
        #expect(model.selectedSegment == nil)
        #expect(!model.canDeleteSegment)
        model.undoEdit()
        #expect(model.edit == splitEdit)
        #expect(model.selectedSegment == 4..<8)
        model.undoEdit()
        #expect(model.edit.retainedRanges == [0..<4, 4..<12])
        model.undoEdit()
        #expect(model.edit.retainedRanges == [0..<12])
        #expect(!model.canUndo)
    }

    @Test func draggingCoalescesAndScrubbingDoesNotConsumeUndo() {
        let model = model()
        defer { model.close() }
        model.position = 6
        model.addCut()
        let splitEdit = model.edit
        model.beginEdit()
        for time in [5.5, 5, 4.5, 4] {
            model.edit.cuts[0].trimLeft(to: time, duration: model.edit.duration)
            model.updateDuration()
        }
        model.endEdit()
        model.beginEdit()
        model.selectSegment(at: 9)
        model.endEdit()
        model.undoEdit()
        #expect(model.edit == splitEdit)
        model.undoEdit()
        #expect(model.edit.cuts.isEmpty)
        #expect(!model.canUndo)
    }

    @Test func deleteWholeClipAndResetAndSpeedChangesCanBeUndone() {
        let model = model()
        defer { model.close() }
        model.beginEdit()
        model.edit.points = [SpeedPoint(time: 0, speed: 2)]
        model.endEdit()
        let speedEdit = model.edit
        model.selectSegment(at: 5)
        model.deleteSelectedSegment()
        #expect(model.edit.retainedRanges.isEmpty)
        #expect(!model.canExport)
        model.resetEdits()
        #expect(model.edit == VideoEdit(duration: 12))
        model.undoEdit()
        #expect(model.edit.retainedRanges.isEmpty)
        model.undoEdit()
        #expect(model.edit == speedEdit)
        #expect(model.selectedSegment == 0..<12)
        model.undoEdit()
        #expect(model.edit.points.isEmpty)
    }

    @Test func deletedGapsAndOutsideTrimDoNotSelectOrSplit() {
        let model = model()
        defer { model.close() }
        model.edit.start = 1
        model.edit.end = 11
        model.edit.cuts = [VideoCut(start: 4, end: 8)]
        for time in [0.0, 6, 12] {
            model.selectSegment(at: time)
            #expect(!model.canDeleteSegment)
            model.deleteSelectedSegment()
            model.position = time
            model.addCut()
        }
        #expect(model.edit.cuts.count == 1)
        #expect(!model.canUndo)
    }

    @Test func filmstripClickFocusesSegmentAndXAndDUndoWorkWithSpeedCurveFoldedOrOpen() throws {
        let model = model()
        defer { model.close() }
        model.position = 6
        model.addCut()
        let view = VideoTimelineView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 260)
        #expect(!model.showSpeedCurve)
        for expanded in [false, true] {
            model.showSpeedCurve = expanded
            let location = view.convert(NSPoint(x: 38 + 946 * 0.75, y: expanded ? 210 : 86), to: nil)
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: click)
            view.mouseUp(with: click)
            #expect(model.selectedSegment == 6..<12)
            let beforeAudioClick = model.edit
            let audioLocation = view.convert(NSPoint(x: 38 + 946 * 0.75, y: expanded ? 160 : 36), to: nil)
            let audioClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: audioLocation,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: audioClick)
            view.mouseUp(with: audioClick)
            #expect(model.edit == beforeAudioClick)
            #expect(model.position == 9)
            #expect(model.selectedSegment == 6..<12)
            for key in ["x", "d"] {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                    isARepeat: false, keyCode: 0))
                view.keyDown(with: event)
                #expect(model.edit.retainedRanges == [0..<6])
                model.undoEdit()
                #expect(model.selectedSegment == 6..<12)
            }
        }
    }
    @Test func partiallyFoldedPanelKeepsAudioAndFilmstripHitRegionsAligned() throws {
        let model = model()
        defer { model.close() }
        model.showSpeedCurve = true
        let view = VideoTimelineView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 198)
        view.setCurveExpansion(0.5)
        for y in [98.0, 148] {
            let location = view.convert(NSPoint(x: 38 + 946 * 0.75, y: y), to: nil)
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: click)
            view.mouseUp(with: click)
            #expect(model.position == 9)
            #expect(model.selectedSegment == 0..<12)
            #expect(model.edit.points.isEmpty)
            #expect(!model.canUndo)
        }
    }

    @Test func draggingGapDoesNotMoveCutOrCreateUndoStep() throws {
        let model = model()
        defer { model.close() }
        model.edit.cuts = [VideoCut(start: 4, end: 8)]
        let before = model.edit
        let view = VideoTimelineView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 136)
        func event(_ type: NSEvent.EventType, time: Double) throws -> NSEvent {
            let location = view.convert(NSPoint(x: 38 + 946 * time / 12, y: 86), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, time: 6))
        view.mouseDragged(with: try event(.leftMouseDragged, time: 9))
        view.mouseUp(with: try event(.leftMouseUp, time: 9))
        #expect(model.edit == before)
        #expect(!model.canUndo)
        #expect(model.selectedCut == model.edit.cuts[0].id)
    }

    @Test func joinGapRestoresOverlappingRemovedFootageAndMergesSeamsWithUndo() {
        let model = model()
        defer { model.close() }
        let unrelated = VideoCut(start: 10, end: 10)
        let gap = VideoCut(start: 4, end: 7)
        model.edit.cuts = [VideoCut(start: 4, end: 4), gap,
                           VideoCut(start: 6, end: 8), VideoCut(start: 8, end: 8), unrelated]
        let before = model.edit
        model.joinGap(gap.id)
        #expect(model.edit.cuts == [unrelated])
        #expect(model.edit.retainedRanges == [0..<10, 10..<12])
        #expect(model.selectedSegment == 0..<10)
        #expect(abs(model.outputDuration - 12) < 0.001)
        model.undoEdit()
        #expect(model.edit == before)
    }

    @Test func oneGapButtonRestoresFootageAndJoinsSurroundingSegments() throws {
        _ = NSApplication.shared
        let model = model()
        defer { model.close() }
        let gap = VideoCut(start: 4, end: 8)
        model.edit.cuts = [gap]
        model.selectedCut = gap.id
        let view = VideoTimelineView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 136)
        view.refreshViewport()
        let buttons = view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.toolTip?.contains("join surrounding") == true }
        #expect(buttons.count == 1)
        let button = try #require(buttons.first)
        button.performClick(nil)
        #expect(model.edit.retainedRanges == [0..<12])
        #expect(model.selectedSegment == 0..<12)
        #expect(button.isHidden)
        model.undoEdit()
        #expect(model.edit.cuts == [gap])
    }

    @Test func splitFocusesOnlyRightSegmentAndDraggingFocusesOnlyItsNeighbor() throws {
        let model = model()
        defer { model.close() }
        model.position = 6
        model.addCut()
        #expect(model.selectedSegment == 6..<12)
        #expect(model.selectedCut == nil)
        let view = VideoTimelineView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 136)
        let location = view.convert(NSPoint(x: 38 + 946 * 0.5 - 5, y: 86), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        view.mouseUp(with: click)
        #expect(model.selectedSegment == 0..<6)
        #expect(model.selectedCut == nil)
        model.undoEdit()
        #expect(model.edit.cuts.isEmpty)
    }

    @Test func restoringDeletedSegmentBorderDoesNotResurrectCoveredSplitSeams() throws {
        for left in [false, true] {
            let model = model()
            defer { model.close() }
            model.edit.cuts = [VideoCut(start: 4, end: 4), VideoCut(start: 8, end: 8), VideoCut(start: 4, end: 8)]
            let before = model.edit
            let view = VideoTimelineView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 136)
            func event(_ type: NSEvent.EventType, at time: Double) throws -> NSEvent {
                let location = view.convert(NSPoint(x: 38 + 946 * time / 12 + (left ? -5 : 5), y: 86), to: nil)
                return try #require(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            view.mouseDown(with: try event(.leftMouseDown, at: left ? 4 : 8))
            // Clicking without moving must not normalize or add an undo step.
            view.mouseUp(with: try event(.leftMouseUp, at: left ? 4 : 8))
            #expect(model.edit == before)
            #expect(!model.canUndo)
            view.mouseDown(with: try event(.leftMouseDown, at: left ? 4 : 8))
            view.mouseDragged(with: try event(.leftMouseDragged, at: left ? 5 : 7))
            view.mouseUp(with: try event(.leftMouseUp, at: left ? 5 : 7))
            #expect(model.edit.cuts.count == 1)
            #expect(model.edit.retainedRanges.count == 2)
            let ranges = model.edit.retainedRanges
            #expect(abs(ranges[0].upperBound - (left ? 5 : 4)) < 0.000001)
            #expect(abs(ranges[1].lowerBound - (left ? 8 : 7)) < 0.000001)
            #expect(model.selectedSegment == (left ? ranges[0] : ranges[1]))
            #expect(model.selectedCut == nil)
            model.undoEdit()
            #expect(model.edit == before)
        }
    }

}
