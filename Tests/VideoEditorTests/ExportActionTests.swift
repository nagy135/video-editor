import AppKit
import AVFoundation
import Foundation
import Testing
@testable import VideoEditor

@MainActor
struct ExportActionTests {
    @Test func quickExportPreservesOriginalAndExistingExportsAfterClosing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clip.mp4")
        let existing = directory.appendingPathComponent("clip-edited.mp4")
        let render = directory.appendingPathComponent("render.mp4")
        try Data("original".utf8).write(to: source)
        try Data("previous export".utf8).write(to: existing)
        try Data("new export".utf8).write(to: render)
        let model = VideoEditorModel(url: source)
        model.renderedURL = render

        let exported = try await model.exportVideo()
        model.close()

        #expect(exported.lastPathComponent == "clip-edited-2.mp4")
        #expect(try Data(contentsOf: exported) == Data("new export".utf8))
        #expect(try Data(contentsOf: source) == Data("original".utf8))
        #expect(try Data(contentsOf: existing) == Data("previous export".utf8))
        #expect(!FileManager.default.fileExists(atPath: render.path))
    }

    @Test func clipboardContainsAFileThatSurvivesEditorClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let render = directory.appendingPathComponent("render.mp4")
        let contents = Data("rendered video".utf8)
        try contents.write(to: render)
        let model = VideoEditorModel(url: directory.appendingPathComponent("clip.mp4"))
        model.renderedURL = render
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(await model.copyExport(to: pasteboard))
        model.close()

        let files = try #require(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])
        let exported = try #require(files.first)
        #expect(exported.lastPathComponent == "clip-edited.mp4")
        #expect(try Data(contentsOf: exported) == contents)
    }

    @Test func failedExportLeavesClipboardUntouchedAndReportsError() async {
        let model = VideoEditorModel(url: URL(fileURLWithPath: "/missing/clip.mp4"))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); model.close() }
        pasteboard.setString("keep me", forType: .string)

        #expect(await !model.copyExport(to: pasteboard))
        #expect(model.error != nil)
        #expect(pasteboard.string(forType: .string) == "keep me")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"] != nil))
    func exportIsAvailableBeforeAnyRenderAndUsesLatestEdit() async throws {
        let input = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIDEO_EDITOR_TEST_FIXTURE"]!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clip.mp4")
        try FileManager.default.copyItem(at: input, to: source)
        let model = VideoEditorModel(url: source)
        defer { model.close() }
        await model.load()
        model.edit.start = 1
        model.edit.end = 3
        model.changed()
        #expect(model.canExport)
        #expect(model.renderedURL == nil)
        #expect(model.sizeText.hasPrefix("≈ "))
        let exported = try await model.exportVideo()
        let duration = try await AVURLAsset(url: exported).load(.duration).seconds
        #expect(abs(duration - 2) < 0.06)
        #expect(!model.saving)
        #expect(model.renderedURL != nil)
    }

}
