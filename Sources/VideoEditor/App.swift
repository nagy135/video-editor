import AppKit

@main
struct VideoEditorApp {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print("Usage: VideoEditor [--edit-video] [video-path ...]\nWithout a path, opens a file picker.")
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
        NSApp.mainMenu = menu
        if paths.isEmpty { openVideo() }
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
            else if self.editors.isEmpty { NSApp.terminate(nil) }
        }
    }

    private func open(_ url: URL) {
        let id = UUID()
        editors[id] = VideoEditor(url: url) { [weak self] in self?.editors[id] = nil }
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach { open($0) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        editors.values.forEach { $0.prepareForTermination() }
    }
}
