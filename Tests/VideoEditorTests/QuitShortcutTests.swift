import Testing
@testable import VideoEditor

@MainActor
struct QuitShortcutTests {
    @Test func quickDoubleQQuitsWithoutShowingPrompt() async throws {
        var prompts = 0
        var quits = 0
        let shortcut = QuitShortcut(showPrompt: { prompts += 1 }, dismissPrompt: {}, quit: { quits += 1 })
        shortcut.pressQ()
        shortcut.pressQ()
        try await Task.sleep(for: .milliseconds(350))
        #expect(prompts == 0)
        #expect(quits == 1)
    }

    @Test func singleQPromptsAndSecondQConfirms() async throws {
        var prompts = 0
        var quits = 0
        let shortcut = QuitShortcut(showPrompt: { prompts += 1 }, dismissPrompt: {}, quit: { quits += 1 })
        shortcut.pressQ()
        try await Task.sleep(for: .milliseconds(350))
        #expect(prompts == 1)
        #expect(quits == 0)
        shortcut.pressQ()
        #expect(quits == 1)
        #expect(!shortcut.isArmed)
    }

    @Test func cancelResetsConfirmation() async throws {
        var prompts = 0
        var quits = 0
        let shortcut = QuitShortcut(showPrompt: { prompts += 1 }, dismissPrompt: {}, quit: { quits += 1 })
        shortcut.pressQ()
        shortcut.cancel()
        try await Task.sleep(for: .milliseconds(350))
        #expect(prompts == 0)
        shortcut.pressQ()
        #expect(quits == 0)
        #expect(shortcut.isArmed)
        shortcut.cancel()
    }
}
