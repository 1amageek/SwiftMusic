import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: SessionModel?
    private var discardConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.windows.first?.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.confirmAllDocuments() != false else { return false }
        discardConfirmed = true
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard discardConfirmed || model?.confirmAllDocuments() != false else { return .terminateCancel }
        Task {
            do { try await model?.shutdown() }
            catch { NSLog("MusicPlaygournd scratch cleanup failed: %@", error.localizedDescription) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
