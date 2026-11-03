import AppKit
import VideoEditorCore

@MainActor
private final class AudioVolumeSlider: NSSlider {
    var beginGesture: (() -> Void)?
    var endGesture: (() -> Void)?
    private(set) var trackingGesture = false
    override func mouseDown(with event: NSEvent) {
        beginGesture?()
        trackingGesture = true
        super.mouseDown(with: event)
        trackingGesture = false
        endGesture?()
    }
}

@MainActor
private final class HoverAudioControl: NSView {
    var hoverChanged: ((Bool) -> Void)?
    var expanded = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
    override func draw(_ dirtyRect: NSRect) {
        if expanded {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }
}

@MainActor
final class VideoTimelineView: NSView {
    private let model: VideoEditorModel
    private enum Drag { case start, end, scrub, point(UUID), cutStart(UUID), cutEnd(UUID), gap(UUID) }
    private var drag: Drag?
    private var edited = false
    private var cutDragOffset = 0.0
    private let joinButton = NSButton()
    private let muteButton = NSButton()
    private let audioControls = HoverAudioControl()
    private var audioControlsHovered = false
    private let volumeSlider = AudioVolumeSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var hoveredGap: UUID?
    private var joinGapID: UUID?

    // Put the two handles inside their respective clips so an untouched split
    // exposes both handles without deleting any source frames.
    private func cutHandle(_ cut: VideoCut, left: Bool) -> NSRect {
        NSRect(x: left ? x(cut.start) - 10 : x(cut.end) + 1,
               y: strip.minY - 3, width: 9, height: strip.height + 6)
    }
    // Only boundaries that actually touch retained footage have handles.
    // Internal seams covered by a larger exclusion cannot be dragged back out.
    private var visibleCutHandles: [(cut: VideoCut, left: Bool)] {
        var handles: [(VideoCut, Bool)] = []
        for range in model.edit.retainedRanges {
            if range.upperBound < model.edit.end,
               let cut = model.edit.cuts.filter({ $0.start == range.upperBound }).max(by: { $0.end < $1.end }) {
                handles.append((cut, true))
            }
            if range.lowerBound > model.edit.start,
               let cut = model.edit.cuts.filter({ $0.end == range.lowerBound }).min(by: { $0.start < $1.start }) {
                handles.append((cut, false))
            }
        }
        return handles
    }

