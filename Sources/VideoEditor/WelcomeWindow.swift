import AppKit
import UniformTypeIdentifiers
import VideoEditorCore

@MainActor
final class WelcomeWindow: NSWindowController {
    private let landing: WelcomeView

    init(onOpen: @escaping () -> Void, onImport: @escaping ([URL]) -> Void) {
        landing = WelcomeView(onOpen: onOpen, onImport: onImport)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Video Editor"
        window.isReleasedWhenClosed = false
        window.contentView = landing
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(landing)
        NSApp.activate(ignoringOtherApps: true)
    }
    func pasteVideo() { landing.paste(nil) }
}

@MainActor
private final class WelcomeButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor
private final class WelcomeView: NSView {
    private let onOpen: () -> Void
    private let onImport: ([URL]) -> Void
    private let message = NSTextField(wrappingLabelWithString: "")
    private var highlighted = false { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }

    init(onOpen: @escaping () -> Void, onImport: @escaping ([URL]) -> Void) {
        self.onOpen = onOpen
        self.onImport = onImport
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .URL, .string])
        setAccessibilityLabel("Open a video by dropping a file, opening a file picker, or pasting a file or path")

        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Video Editor")
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let heading = NSTextField(labelWithString: "Drop a video")
        heading.font = .systemFont(ofSize: 26, weight: .semibold)
        let hint = NSTextField(labelWithString: "or open a file or paste with ⌘V")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 13)
        let open = WelcomeButton(title: "Open Video…", target: self, action: #selector(openVideo))
        open.bezelStyle = .rounded
        open.controlSize = .large
        let paste = WelcomeButton(title: "Paste", target: self, action: #selector(paste(_:)))
        paste.bezelStyle = .rounded
        paste.controlSize = .large
        let buttons = NSStackView(views: [open, paste])
        buttons.spacing = 10
        message.textColor = .systemRed
        message.alignment = .center
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 3
        let stack = NSStackView(views: [icon, heading, hint, buttons, message])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -88),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 20, dy: 20), xRadius: 20, yRadius: 20)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            border.fill()
        }
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        border.lineWidth = highlighted ? 2 : 1
        border.setLineDash([6, 5], count: 2, phase: 0)
        border.stroke()
    }

    @objc private func openVideo() { onOpen() }
    override func mouseDown(with event: NSEvent) { onOpen() }
    @objc func paste(_ sender: Any?) { importVideos(from: .general) }

    private func urls(from board: NSPasteboard) -> [URL] {
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files }
        guard let text = board.string(forType: .string) else { return [] }
        return VideoInput.paths(from: text)
    }

    private func importVideos(from board: NSPasteboard) {
        let files = urls(from: board)
        guard !files.isEmpty else {
            message.stringValue = "Copy a video in Finder, a local path, or a file:// URL."
            return
        }
        let videos = files.filter(VideoInput.isVideo)
        guard videos.count == files.count else {
            message.stringValue = "Choose an existing video file, such as MP4, MOV, or M4V."
            return
        }
        message.stringValue = ""
        onImport(videos)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let files = urls(from: sender.draggingPasteboard)
        highlighted = !files.isEmpty && files.allSatisfy(VideoInput.isVideo)
        return highlighted ? .copy : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlighted = false }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { highlighted }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        let files = urls(from: sender.draggingPasteboard)
        guard !files.isEmpty, files.allSatisfy(VideoInput.isVideo) else { return false }
        importVideos(from: sender.draggingPasteboard)
        return true
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { highlighted = false }
}
