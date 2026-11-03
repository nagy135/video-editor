import Foundation

/// Delay the first prompt briefly so a deliberate quick QQ quits without flashing
/// a dialog. A held key cannot confirm: the event handler filters key repeats.
@MainActor
final class QuitShortcut {
    private(set) var isArmed = false
    private var promptTask: Task<Void, Never>?
    private let showPrompt: () -> Void
    private let dismissPrompt: () -> Void
    private let quit: () -> Void

    init(showPrompt: @escaping () -> Void, dismissPrompt: @escaping () -> Void, quit: @escaping () -> Void) {
        self.showPrompt = showPrompt
        self.dismissPrompt = dismissPrompt
        self.quit = quit
    }

    func pressQ() {
        if isArmed {
            cancel()
            quit()
            return
        }
        isArmed = true
        promptTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard let self, self.isArmed else { return }
            self.showPrompt()
        }
    }

    func cancel() {
        promptTask?.cancel()
        promptTask = nil
        isArmed = false
        dismissPrompt()
    }
}
