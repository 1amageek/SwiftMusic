import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileSidebarView: View {
    @Bindable var model: SessionModel
    @Bindable var browser: SessionFileBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FILES").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5)
                Spacer()
                Button(action: chooseFolder) { Image(systemName: "folder.badge.plus") }.help("Open Folder")
                    .accessibilityLabel("Open Folder")
                Button(action: newSession) { Image(systemName: "doc.badge.plus") }.help("New Session")
                    .accessibilityLabel("New Session")
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(14)
            if let directory = browser.directory {
                HStack(spacing: 6) {
                    Button { perform { try browser.load(directory.deletingLastPathComponent()) } } label: {
                        Image(systemName: "chevron.up")
                    }.help("Parent Folder").accessibilityLabel("Parent Folder")
                    Text(directory.lastPathComponent).lineLimit(1).help(directory.path)
                    Spacer(minLength: 0)
                    Button { perform { try browser.load(directory) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("Refresh Files").accessibilityLabel("Refresh Files")
                }.font(.system(size: 10)).buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 10)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(browser.entries) { entry in
                            Button { open(entry) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.isDirectory ? "folder" : "swift")
                                        .foregroundStyle(entry.isDirectory ? Color.secondary : .orange)
                                    Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    if model.fileURL?.standardizedFileURL == entry.url.standardizedFileURL && model.hasUnsavedChanges {
                                        Circle().fill(.orange).frame(width: 4, height: 4)
                                    }
                                }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                    .background(model.fileURL?.standardizedFileURL == entry.url.standardizedFileURL
                                        ? Color.mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).help(entry.url.path)
                        }
                        if browser.entries.isEmpty { Text("No Swift files").font(.caption).foregroundStyle(.secondary).padding(12) }
                    }.padding(6)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your sessions,\none folder away.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Open Folder…", action: chooseFolder).controlSize(.small)
                }.padding(14)
                Spacer()
            }
            if let error = browser.errorMessage {
                Text((browser.directory == nil ? "" : "Listing may be out of date.\n") + error)
                    .font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled).padding(12)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
            .background(Color(red: 0.045, green: 0.055, blue: 0.065))
            .accessibilityIdentifier("file-sidebar")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = browser.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try browser.load(url) }
    }

    private func open(_ entry: SessionFileBrowser.Entry) {
        if entry.isDirectory { perform { try browser.load(entry.url) }; return }
        guard model.fileURL?.standardizedFileURL != entry.url.standardizedFileURL else { return }
        perform { try model.openDocument(at: entry.url) }
    }

    private func newSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.swiftSource]
        panel.nameFieldStringValue = "Session.swift"
        panel.directoryURL = browser.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try browser.create(at: url, source: SessionModel.initialSource)
            do { try model.openDocument(at: url) }
            catch { browser.errorMessage = "Created \(url.lastPathComponent), but could not open it: \(error.localizedDescription)"; return }
            try browser.load(url.deletingLastPathComponent())
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { browser.errorMessage = error.localizedDescription }
    }
}
