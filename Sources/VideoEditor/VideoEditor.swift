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
    @Published var selectedCut: UUID?
    @Published var zoomResetToken = 0
    @Published var viewportZoomed = false
    @Published var sizeText = "Calculating…"
    @Published var error: String?
    @Published var loading = true
    @Published var saving = false
    @Published var renderedURL: URL?
    @Published var thumbnails: [NSImage] = []
    private var playbackTask: Task<Void, Never>?
    private var sourceItem: AVPlayerItem?
    private var playbackEdit: VideoEdit?
    private var preparedEdit: VideoEdit?
    private var preparedComposition: AVMutableComposition?
    private var itemGeneration = 0
    private var renderTask: Task<Void, Never>?
    private var exportSession: AVAssetExportSession?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
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
            sourceItem = item
            installPlayerItem(item, edit: nil)
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

    private func installPlayerItem(_ item: AVPlayerItem, edit: VideoEdit?) {
        itemGeneration += 1
        let version = itemGeneration
        seeking = false
        pendingSeek = nil
        playbackEdit = edit
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        item.audioTimePitchAlgorithm = .varispeed
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing, !self.closed, self.itemGeneration == version else { return }
                self.finishPlayback()
            }
        }
    }

    private func finishPlayback() {
        let end = playbackEdit?.retainedRanges.last?.upperBound ?? edit.end
        pause()
        position = end
    }

    private func tick(_ time: Double) {
        guard playing, !seeking, pendingSeek == nil, let playbackEdit else { return }
        position = playbackEdit.sourceTime(atPlaybackTime: time)
        // The composition plays through joins itself. No seek, item replacement,
        // or rate restart is performed when the source playhead crosses a cut.
        let rate = Float(edit.speed(at: position))
        if player.rate != rate { player.rate = rate }
    }

    func togglePlayback() {
        if playing { pause() }
        else { startPlayback(at: position) }
    }

    func playFromStart() {
        guard let first = edit.retainedRanges.first else { return }
        startPlayback(at: first.lowerBound)
    }

    private func startPlayback(at sourceTime: Double) {
        guard !loading, !saving, let first = edit.retainedRanges.first else { return }
        pause()
        playing = true
        let target = edit.nextPlayableTime(at: sourceTime) ?? first.lowerBound
        var snapshot = edit
        snapshot.points = [] // Speed is applied live; only trim/cuts belong in the composition.
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let composition: AVMutableComposition
                if preparedEdit == snapshot, let cached = preparedComposition {
                    composition = cached
                } else {
                    composition = try await VideoEditorMedia.composition(url: url, edit: snapshot)
                }
                try Task.checkCancellation()
                guard playing, !closed else { return }
                preparedEdit = snapshot
                preparedComposition = composition
                installPlayerItem(AVPlayerItem(asset: composition), edit: snapshot)
                seek(target)
            } catch {
                guard !Task.isCancelled, !closed else { return }
                pause()
                self.error = "Could not prepare playback: \(error.localizedDescription)"
            }
        }
    }

    private func resumePlayback() {
        guard playing, !closed, playbackEdit != nil else { return }
        player.playImmediately(atRate: Float(edit.speed(at: position)))
    }

    func pause() {
        playing = false
        player.pause()
        playbackTask?.cancel()
        playbackTask = nil
    }

    /// Chase the newest drag position, never queue stale seeks behind the mouse.
    func seek(_ time: Double) {
        // Scrubbing must still show source frames inside removed ranges.
        if !playing, playbackEdit != nil, let sourceItem {
            installPlayerItem(sourceItem, edit: nil)
        }
        position = min(edit.end, max(edit.start, time))
        pendingSeek = position
        chaseSeek()
    }

    private func chaseSeek() {
        guard !seeking, let target = pendingSeek else { return }
        seeking = true
        pendingSeek = nil
        let version = itemGeneration
        let itemTime = playbackEdit?.playbackTime(atSourceTime: target) ?? target
        let targetTime = CMTime(value: Int64(ceil(itemTime * 60000)), timescale: 60000)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.closed, self.itemGeneration == version else { return }
                self.seeking = false
                if self.pendingSeek != nil { self.chaseSeek() }
                else { self.resumePlayback() }
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
        // A reset or toolbar edit may arrive while a preview is being prepared.
        // Cancel it so an obsolete composition cannot start after the edit.
        pause()
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
        guard !edit.retainedRanges.isEmpty else {
            sizeText = "No video remaining"
            return
        }
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

    func addCut() {
        guard !loading, !saving, edit.end > edit.start else { return }
        pause()
        let split = min(edit.end, max(edit.start, position))
        guard split > edit.start, split < edit.end else { return }
        if let existing = edit.cuts.first(where: { abs($0.split - split) < 0.001 }) {
            selectedCut = existing.id
            selected = nil
            return
        }
        let cut = VideoCut(start: split, end: split)
        edit.cuts.append(cut)
        selectedCut = cut.id
        selected = nil
        changed()
    }

    func undoCut() {
        guard !loading, !saving, !edit.cuts.isEmpty else { return }
        pause()
        let id = selectedCut ?? edit.cuts.last!.id
        edit.cuts.removeAll { $0.id == id }
        selectedCut = nil
        changed()
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        itemGeneration += 1
        player.replaceCurrentItem(with: nil)
        sourceItem = nil
        preparedComposition = nil
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
                    HStack(spacing: 10) {
                        Button(action: model.playFromStart) {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Play from start")
                        .help("Play from the beginning of the edited video")
                        .modifier(EditorClickCursor())
                        .disabled(model.loading || model.saving || model.edit.retainedRanges.isEmpty)
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
                        Color.clear.frame(width: 34, height: 34)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                EditorTimeline(model: model).frame(height: 208)
                if let error = model.error {
                    HStack {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        if model.edit.duration > 0 { Button("Retry render", action: model.changed).modifier(EditorClickCursor()) }
                    }
                }
                HStack(spacing: 12) {
                    Button(action: model.addCut) {
                        Label("Add Cut", systemImage: "scissors")
                    }
                    .keyboardShortcut("c", modifiers: [])
                    .help("Split the blue filmstrip at the playhead (C). Drag the handles apart to trim.")
                    .modifier(EditorClickCursor())
                    .disabled(model.loading || model.saving)
                    Button(action: model.undoCut) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .keyboardShortcut("u", modifiers: [])
                    .accessibilityLabel("Undo cut")
                    .help("Restore the selected cut, or the latest cut (U)")
                    .modifier(EditorClickCursor())
                    .disabled(model.loading || model.saving || model.edit.cuts.isEmpty)
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
                        model.selectedCut = nil
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
