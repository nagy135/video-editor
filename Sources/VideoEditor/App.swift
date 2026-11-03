import AppKit

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
final class EditorAppDelegate: NSObject, NSApplicationDelegate {
    private let paths: [String]
    private var editors: [UUID: VideoEditor] = [:]
    private var welcome: WelcomeWindow?

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
            else if self.editors.isEmpty { self.showWelcome() }
        }
    }

    private func open(_ url: URL) {
        let id = UUID()
        welcome?.window?.orderOut(nil)
        editors[id] = VideoEditor(url: url) { [weak self] in
            guard let self else { return }
            self.editors[id] = nil
            if self.editors.isEmpty { self.showWelcome() }
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
        showWelcome()
        welcome?.pasteVideo()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach { open($0) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        editors.values.forEach { $0.prepareForTermination() }
    }
}
