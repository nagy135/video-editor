import AppKit
import VideoEditorCore

@MainActor
final class VideoTimelineView: NSView {
    private let model: VideoEditorModel
    private enum Drag { case start, end, scrub, point(UUID), cutStart(UUID), cutEnd(UUID), cutMove(UUID, Double, Double, Double) }
    private var drag: Drag?
    private var edited = false
    private var cutDragOffset = 0.0
    // Put the two handles inside their respective clips so an untouched split
    // exposes both handles without deleting any source frames.
    private func cutHandle(_ cut: VideoCut, left: Bool) -> NSRect {
        NSRect(x: left ? x(cut.start) - 10 : x(cut.end) + 1,
               y: strip.minY - 3, width: 9, height: strip.height + 6)
    }
    private var cursorTracking: NSTrackingArea?
    private var speedSpan = 9.0
    private var timeZoom = 1.0
    private var visibleStart = 0.0
    private var resetToken = 0
    private let timeScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 12))
    private var accessibilityViewport = ""
    private var visibleDuration: Double { model.edit.duration / timeZoom }
    private var visibleEnd: Double { visibleStart + visibleDuration }
    private var graph: NSRect { NSRect(x: 38, y: 8, width: max(1, bounds.width - 54), height: 112) }
    private var strip: NSRect { NSRect(x: graph.minX, y: 142, width: graph.width, height: 42) }
    override var isFlipped: Bool { true }

    init(model: VideoEditorModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel("Speed curve, trim and cut timeline")
        timeScroller.controlSize = .small
        timeScroller.scrollerStyle = .legacy
        timeScroller.target = self
        timeScroller.action = #selector(scrollTime)
        timeScroller.isHidden = true
        addSubview(timeScroller)
        toolTip = "Scroll over the graph to zoom toward 1×; scroll over the filmstrip to zoom in time. Scroll sideways or use the scrollbar to pan. Click above the filmstrip to add speed points from 1× to 10×. Drag filmstrip ends to trim; drag inside to scrub. Press C to split the blue filmstrip. Drag the left handle left or the right handle right to trim away from the split; U restores the selected cut."
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
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateScroller()
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
        let value = String(format: "Speed 1×–%.3g×; time %.2f–%.2f seconds", 1 + speedSpan, visibleStart, visibleEnd)
        if accessibilityViewport != value {
            accessibilityViewport = value
            setAccessibilityValue(value)
        }
    }

    private func viewportChanged() {
        model.viewportZoomed = timeZoom > 1.00001 || speedSpan < 8.99999
        updateScroller()
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
        if p.y < 132 {
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
        if p.y >= 132, event.modifierFlags.contains(.shift) || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
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
        if p.y < 132 {
            if let point = model.edit.points.filter({ $0.speed <= 1 + speedSpan && $0.time >= visibleStart && $0.time <= visibleEnd }).min(by: {
                hypot(x($0.time) - p.x, y($0.speed) - p.y) < hypot(x($1.time) - p.x, y($1.speed) - p.y)
            }), (hypot(x(point.time) - p.x, y(point.speed) - p.y) < 14 || abs(point.time - time(p.x)) < 0.002) {
                return .point(point.id)
            }
            return nil // Empty graph space creates a point.
        }
        guard p.y >= strip.minY - 4, p.y <= strip.maxY + 4 else { return nil }
        let cuts = model.edit.cuts.sorted {
            ($0.id == model.selectedCut ? 1 : 0) < ($1.id == model.selectedCut ? 1 : 0)
        }
        for cut in cuts.reversed() {
            if cutHandle(cut, left: true).contains(p) { return .cutStart(cut.id) }
            if cutHandle(cut, left: false).contains(p) { return .cutEnd(cut.id) }
            if p.x >= x(cut.start), p.x <= x(cut.end) {
                return .cutMove(cut.id, time(p.x), cut.start, cut.end)
            }
        }
        if abs(p.x - x(model.edit.start)) < 12 { return .start }
        if abs(p.x - x(model.edit.end)) < 12 { return .end }
        return .scrub
    }

    private func updateCursor(at p: NSPoint) {
        guard !model.loading, !model.saving, model.edit.duration > 0 else { NSCursor.arrow.set(); return }
        if let drag {
            switch drag {
            case .start, .end, .cutStart, .cutEnd: NSCursor.resizeLeftRight.set()
            case .point, .scrub, .cutMove: NSCursor.closedHand.set()
            }
            return
        }
        guard bounds.contains(p) else { NSCursor.arrow.set(); return }
        switch interaction(at: p) {
        case .start, .end, .cutStart, .cutEnd: NSCursor.resizeLeftRight.set()
        case .point, .scrub, .cutMove: NSCursor.openHand.set()
        case nil: NSCursor.crosshair.set()
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
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        if drag == nil { NSCursor.arrow.set() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
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
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            border.stroke()
        }
        for cut in model.edit.cuts {
            let gap = NSRect(x: x(cut.start) - 1, y: strip.minY - 3,
                             width: max(2, x(cut.end) - x(cut.start) + 2), height: strip.height + 6)
            NSColor.windowBackgroundColor.setFill()
            gap.fill()
            for left in [true, false] {
                let handle = cutHandle(cut, left: left)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
                if cut.id == model.selectedCut {
                    NSColor.labelColor.setStroke()
                    NSBezierPath(roundedRect: handle.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
                }
                NSColor.white.setFill()
                NSRect(x: handle.midX - 0.5, y: strip.midY - 6, width: 1, height: 12).fill()
            }
        }
        for t in [model.edit.start, model.edit.end] {
            let handle = NSRect(x: x(t) - 5, y: strip.minY - 3, width: 10, height: strip.height + 6)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
            NSColor.white.setFill()
            NSRect(x: x(t) - 1, y: strip.midY - 6, width: 2, height: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: graph.minX, y: graph.minY, width: graph.width, height: strip.maxY - graph.minY + 3)).addClip()
        NSColor.labelColor.setStroke()
        let playhead = NSBezierPath()
        playhead.move(to: NSPoint(x: x(model.position), y: graph.minY))
        playhead.line(to: NSPoint(x: x(model.position), y: strip.maxY + 3))
        playhead.lineWidth = 1
        playhead.stroke()
        NSGraphicsContext.restoreGraphicsState()
        for index in 0...4 {
            let t = visibleStart + visibleDuration * Double(index) / 4
            let text = String(format: visibleDuration < 5 ? "%.2fs" : "%.1fs", t)
            text.draw(at: NSPoint(x: min(graph.maxX - 30, x(t)), y: 125), withAttributes: labelAttributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !model.loading, !model.saving else { return }
        model.pause()
        let p = convert(event.locationInWindow, from: nil)
        edited = false
        cutDragOffset = 0
        if p.y < 132 {
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
            case .cutStart(let id), .cutEnd(let id), .cutMove(let id, _, _, _):
                model.selectedCut = id
                model.selected = nil
                if let cut = model.edit.cuts.first(where: { $0.id == id }) {
                    switch drag {
                    case .cutStart: cutDragOffset = time(p.x) - cut.start
                    case .cutEnd: cutDragOffset = time(p.x) - cut.end
                    default: break
                    }
                }
            default: model.selectedCut = nil
            }
        }
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
        if edited { model.changed() }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func apply(_ p: NSPoint) {
        let t = time(p.x)
        switch drag {
        case .start:
            model.edit.start = min(t, model.edit.end - min(0.05, model.edit.duration))
            model.seek(model.edit.start)
            edited = true
        case .end:
            model.edit.end = max(t, model.edit.start + min(0.05, model.edit.duration))
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
        case .cutStart(let id), .cutEnd(let id), .cutMove(let id, _, _, _):
            if let index = model.edit.cuts.firstIndex(where: { $0.id == id }) {
                switch drag {
                case .cutStart:
                    model.edit.cuts[index].trimLeft(to: t - cutDragOffset, duration: model.edit.duration)
                case .cutEnd:
                    model.edit.cuts[index].trimRight(to: t - cutDragOffset, duration: model.edit.duration)
                case .cutMove(_, let anchor, let start, let end):
                    let delta = min(model.edit.duration - end, max(-start, t - anchor))
                    let splitOffset = model.edit.cuts[index].split - model.edit.cuts[index].start
                    model.edit.cuts[index].start = start + delta
                    model.edit.cuts[index].end = end + delta
                    model.edit.cuts[index].split = start + delta + splitOffset
                default: break
                }
                edited = true
            }
        case nil: break
        }
        // Keep the readout live while dragging, defer expensive rendering to mouse-up.
        if edited { model.updateDuration() }
        needsDisplay = true
    }
}
