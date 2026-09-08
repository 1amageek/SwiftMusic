import AppKit
import SwiftUI

@main
struct MusicPlaygourndApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @State private var model = SessionModel()

    var body: some Scene {
        Window("MusicPlaygournd", id: "editor") {
            ContentView(model: model)
                .onAppear { delegate.model = model; model.prepareInitialSource(); NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Session…", action: model.openDocument).keyboardShortcut("o")
                Button("Close Tab") { model.closeDocument(model.activeDocumentID) }.keyboardShortcut("w")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Session") { model.saveDocument() }.keyboardShortcut("s")
            }
            CommandMenu("Session") {
                Button("Apply Edit") { model.scheduleEvaluation(immediate: true) }.keyboardShortcut("r")
                Button("Play / Pause", action: model.togglePlayback)
                Divider()
                Button("Inline Results") { model.inlineLayout = true }
                Button("Side Timeline") { model.inlineLayout = false; model.bottomLayout = false }
                Button("Bottom Overview") { model.inlineLayout = false; model.bottomLayout = true }
            }
        }
    }
}
