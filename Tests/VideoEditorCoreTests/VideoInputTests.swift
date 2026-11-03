import Foundation
import Testing
@testable import VideoEditorCore

@Test func pastedPathsKeepSpacesAndSupportFinderURLs() {
    let plain = VideoInput.paths(from: "  /tmp/a video.mp4\n'/tmp/second video.mov'\n\"/tmp/third.m4v\"  ")
    #expect(plain.map(\.path) == ["/tmp/a video.mp4", "/tmp/second video.mov", "/tmp/third.m4v"])
    #expect(VideoInput.paths(from: "file:///tmp/a%20video.mp4").first?.path == "/tmp/a video.mp4")
    #expect(VideoInput.paths(from: "~/Movies/clip.mp4").first?.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/clip.mp4").path)
    #expect(VideoInput.paths(from: "https://example.com/video.mp4\nrandom clipboard text").isEmpty)
}

@Test func videoImportRejectsMissingFilesFoldersAndNonVideoFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("clip.mp4")
    let text = directory.appendingPathComponent("notes.txt")
    let folder = directory.appendingPathComponent("folder.mp4")
    try Data().write(to: video)
    try Data().write(to: text)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    #expect(VideoInput.isVideo(video))
    #expect(!VideoInput.isVideo(text))
    #expect(!VideoInput.isVideo(folder))
    #expect(!VideoInput.isVideo(directory.appendingPathComponent("missing.mp4")))
    #expect(!VideoInput.isVideo(URL(string: "https://example.com/video.mp4")!))
}
