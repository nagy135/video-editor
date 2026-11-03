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
        super.init(window: window)
        window.contentView = NSHostingView(rootView: VideoEditorView(model: model, onFinish: { [weak self] in
            self?.close()
        }))
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
    @Published var selectedSegment: Range<Double>?
    private struct EditSnapshot {
        let edit: VideoEdit
        let point: UUID?
        let cut: UUID?
        let segment: Range<Double>?
        let position: Double
    }
    @Published private var undoHistory: [EditSnapshot] = []
    @Published private var pendingEdit: EditSnapshot?
    @Published var zoomResetToken = 0
    @Published var viewportZoomed = false
    @Published var sizeText = "Loading…"
    @Published var error: String?
    @Published var loading = true
    @Published var saving = false
    @Published var renderedURL: URL?
    @Published var thumbnails: [NSImage] = []
    @Published var showSpeedCurve = false
    @Published var waveform: AudioWaveform?
    @Published var waveformStatus = "Loading audio…"
    private var waveformTask: Task<Void, Never>?
    private var waveformDecodeTask: Task<AudioWaveform?, Error>?
    private var playbackTask: Task<Void, Never>?
    private var sourceItem: AVPlayerItem?
    private var playbackEdit: VideoEdit?
    private var preparedEdit: VideoEdit?
    private var preparedComposition: AVMutableComposition?
    private var itemGeneration = 0
    private var exportSession: AVAssetExportSession?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
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
            let decode = Task.detached(priority: .utility) { try await AudioWaveform.load(url: self.url) }
            waveformDecodeTask = decode
            waveformTask = Task { [weak self] in
                do {
                    let waveform = try await decode.value
                    guard let self, !self.closed else { return }
                    self.waveform = waveform
                    self.waveformStatus = waveform == nil ? "No audio" : "Audio"
                } catch {
                    guard let self, !self.closed else { return }
                    self.waveformStatus = "Audio waveform unavailable"
                }
            }
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
        exportSession?.cancelExport()
        exportSession = nil
        if let renderedURL { try? FileManager.default.removeItem(at: renderedURL) }
        renderedURL = nil
        sizeText = "Updating estimate…"
        outputDuration = edit.outputDuration
        objectWillChange.send()
    }

    func changed(pausePlayback: Bool = true) {
        // A reset or toolbar edit may arrive while a preview is being prepared.
        // Cancel it so an obsolete composition cannot start after the edit.
        if pausePlayback { pause() }
        player.volume = edit.effectiveAudioVolume
        updateDuration()
        if position < edit.start || position > edit.end { seek(min(edit.end, max(edit.start, position))) }
        error = nil
        guard !edit.retainedRanges.isEmpty else {
            sizeText = "No video remaining"
            return
        }
        // A size estimate must not encode the entire video or gate export actions.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attributes[.size] as? NSNumber, edit.duration > 0 {
            let estimate = Double(bytes.int64Value) * outputDuration / edit.duration
            sizeText = "≈ " + ByteCountFormatter.string(fromByteCount: Int64(estimate), countStyle: .file)
        } else {
            sizeText = "Size available after export"
        }
    }

    var canExport: Bool { !closed && !loading && !saving && !edit.retainedRanges.isEmpty }

    private func prepareExport() async throws -> URL {
        if let renderedURL { return renderedURL }
        guard !closed, !loading, !edit.retainedRanges.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("video-editor-\(UUID().uuidString).mp4")
        do {
            try await VideoEditorMedia.export(url: url, edit: edit, to: target) { session in
                if self.closed { session.cancelExport() }
                else { self.exportSession = session }
            }
            guard !closed else { throw CancellationError() }
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            renderedURL = target
            exportSession = nil
            return target
        } catch {
            exportSession = nil
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    private func snapshot() -> EditSnapshot {
        EditSnapshot(edit: edit, point: selected, cut: selectedCut, segment: selectedSegment, position: position)
    }

    // One snapshot per gesture, regardless of the number of mouse-drag updates.
    func beginEdit() {
        guard !closed, !loading, !saving, pendingEdit == nil else { return }
        pendingEdit = snapshot()
    }

    func endEdit(pausePlayback: Bool = true) {
        guard let before = pendingEdit else { return }
        pendingEdit = nil
        guard before.edit != edit else { return }
        undoHistory.append(before)
        if let selectedSegment, !edit.retainedRanges.contains(selectedSegment) { self.selectedSegment = nil }
        changed(pausePlayback: pausePlayback)
    }

    var canUndo: Bool { !closed && !loading && !saving && pendingEdit == nil && !undoHistory.isEmpty }
    var canDeleteSegment: Bool {
        !closed && !loading && !saving && pendingEdit == nil
            && selectedSegment.map { edit.retainedRanges.contains($0) } == true
    }

    func selectSegment(at time: Double) {
        selectedSegment = edit.retainedRanges.first { $0.contains(time) }
        selected = nil
        selectedCut = nil
    }

    func setOutputVolume(_ volume: Double, continuous: Bool = false) {
        guard !closed, !loading, !saving, volume.isFinite else { return }
        if !continuous { beginEdit() }
        edit.audioVolume = Float(min(1, max(0, volume)))
        edit.audioMuted = false
        player.volume = edit.effectiveAudioVolume
        if !continuous { endEdit(pausePlayback: false) }
    }

    func toggleOutputMute() {
        guard !closed, !loading, !saving else { return }
        beginEdit()
        if edit.audioMuted || edit.audioVolume == 0 {
            edit.audioMuted = false
            if edit.audioVolume == 0 { edit.audioVolume = 1 }
        } else {
            edit.audioMuted = true
        }
        player.volume = edit.effectiveAudioVolume
        endEdit(pausePlayback: false)
    }

    func deleteSelectedSegment() {
        guard canDeleteSegment, let range = selectedSegment else { return }
        beginEdit()
        edit.cuts.append(VideoCut(start: range.lowerBound, end: range.upperBound))
        selectedSegment = nil
        selectedCut = nil
        selected = nil
        endEdit()
    }

    private func gapCuts(containing id: UUID) -> [VideoCut] {
        guard let cut = edit.cuts.first(where: { $0.id == id }) else { return [] }
        var lower = cut.start
        var upper = cut.end
        var group = [cut]
        while true {
            let connected = edit.cuts.filter { $0.start <= upper && $0.end >= lower }
            let nextLower = connected.map(\.start).min() ?? lower
            let nextUpper = connected.map(\.end).max() ?? upper
            group = connected
            if lower == nextLower, upper == nextUpper { return group }
            lower = nextLower
            upper = nextUpper
        }
    }

    /// Merge the exclusions behind a visible boundary before resizing it.
    /// Old split seams inside a deleted segment must never become editable islands.
    func prepareCutHandle(_ id: UUID, left: Bool) {
        let group = gapCuts(containing: id)
        guard let original = group.first(where: { $0.id == id }),
              let lower = group.map(\.start).min(), let upper = group.map(\.end).max() else { return }
        if group.count > 1 {
            let ids = Set(group.map(\.id))
            var merged = VideoCut(id: id, start: lower, end: upper)
            merged.split = min(upper, max(lower, original.split))
            edit.cuts.removeAll { ids.contains($0.id) }
            edit.cuts.append(merged)
        }
        focusCutSegment(id, left: left)
    }

    func focusCutSegment(_ id: UUID, left: Bool) {
        guard let cut = edit.cuts.first(where: { $0.id == id }) else { return }
        selectedSegment = edit.retainedRanges.first { left ? $0.upperBound == cut.start : $0.lowerBound == cut.end }
        selected = nil
        selectedCut = nil
    }

    func gapRange(containing id: UUID) -> Range<Double>? {
        let cuts = gapCuts(containing: id)
        guard let lower = cuts.map(\.start).min(), let upper = cuts.map(\.end).max() else { return nil }
        return lower..<upper
    }

    func joinGap(_ id: UUID) {
        guard !closed, !loading, !saving, pendingEdit == nil,
              let range = gapRange(containing: id) else { return }
        let ids = Set(gapCuts(containing: id).map(\.id))
        beginEdit()
        edit.cuts.removeAll { ids.contains($0.id) }
        selectSegment(at: (range.lowerBound + range.upperBound) / 2)
        endEdit()
    }

    func undoEdit() {
        guard canUndo, let before = undoHistory.popLast() else { return }
        edit = before.edit
        selected = before.point
        selectedCut = before.cut
        selectedSegment = before.segment
        position = before.position
        changed()
        seek(position)
    }

    func resetEdits() {
        guard !closed, !loading, !saving else { return }
        beginEdit()
        edit = VideoEdit(duration: edit.duration)
        selected = nil
        selectedCut = nil
        selectedSegment = nil
        endEdit()
    }

    func addCut() {
        guard !loading, !saving, edit.end > edit.start else { return }
        pause()
        let split = min(edit.end, max(edit.start, position))
        guard edit.retainedRanges.contains(where: { split > $0.lowerBound && split < $0.upperBound }) else { return }
        if let existing = edit.cuts.first(where: { abs($0.split - split) < 0.001 }) {
            selectedCut = existing.id
            selected = nil
            return
        }
        beginEdit()
        let cut = VideoCut(start: split, end: split)
        edit.cuts.append(cut)
        selectSegment(at: split)
        endEdit()
    }

    func removePoint() {
        guard !loading, !saving else { return }
        beginEdit()
        edit.points.removeAll { $0.id == selected }
        selected = nil
        endEdit()
    }

    /// Keep quick exports beside the original; closing the editor deletes its render cache.
    func exportVideo() async throws -> URL {
        guard !closed, !saving else { throw CocoaError(.fileReadNoSuchFile) }
        saving = true
        defer { saving = false }
        let renderedURL = try await prepareExport()
        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent + "-edited"
        var suffix = 1
        while true {
            let filename = suffix == 1 ? "\(name).mp4" : "\(name)-\(suffix).mp4"
            let destination = directory.appendingPathComponent(filename)
            do {
                try FileManager.default.copyItem(at: renderedURL, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    func revealExport() async -> Bool {
        pause()
        do {
            let destination = try await exportVideo()
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return true
        } catch {
            self.error = "Could not export the edit: \(error.localizedDescription)"
            return false
        }
    }

    func copyExport(to pasteboard: NSPasteboard = .general) async -> Bool {
        pause()
        do {
            let destination = try await exportVideo()
            pasteboard.clearContents()
            guard pasteboard.writeObjects([destination as NSURL]) else {
                try? FileManager.default.removeItem(at: destination)
                self.error = "Could not copy the exported video to the clipboard."
                return false
            }
            return true
        } catch {
            self.error = "Could not export the edit: \(error.localizedDescription)"
            return false
        }
    }

    func save() {
        guard canExport else { return }
        pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-edited.mp4"
        panel.canCreateDirectories = true
        saving = true
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { self.saving = false; return }
            guard destination.standardizedFileURL != self.url.standardizedFileURL else {
                self.error = "Choose a different name to keep your original recording."
                self.saving = false
                return
            }
            Task { @MainActor in
                defer { self.saving = false }
                do {
                    let renderedURL = try await self.prepareExport()
                    // Atomic replacement after NSSavePanel confirms any overwrite.
                    let data = try Data(contentsOf: renderedURL, options: .mappedIfSafe)
                    try data.write(to: destination, options: .atomic)
                } catch { self.error = "Could not save the edit: \(error.localizedDescription)" }
            }
        }
    }

    func close() {
        closed = true
        waveformDecodeTask?.cancel()
        waveformTask?.cancel()
        pause()
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

private struct EditorTimeline: NSViewRepresentable, Animatable {
    @ObservedObject var model: VideoEditorModel
    nonisolated var curveExpansion: Double
    nonisolated var animatableData: Double {
        get { curveExpansion }
        set { curveExpansion = newValue }
    }
    func makeNSView(context: Context) -> VideoTimelineView { VideoTimelineView(model: model) }
    func updateNSView(_ view: VideoTimelineView, context: Context) {
        view.setCurveExpansion(curveExpansion)
        view.refreshViewport()
    }
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
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(model.saving ? "Exporting…" : model.sizeText).monospacedDigit()
                                .help("Estimated edited file size; exact size is shown after export")
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                    model.showSpeedCurve.toggle()
                                }
                            } label: {
                                Image(systemName: "speaker.wave.2")
                            }
                            .accessibilityLabel(model.showSpeedCurve ? "Hide speed curve" : "Show speed curve")
                            .accessibilityValue(model.showSpeedCurve ? "Expanded" : "Collapsed")
                            .help(model.showSpeedCurve ? "Hide speed curve" : "Show speed curve")
                            .background(model.showSpeedCurve ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .modifier(EditorClickCursor())
                        }
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
                EditorTimeline(model: model, curveExpansion: model.showSpeedCurve ? 1 : 0)
                    .frame(height: model.showSpeedCurve ? 260 : 136)
                if let error = model.error {
                    HStack {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)

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
                    Button(action: model.undoEdit) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .keyboardShortcut("u", modifiers: [])
                    .accessibilityLabel("Undo edit")
                    .help("Undo the latest edit, including splits, segment deletion, and trimming (U)")
                    .modifier(EditorClickCursor())
                    .disabled(!model.canUndo)
                    Button(action: model.deleteSelectedSegment) {
                        Image(systemName: "trash")
                    }
                    .keyboardShortcut("d", modifiers: [])
                    .accessibilityLabel("Delete selected segment")
                    .help("Delete the highlighted segment (D or X); U undoes it")
                    .modifier(EditorClickCursor())
                    .disabled(!model.canDeleteSegment)
                    if let point = model.edit.points.first(where: { $0.id == model.selected }) {
                        Text(String(format: "%.3f×", point.speed)).monospacedDigit()
                        Button(action: model.removePoint) {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Remove speed point")
                        .help("Remove speed point")
                        .disabled(model.saving)
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
                    Button(action: model.resetEdits) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset edits")
                    .help("Reset edits")
                    .modifier(EditorClickCursor())
                    .disabled(model.loading || model.saving)
                    Button("Save…", action: model.save)
                        .help("Save edited video to a new location and keep editing (⌘S)")
                        .keyboardShortcut("s", modifiers: .command)
                        .modifier(EditorClickCursor())
                        .disabled(!model.canExport)
                    Button {
                        Task { if await model.revealExport() { onFinish() } }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Show export in Finder and close")
                    .help("Export beside the original, show in Finder, and close the editor")
                    .modifier(EditorClickCursor())
                    .disabled(!model.canExport)
                    Button {
                        Task { if await model.copyExport() { onFinish() } }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .accessibilityLabel("Copy exported video and close")
                    .help("Copy the exported video file to the clipboard and close the editor")
                    .buttonStyle(.borderedProminent)
                    .modifier(EditorClickCursor())
                    .disabled(!model.canExport)
                }
            }.padding(12).background(.background)
        }.overlay { if model.loading { ProgressView("Loading recording…").padding().background(.regularMaterial) } }
    }

    static func time(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}