    private var isDraggingStart: Bool { if case .start = drag { return true }; return false }
    private var isDraggingEnd: Bool { if case .end = drag { return true }; return false }
    private var cursorTracking: NSTrackingArea?
    private var speedSpan = 9.0
    private var timeZoom = 1.0
    private var visibleStart = 0.0
    private var resetToken = 0
    private let timeScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 12))
    private var accessibilityViewport = ""
    private var visibleDuration: Double { model.edit.duration / timeZoom }
    private var visibleEnd: Double { visibleStart + visibleDuration }
    private var animatedExpansion: Double?
    private var curveExpansion: Double { animatedExpansion ?? (model.showSpeedCurve ? 1 : 0) }
    private var curveBottom: Double { 8 + 124 * curveExpansion }

    func setCurveExpansion(_ expansion: Double) {
        animatedExpansion = min(1, max(0, expansion))
        updateScroller()
        updateJoinButton()
        updateVolumeControls()
        needsDisplay = true
    }

    private var graph: NSRect { NSRect(x: 38, y: 8 - 124 * (1 - curveExpansion), width: max(1, bounds.width - 54), height: 112) }
    private var audio: NSRect { NSRect(x: graph.minX, y: 18 + 124 * curveExpansion, width: graph.width, height: 44) }
    private var strip: NSRect { NSRect(x: graph.minX, y: audio.maxY + 8, width: graph.width, height: 42) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Keep X available after clicking toolbar controls as well as the timeline.
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.charactersIgnoringModifiers?.lowercased() == "x", model.canDeleteSegment,
           !((window?.firstResponder as? NSTextView)?.isEditable ?? false) {
            model.deleteSelectedSegment()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "d", "x": model.deleteSelectedSegment()
        case "u": model.undoEdit()
        default: super.keyDown(with: event)
        }
    }

    init(model: VideoEditorModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel("Speed curve, audio waveform, trim and cut timeline")
        timeScroller.controlSize = .small
        timeScroller.scrollerStyle = .legacy
        timeScroller.target = self
        timeScroller.action = #selector(scrollTime)
        timeScroller.isHidden = true
        addSubview(timeScroller)
        joinButton.image = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: "Join segments")
        joinButton.imagePosition = .imageOnly
        joinButton.bezelStyle = .rounded
        joinButton.controlSize = .small
        joinButton.setAccessibilityLabel("Restore footage and join segments")
        joinButton.toolTip = "Restore removed footage and join surrounding segments (U undoes)"
        joinButton.target = self
        joinButton.action = #selector(joinSelectedGap)
        joinButton.isHidden = true
        addSubview(joinButton)
        muteButton.imagePosition = .imageOnly
        muteButton.bezelStyle = .inline
        muteButton.isBordered = false
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(changeVolume)
        volumeSlider.setAccessibilityLabel("Output volume")
        volumeSlider.beginGesture = { [weak model] in model?.beginEdit() }
        volumeSlider.endGesture = { [weak model] in model?.endEdit(pausePlayback: false) }
        audioControls.addSubview(muteButton)
        audioControls.addSubview(volumeSlider)
        audioControls.hoverChanged = { [weak self] hovering in
            self?.audioControlsHovered = hovering
            self?.updateVolumeControls()
        }
        addSubview(audioControls)
        updateVolumeControls()
        toolTip = "Click or drag the audio waveform to scrub to speech. Scroll over the graph to zoom toward 1×; scroll over the filmstrip to zoom in time. Scroll sideways or use the scrollbar to pan. Click the speed graph to add speed points from 1× to 10×. Drag filmstrip ends to trim; drag inside to scrub. Press C to split the blue filmstrip. Drag the left handle left or the right handle right to trim away from the split; Click a gap for its join button to restore footage. Click a segment to select it; D or X deletes it. U undoes the latest edit."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func x(_ time: Double) -> Double { graph.minX + (time - visibleStart) / max(0.001, visibleDuration) * graph.width }
    private func y(_ speed: Double) -> Double { graph.maxY - (speed - 1) / speedSpan * graph.height }
    private func time(_ x: Double) -> Double { min(model.edit.duration, max(0, visibleStart + (x - graph.minX) / graph.width * visibleDuration)) }
    private func speed(_ y: Double) -> Double { min(1 + speedSpan, max(1, 1 + (graph.maxY - y) / graph.height * speedSpan)) }

    func refreshViewport() {
        if resetToken != model.zoomResetToken {
            resetToken = model.zoomResetToken
            speedSpan = 9
            timeZoom = 1
            visibleStart = 0
        }
        updateScroller()
        updateJoinButton()
        updateVolumeControls()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateScroller()
        updateJoinButton()
        updateVolumeControls()
    }

    private func updateScroller() {
        let frame = NSRect(x: strip.minX, y: strip.maxY + 8, width: strip.width, height: 12)
        if timeScroller.frame != frame { timeScroller.frame = frame }
        let hidden = timeZoom <= 1
        if timeScroller.isHidden != hidden { timeScroller.isHidden = hidden }
        if timeScroller.knobProportion != 1 / timeZoom { timeScroller.knobProportion = 1 / timeZoom }
        let overflow = model.edit.duration - visibleDuration
        let position = overflow > 0 ? visibleStart / overflow : 0
        if timeScroller.doubleValue != position { timeScroller.doubleValue = position }
        let selection = model.selectedSegment.map { String(format: "; selected segment %.2f–%.2f seconds", $0.lowerBound, $0.upperBound) } ?? ""
        let value = String(format: "Speed 1×–%.3g×; time %.2f–%.2f seconds", 1 + speedSpan, visibleStart, visibleEnd) + selection
        if accessibilityViewport != value {
            accessibilityViewport = value
            setAccessibilityValue(value)
        }
    }

    private func updateVolumeControls() {
        let muted = model.edit.effectiveAudioVolume == 0
        let showSlider = volumeSlider.trackingGesture || (!muted && audioControlsHovered)
        audioControls.frame = NSRect(x: 3, y: audio.midY - 14, width: showSlider ? 132 : 26, height: 28)
        audioControls.expanded = showSlider
        muteButton.frame = NSRect(x: 1, y: 3, width: 24, height: 22)
        volumeSlider.frame = NSRect(x: 31, y: 4, width: 92, height: 20)
        volumeSlider.isHidden = !showSlider
        muteButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                  accessibilityDescription: muted ? "Unmute output" : "Mute output")
        muteButton.setAccessibilityLabel(muted ? "Unmute output" : "Mute output")
        muteButton.toolTip = muted ? "Unmute output audio" : "Mute output audio completely"
        if !volumeSlider.trackingGesture { volumeSlider.doubleValue = Double(model.edit.effectiveAudioVolume) }
        volumeSlider.toolTip = "Output volume: \(Int(model.edit.effectiveAudioVolume * 100))%"
        volumeSlider.isEnabled = !model.loading && !model.saving
        muteButton.isEnabled = volumeSlider.isEnabled
    }

    @objc private func toggleMute() {
        model.toggleOutputMute()
        updateVolumeControls()
    }

    @objc private func changeVolume() {
        model.setOutputVolume(volumeSlider.doubleValue, continuous: volumeSlider.trackingGesture)
        updateVolumeControls()
    }

    private func updateJoinButton() {
        let id = hoveredGap ?? model.selectedCut
        guard drag == nil, !model.loading, !model.saving, let id,
              let range = model.gapRange(containing: id) else {
            joinButton.isHidden = true
            joinGapID = nil
            return
        }
        let left = max(strip.minX, x(max(model.edit.start, range.lowerBound)))
        let right = min(strip.maxX, x(min(model.edit.end, range.upperBound)))
        guard right >= left, right >= strip.minX, left <= strip.maxX else {
            joinButton.isHidden = true
            joinGapID = nil
            return
        }
        joinGapID = id
        joinButton.frame = NSRect(x: min(strip.maxX - 28, max(strip.minX, (left + right) / 2 - 14)),
                                  y: strip.midY - 12, width: 28, height: 24)
        joinButton.isHidden = false
    }

    @objc private func joinSelectedGap() {
        guard let id = joinGapID else { return }
        model.joinGap(id)
        hoveredGap = nil
        window?.makeFirstResponder(self)
        updateJoinButton()
        updateVolumeControls()
        needsDisplay = true
    }

    private func viewportChanged() {
        model.viewportZoomed = timeZoom > 1.00001 || speedSpan < 8.99999
        updateScroller()
        updateJoinButton()
        updateVolumeControls()
        needsDisplay = true
    }

    @objc private func scrollTime() {
        let overflow = max(0, model.edit.duration - visibleDuration)
        switch timeScroller.hitPart {
        case .decrementPage: visibleStart -= visibleDuration * 0.8
        case .incrementPage: visibleStart += visibleDuration * 0.8
        default: visibleStart = timeScroller.doubleValue * overflow
        }
        visibleStart = min(overflow, max(0, visibleStart))
        viewportChanged()
    }

    private func zoom(by amount: Double, at p: NSPoint) {
        guard drag == nil, !model.loading, model.edit.duration > 0 else { return }
        if model.showSpeedCurve, p.y < curveBottom {
            speedSpan = min(9, max(0.1, speedSpan * exp(-amount)))
        } else {
            let anchor = time(p.x)
            let fraction = min(1, max(0, (p.x - graph.minX) / graph.width))
            let limit = max(1, min(1000, model.edit.duration / 0.1))
            timeZoom = min(limit, max(1, timeZoom * exp(amount)))
            visibleStart = min(max(0, model.edit.duration - visibleDuration), max(0, anchor - fraction * visibleDuration))
        }
        viewportChanged()
        updateCursor(at: p)
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), drag == nil else { return }
        if !model.showSpeedCurve || p.y >= curveBottom, event.modifierFlags.contains(.shift) || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            let delta = event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : event.scrollingDeltaX
            visibleStart = min(max(0, model.edit.duration - visibleDuration),
                               max(0, visibleStart - delta / graph.width * visibleDuration))
            viewportChanged()
        } else {
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.012 : 0.12
            zoom(by: max(-1, min(1, -Double(event.scrollingDeltaY) * sensitivity)), at: p)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: Double(event.magnification) * 2, at: convert(event.locationInWindow, from: nil))
    }

    private func interaction(at p: NSPoint) -> Drag? {
        guard !model.loading, !model.saving, model.edit.duration > 0, bounds.contains(p) else { return nil }
        if model.showSpeedCurve, p.y < curveBottom {
            if let point = model.edit.points.filter({ $0.speed <= 1 + speedSpan && $0.time >= visibleStart && $0.time <= visibleEnd }).min(by: {
                hypot(x($0.time) - p.x, y($0.speed) - p.y) < hypot(x($1.time) - p.x, y($1.speed) - p.y)
            }), (hypot(x(point.time) - p.x, y(point.speed) - p.y) < 14 || abs(point.time - time(p.x)) < 0.002) {
                return .point(point.id)
            }
            return nil // Empty graph space creates a point.
        }
        if audio.contains(p) { return .scrub }
        guard p.y >= strip.minY - 4, p.y <= strip.maxY + 4 else { return nil }
        for (cut, left) in visibleCutHandles {
            if cutHandle(cut, left: left).contains(p) { return left ? .cutStart(cut.id) : .cutEnd(cut.id) }
        }
        for cut in model.edit.cuts where p.x >= x(cut.start) && p.x <= x(cut.end) { return .gap(cut.id) }
        let ranges = model.edit.retainedRanges
        if ranges.first?.lowerBound == model.edit.start, abs(p.x - x(model.edit.start)) < 12 { return .start }
        if ranges.last?.upperBound == model.edit.end, abs(p.x - x(model.edit.end)) < 12 { return .end }
        return .scrub
    }

    private func updateCursor(at p: NSPoint) {
        guard !model.loading, !model.saving, model.edit.duration > 0 else { NSCursor.arrow.set(); return }
        if let drag {
            switch drag {
            case .start, .end, .cutStart, .cutEnd: NSCursor.resizeLeftRight.set()
            case .point, .scrub: NSCursor.closedHand.set()
            case .gap: NSCursor.arrow.set()
            }
            return
        }
        guard bounds.contains(p) else { NSCursor.arrow.set(); return }
        switch interaction(at: p) {
        case .start, .end, .cutStart, .cutEnd: NSCursor.resizeLeftRight.set()
        case .point, .scrub: NSCursor.openHand.set()
        case .gap: NSCursor.arrow.set()
        case nil: (model.showSpeedCurve && p.y < curveBottom ? NSCursor.crosshair : NSCursor.arrow).set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTracking = area
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .gap(let id) = interaction(at: p) { hoveredGap = id }
        else if !joinButton.frame.contains(p) { hoveredGap = nil }
        updateJoinButton()
        updateVolumeControls()
        updateCursor(at: p)
    }
    override func mouseEntered(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        hoveredGap = nil
        updateJoinButton()
        updateVolumeControls()
        if drag == nil { NSCursor.arrow.set() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        if curveExpansion > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 124 * curveExpansion)).addClip()
            drawSpeedGraph()
            NSGraphicsContext.restoreGraphicsState()
        }
        guard model.edit.duration > 0 else { return }
        drawAudio()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: strip.insetBy(dx: -6, dy: -4)).addClip()
        NSColor.tertiaryLabelColor.setFill()
        strip.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: strip).addClip()
        for (index, image) in model.thumbnails.enumerated() {
            let width = graph.width * timeZoom / 12
            image.draw(in: NSRect(x: x(model.edit.duration * Double(index) / 12), y: strip.minY, width: width + 1, height: strip.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSRect(x: strip.minX, y: strip.minY, width: max(0, min(strip.width, x(model.edit.start) - strip.minX)), height: strip.height).fill()
        NSRect(x: max(strip.minX, x(model.edit.end)), y: strip.minY, width: max(0, strip.maxX - max(strip.minX, x(model.edit.end))), height: strip.height).fill()
        // Outline each remaining piece of the original blue bar separately.
        // A fresh zero-width cut is a visible seam, not an excluded range.
        for range in model.edit.retainedRanges {
            let rect = NSRect(x: x(range.lowerBound), y: strip.minY,
                              width: x(range.upperBound) - x(range.lowerBound), height: strip.height)
            (range == model.selectedSegment ? NSColor.systemGreen : NSColor.controlAccentColor).setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            border.stroke()
        }
        for cut in model.edit.cuts {
            let gap = NSRect(x: x(cut.start) - 1, y: strip.minY - 3,
                             width: max(2, x(cut.end) - x(cut.start) + 2), height: strip.height + 6)
            NSColor.windowBackgroundColor.setFill()
            gap.fill()
        }
        for (cut, left) in visibleCutHandles {
            let handle = cutHandle(cut, left: left)
            let boundary = left ? cut.start : cut.end
            let segmentFocused = model.selectedSegment.map { left ? $0.upperBound == boundary : $0.lowerBound == boundary } ?? false
            (segmentFocused ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
            NSColor.white.setFill()
            NSRect(x: handle.midX - 0.5, y: strip.midY - 6, width: 1, height: 12).fill()
        }
        let ranges = model.edit.retainedRanges
        let outerHandles = [ranges.first?.lowerBound == model.edit.start ? model.edit.start : nil,
                            ranges.last?.upperBound == model.edit.end ? model.edit.end : nil].compactMap { $0 }
        for t in outerHandles {
            let handle = NSRect(x: x(t) - 5, y: strip.minY - 3, width: 10, height: strip.height + 6)
            let segmentFocused = model.selectedSegment.map { t == model.edit.start ? $0.lowerBound == t : $0.upperBound == t } ?? false
            let dragging = (t == model.edit.start && isDraggingStart) || (t == model.edit.end && isDraggingEnd)
            (segmentFocused || dragging ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
            NSColor.white.setFill()
            NSRect(x: x(t) - 1, y: strip.midY - 6, width: 2, height: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: graph.minX, y: 8, width: graph.width, height: strip.maxY - 8 + 3)).addClip()
        NSColor.labelColor.setStroke()
        let playhead = NSBezierPath()
        playhead.move(to: NSPoint(x: x(model.position), y: 8))
        playhead.line(to: NSPoint(x: x(model.position), y: strip.maxY + 3))
        playhead.lineWidth = 1
        playhead.stroke()
        NSGraphicsContext.restoreGraphicsState()
        for index in 0...4 {
            let t = visibleStart + visibleDuration * Double(index) / 4
            let text = String(format: visibleDuration < 5 ? "%.2fs" : "%.1fs", t)
            text.draw(at: NSPoint(x: min(graph.maxX - 30, x(t)), y: 1 + 124 * curveExpansion), withAttributes: labelAttributes)
        }
    }

    private func drawSpeedGraph() {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: graph.insetBy(dx: -1, dy: -4), xRadius: 4, yRadius: 4).fill()
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let roughStep = speedSpan / 3
        let magnitude = pow(10, floor(log10(roughStep)))
        let step = ([1.0, 2, 3, 5, 10].first { $0 * magnitude >= roughStep } ?? 10) * magnitude
        for index in 0...Int(floor(speedSpan / step + 0.000001)) {
            let rate = 1 + Double(index) * step
            NSColor.separatorColor.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: graph.minX, y: y(rate)))
            line.line(to: NSPoint(x: graph.maxX, y: y(rate)))
            line.lineWidth = 0.5
            line.stroke()
            String(format: "%.3g×", rate).draw(at: NSPoint(x: 5, y: y(rate) - 6), withAttributes: labelAttributes)
        }
        guard model.edit.duration > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: graph.insetBy(dx: -6, dy: -6)).addClip()
        let curve = NSBezierPath()
        for index in 0...Int(graph.width) {
            let px = graph.minX + Double(index)
            let point = NSPoint(x: px, y: y(model.edit.speed(at: time(px))))
            if index == 0 { curve.move(to: point) } else { curve.line(to: point) }
        }
        NSColor.controlAccentColor.setStroke()
        curve.lineWidth = 2.5
        curve.stroke()
        for point in model.edit.points {
            let rect = NSRect(x: x(point.time) - 5, y: y(point.speed) - 5, width: 10, height: 10)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            (point.id == model.selected ? NSColor.labelColor : NSColor.windowBackgroundColor).setStroke()
            let outline = NSBezierPath(ovalIn: rect)
            outline.lineWidth = 2
            outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawAudio() {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: audio, xRadius: 4, yRadius: 4).fill()
        guard let waveform = model.waveform else {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
            model.waveformStatus.draw(at: NSPoint(x: audio.minX + 8, y: audio.midY - 6), withAttributes: attributes)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: audio).addClip()
        NSColor.separatorColor.setFill()
        NSRect(x: audio.minX, y: audio.midY, width: audio.width, height: 0.5).fill()
        let bars = NSBezierPath()
        for pixel in 0..<Int(audio.width) {
            let start = max(0, Int(time(audio.minX + Double(pixel)) / waveform.interval))
            let end = min(waveform.peaks.count, max(start + 1, Int(ceil(time(audio.minX + Double(pixel + 1)) / waveform.interval))))
            guard start < end else { continue }
            let peak = waveform.peaks[start..<end].max() ?? 0
            let height = max(0.5, Double(sqrt(peak)) * (audio.height - 8))
            bars.appendRect(NSRect(x: audio.minX + Double(pixel), y: audio.midY - height / 2, width: 1, height: height))
        }
        NSColor.systemTeal.setFill()
        bars.fill()
        NSColor.windowBackgroundColor.withAlphaComponent(0.7).setFill()
        for range in [0..<model.edit.start, model.edit.end..<model.edit.duration] + model.edit.cuts.map({ $0.start..<$0.end }) {
            NSRect(x: x(range.lowerBound), y: audio.minY, width: x(range.upperBound) - x(range.lowerBound), height: audio.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        guard !model.loading, !model.saving else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard location.x >= graph.minX else { return }
        window?.makeFirstResponder(self)
        model.pause()
        model.beginEdit()
        let p = convert(event.locationInWindow, from: nil)
        edited = false
        cutDragOffset = 0
        if model.showSpeedCurve, p.y < curveBottom {
            model.selectedSegment = nil
            if case .point(let id) = interaction(at: p) {
                model.selectedCut = nil
                model.selected = id
                drag = .point(id)
            } else if let point = model.edit.points.first(where: { abs($0.time - time(p.x)) < 0.002 }) {
                // Reuse a point at this time even when it is above the zoomed
                // speed range, rather than introducing coincident points.
                model.selectedCut = nil
                model.selected = point.id
                drag = .point(point.id)
            } else {
                let point = SpeedPoint(time: time(p.x), speed: speed(p.y))
                model.edit.points.append(point)
                model.selectedCut = nil
                model.selected = point.id
                drag = .point(point.id)
                edited = true
            }
        } else {
            drag = interaction(at: p)
            switch drag {
            case .cutStart(let id), .cutEnd(let id):
                let left: Bool
                if case .cutStart = drag { left = true } else { left = false }
                model.focusCutSegment(id, left: left)
                if let cut = model.edit.cuts.first(where: { $0.id == id }) {
                    cutDragOffset = time(p.x) - (left ? cut.start : cut.end)
                }
            case .gap(let id):
                model.selectedCut = id
                model.selected = nil
                model.selectedSegment = nil
            case .scrub:
                model.selectSegment(at: time(p.x))
            default:
                model.selectedCut = nil
                model.selectedSegment = nil
            }
        }
        updateJoinButton()
        updateVolumeControls()
        apply(p)
        updateCursor(at: p)
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        apply(p)
        updateCursor(at: p)
    }
    override func mouseUp(with event: NSEvent) {
        apply(convert(event.locationInWindow, from: nil))
        drag = nil
        model.endEdit()
        updateJoinButton()
        updateVolumeControls()
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func apply(_ p: NSPoint) {
        let t = time(p.x)
        switch drag {
        case .start:
            let end = model.edit.retainedRanges.first?.upperBound ?? model.edit.end
            model.edit.start = min(t, end - min(0.05, end - model.edit.start))
            model.selectSegment(at: model.edit.start)
            model.seek(model.edit.start)
            edited = true
        case .end:
            let start = model.edit.retainedRanges.last?.lowerBound ?? model.edit.start
            model.edit.end = max(t, start + min(0.05, model.edit.end - start))
            model.selectedSegment = model.edit.retainedRanges.last
            model.selectedCut = nil
            model.selected = nil
            model.seek(model.edit.end)
            edited = true
        case .scrub: model.seek(t)
        case .point(let id):
            if let index = model.edit.points.firstIndex(where: { $0.id == id }) {
                let sorted = model.edit.points.sorted { $0.time < $1.time }
                let ordinal = sorted.firstIndex(where: { $0.id == id })!
                let lower = ordinal > 0 ? sorted[ordinal - 1].time + 0.001 : 0
                let upper = ordinal + 1 < sorted.count ? sorted[ordinal + 1].time - 0.001 : model.edit.duration
                model.edit.points[index].time = min(upper, max(lower, t))
                model.edit.points[index].speed = speed(p.y)
                model.seek(model.edit.points[index].time)
                edited = true
            }
        case .cutStart(let id), .cutEnd(let id):
            let left: Bool
            if case .cutStart = drag { left = true } else { left = false }
            if let cut = model.edit.cuts.first(where: { $0.id == id }),
               abs(t - cutDragOffset - (left ? cut.start : cut.end)) > 0.000000001 {
                model.prepareCutHandle(id, left: left)
            }
            if let index = model.edit.cuts.firstIndex(where: { $0.id == id }) {
                switch drag {
                case .cutStart:
                    let start = model.selectedSegment?.lowerBound ?? model.edit.start
                    let minimum = min(0.05, (model.selectedSegment?.upperBound ?? model.edit.end) - start)
                    model.edit.cuts[index].trimLeft(to: max(start + minimum, t - cutDragOffset), duration: model.edit.duration)
                    model.focusCutSegment(id, left: true)
                case .cutEnd:
                    let end = model.selectedSegment?.upperBound ?? model.edit.end
                    let minimum = min(0.05, end - (model.selectedSegment?.lowerBound ?? model.edit.start))
                    model.edit.cuts[index].trimRight(to: min(end - minimum, t - cutDragOffset), duration: model.edit.duration)
                    model.focusCutSegment(id, left: false)
                default: break
                }
                edited = true
            }
        case .gap, nil: break
        }
        // Keep the readout live while dragging, defer expensive rendering to mouse-up.
        if edited { model.updateDuration() }
        needsDisplay = true
    }
}
