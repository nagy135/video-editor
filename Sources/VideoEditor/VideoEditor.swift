import AppKit
import AVKit
import SwiftUI
import Combine
import VideoEditorCore

@MainActor
final class VideoEditor: NSWindowController, NSWindowDelegate {
    private let model: VideoEditorModel
    private let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        model = VideoEditorModel(url: url)
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Video Editor — \(url.lastPathComponent)"
        window.minSize = NSSize(width: 760, height: 650)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VideoEditorView(model: model))
        super.init(window: window)
        window.delegate = self
        window.center()
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.load() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func prepareForTermination() { model.close() }
    func windowWillClose(_ notification: Notification) { model.close(); onClose() }
}

@MainActor
final class VideoEditorModel: ObservableObject {
    let url: URL
    let player = AVPlayer()
    @Published var edit = VideoEdit(duration: 0)
    @Published var position = 0.0
    @Published var playing = false
    @Published var selected: UUID?
    @Published var zoomResetToken = 0
    @Published var viewportZoomed = false
    @Published var sizeText = "Calculating…"
    @Published var error: String?
    @Published var loading = true
    @Published var saving = false
    @Published var renderedURL: URL?
    @Published var thumbnails: [NSImage] = []
    private var renderTask: Task<Void, Never>?
    private var exportSession: AVAssetExportSession?
    private var observer: Any?
    private var generation = 0
    private var seeking = false
    private var pendingSeek: Double?
    private var closed = false
    private(set) var outputDuration = 0.0

    init(url: URL) { self.url = url }

    func load() async {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            guard !closed else { return }
            edit = VideoEdit(duration: duration)
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .varispeed
            player.replaceCurrentItem(with: item)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                Task { @MainActor in self?.tick(time.seconds) }
            }
            loading = false
            changed()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 100)
            for index in 0..<12 {
                guard !closed else { return }
                if let result = try? await generator.image(at: CMTime(seconds: duration * Double(index) / 12, preferredTimescale: 600)) {
                    thumbnails.append(NSImage(cgImage: result.image, size: .zero))
                }
            }
        } catch { self.error = error.localizedDescription; loading = false }
    }

    private func tick(_ time: Double) {
        guard !seeking, pendingSeek == nil else { return }
        if playing {
            if time >= edit.end { pause(); seek(edit.start); return }
            position = max(edit.start, time)
            player.rate = Float(edit.speed(at: position))
        }
    }

    func togglePlayback() {
        if playing { pause() } else {
            if position < edit.start || position >= edit.end { seek(edit.start) }
            playing = true
            player.playImmediately(atRate: Float(edit.speed(at: max(edit.start, position))))
        }
    }

    func pause() { playing = false; player.pause() }

    /// Chase the newest drag position, never queue stale seeks behind the mouse.
    func seek(_ time: Double) {
        position = min(edit.end, max(edit.start, time))
        pendingSeek = position
        chaseSeek()
    }

    private func chaseSeek() {
        guard !seeking, let target = pendingSeek else { return }
        seeking = true
        pendingSeek = nil
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.seeking = false
                self.chaseSeek()
            }
        }
    }

    func updateDuration() {
        generation += 1
        renderTask?.cancel()
        exportSession?.cancelExport()
        exportSession = nil
        if let renderedURL { try? FileManager.default.removeItem(at: renderedURL) }
        renderedURL = nil
        sizeText = "Calculating…"
        outputDuration = edit.outputDuration
        objectWillChange.send()
    }

    func changed() {
        updateDuration()
        if position < edit.start || position > edit.end { seek(min(edit.end, max(edit.start, position))) }
        generation += 1
        let version = generation
        renderTask?.cancel()
        exportSession?.cancelExport()
        exportSession = nil
        if let renderedURL { try? FileManager.default.removeItem(at: renderedURL) }
        renderedURL = nil
        sizeText = "Calculating…"
        error = nil
        let snapshot = edit
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("video-editor-\(UUID().uuidString).mp4")
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(650))
                try await VideoEditorMedia.export(url: url, edit: snapshot, to: target) { session in
                    if version == self.generation, !self.closed, !Task.isCancelled { self.exportSession = session }
                    else { session.cancelExport() }
                }
                try Task.checkCancellation()
                guard version == generation, !closed else { try? FileManager.default.removeItem(at: target); return }
                let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
                let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                renderedURL = target
                exportSession = nil
            } catch {
                try? FileManager.default.removeItem(at: target)
                if version == generation, !closed, !Task.isCancelled {
                    self.error = "Could not render the edit: \(error.localizedDescription)"
                    sizeText = "Unavailable"
                }
            }
        }
    }

    func removePoint() {
        edit.points.removeAll { $0.id == selected }
        selected = nil
        changed()
    }

    func save() {
        guard let renderedURL else { return }
        pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-edited.mp4"
        panel.canCreateDirectories = true
        saving = true
        panel.begin { [weak self] response in
            guard let self else { return }
            defer { self.saving = false }
            guard response == .OK, let destination = panel.url else { return }
            guard destination.standardizedFileURL != self.url.standardizedFileURL else {
                self.error = "Choose a different name to keep your original recording."
                return
            }
            do {
                // Atomic replacement after NSSavePanel confirms any overwrite.
                let data = try Data(contentsOf: renderedURL, options: .mappedIfSafe)
                try data.write(to: destination, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { self.error = "Could not save the edit: \(error.localizedDescription)" }
        }
    }

    func close() {
        closed = true
        pause()
        renderTask?.cancel()
        exportSession?.cancelExport()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        if let renderedURL { try? FileManager.default.removeItem(at: renderedURL) }
    }
}

private struct EditorPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct EditorTimeline: NSViewRepresentable {
    @ObservedObject var model: VideoEditorModel
    func makeNSView(context: Context) -> VideoTimelineView { VideoTimelineView(model: model) }
    func updateNSView(_ view: VideoTimelineView, context: Context) { view.refreshViewport() }
}

private struct EditorClickCursor: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hovering = true
                    (enabled ? NSCursor.pointingHand : NSCursor.arrow).set()
                case .ended:
                    hovering = false
                    NSCursor.arrow.set()
                }
            }
            .onChange(of: enabled) { _, enabled in
                if hovering { (enabled ? NSCursor.pointingHand : NSCursor.arrow).set() }
            }
            .onDisappear { if hovering { NSCursor.arrow.set() } }
    }
}

private struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    var body: some View {
        VStack(spacing: 0) {
            EditorPlayer(player: model.player)
                .frame(minHeight: 250, maxHeight: .infinity)
                .background(.black)
            VStack(spacing: 8) {
                ZStack {
                    HStack(spacing: 12) {
                        Text("\(Self.time(model.position)) / \(Self.time(model.outputDuration))")
                            .monospacedDigit()
                            .help("Source position / edited duration")
                        Spacer()
                        Text(model.sizeText).monospacedDigit()
                            .help("Edited file size")
                    }
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .offset(x: model.playing ? 0 : 2)
                            .frame(width: 64, height: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(model.playing ? "Pause" : "Play")
                    .help(model.playing ? "Pause (Space)" : "Play (Space)")
                    .keyboardShortcut(.space, modifiers: [])
                    .modifier(EditorClickCursor())
                    .disabled(model.loading)
                }
                EditorTimeline(model: model).frame(height: 208)
                if let error = model.error {
                    HStack {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        if model.edit.duration > 0 { Button("Retry render", action: model.changed).modifier(EditorClickCursor()) }
                    }
                }
                HStack(spacing: 12) {
                    if let point = model.edit.points.first(where: { $0.id == model.selected }) {
                        Text(String(format: "%.3f×", point.speed)).monospacedDigit()
                        Button(action: model.removePoint) {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Remove speed point")
                        .help("Remove speed point")
                        .modifier(EditorClickCursor())
                    }
                    Spacer()
                    Button {
                        model.viewportZoomed = false
                        model.zoomResetToken += 1
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Reset zoom")
                    .help("Reset speed and timeline zoom")
                    .modifier(EditorClickCursor())
                    .disabled(!model.viewportZoomed)
                    Button {
                        model.edit = VideoEdit(duration: model.edit.duration)
                        model.selected = nil
                        model.changed()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset edits")
                    .help("Reset edits")
                    .modifier(EditorClickCursor())
                    .disabled(model.loading || model.saving)
                    Button("Save…", action: model.save)
                        .help("Save edited video (⌘S)")
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .modifier(EditorClickCursor())
                        .disabled(model.renderedURL == nil || model.saving)
                }
            }.padding(12).background(.background)
        }.overlay { if model.loading { ProgressView("Loading recording…").padding().background(.regularMaterial) } }
    }

    static func time(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}
