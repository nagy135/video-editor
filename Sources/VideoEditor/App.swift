import AppKit
import VideoEditorCore

@main
struct VideoEditorApp {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print("Usage: VideoEditor [--edit-video] [video-path ...]\nWithout a path, opens the drop/open/paste window.")
            return
        }
        let paths = arguments.first == "--edit-video" ? Array(arguments.dropFirst()) : arguments
        if arguments.first == "--edit-video", paths.isEmpty {
            FileHandle.standardError.write(Data("--edit-video requires a video path\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = EditorAppDelegate(paths: paths)
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class EditorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let paths: [String]
    private var editors: [UUID: VideoEditor] = [:]
    private var welcome: WelcomeWindow?
    private var keyMonitor: Any?
    private var quitPanel: NSPanel?
    private lazy var quitShortcut = QuitShortcut(
        showPrompt: { [weak self] in self?.showQuitPrompt() },
        dismissPrompt: { [weak self] in self?.dismissQuitPrompt() },
        quit: { NSApp.terminate(nil) }
    )

    init(paths: [String]) { self.paths = paths }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let application = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Video Editor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = applicationMenu
        menu.addItem(application)
        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(openVideo), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu
        menu.addItem(file)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                if let field = event.window?.firstResponder as? NSTextView, field.isEditable { return false }
                if event.keyCode == 53, self.quitShortcut.isArmed {
                    self.quitShortcut.cancel()
                    return true
                }
                guard event.charactersIgnoringModifiers?.lowercased() == "q" else { return false }
                if !event.isARepeat { self.quitShortcut.pressQ() }
                return true
            }
            return handled ? nil : event
        }
        if paths.isEmpty, editors.isEmpty { showWelcome() }
        else { paths.forEach { open(URL(fileURLWithPath: $0)) } }
    }

    @objc private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK { panel.urls.forEach { self.open($0) } }
        }
    }

    private func open(_ url: URL) {
        let id = UUID()
        welcome?.window?.orderOut(nil)
        editors[id] = VideoEditor(url: url) { [weak self] in
            guard let self else { return }
            self.editors[id] = nil
        }
    }

    private func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindow(onOpen: { [weak self] in self?.openVideo() }, onImport: { [weak self] urls in
                urls.forEach { self?.open($0) }
            })
        }
        welcome?.present()
    }

    @objc private func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let urls = files.isEmpty ? VideoInput.paths(from: board.string(forType: .string) ?? "") : files
        guard !urls.isEmpty, urls.allSatisfy(VideoInput.isVideo) else {
            if let welcome, welcome.window?.isVisible == true { welcome.pasteVideo() }
            else { NSSound.beep() }
            return
        }
        urls.forEach { open($0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    private func showQuitPrompt() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 150),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Quit Video Editor"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let title = NSTextField(labelWithString: "Press Q again to discard and quit")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let hint = NSTextField(labelWithString: "Unsaved edits will be discarded. Esc cancels.")
        hint.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelQuit))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let quit = NSButton(title: "Discard and Quit", target: self, action: #selector(confirmQuit))
        quit.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, quit])
        buttons.spacing = 10
        let stack = NSStackView(views: [title, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
        quitPanel = panel
        if let parent = NSApp.keyWindow { parent.beginSheet(panel) }
        else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }

    private func dismissQuitPrompt() {
        guard let panel = quitPanel else { return }
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.orderOut(nil)
        quitPanel = nil
    }

    @objc private func cancelQuit() { quitShortcut.cancel() }
    @objc private func confirmQuit() { quitShortcut.pressQ() }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === quitPanel { quitShortcut.cancel() }
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach { open($0) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        quitShortcut.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        editors.values.forEach { $0.prepareForTermination() }
    }
}
