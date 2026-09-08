import Foundation
import Testing
@testable import MusicPlaygourndApp

@MainActor
struct SessionFileBrowserTests {
    @Test(.timeLimit(.minutes(1)))
    func directListingFiltersLinksAndKeepsFoldersFirst() throws {
        try withDirectory { root in
            let folder = root.appending(path: "Beats")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data().write(to: folder.appending(path: "Nested.swift"))
            try Data().write(to: root.appending(path: "Kick.swift"))
            try Data().write(to: root.appending(path: "Notes.txt"))
            try Data().write(to: root.appending(path: ".Hidden.swift"))
            try FileManager.default.createSymbolicLink(at: root.appending(path: "Link.swift"), withDestinationURL: root.appending(path: "Kick.swift"))
            let browser = SessionFileBrowser()
            try browser.load(root)
            #expect(browser.entries.map(\.url.lastPathComponent) == ["Beats", "Kick.swift"])
            try browser.load(folder)
            #expect(browser.entries.map(\.url.lastPathComponent) == ["Nested.swift"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedNavigationPreservesLastListingAndReportsFailure() throws {
        try withDirectory { root in
            try Data().write(to: root.appending(path: "Kick.swift"))
            let browser = SessionFileBrowser()
            try browser.load(root)
            let previous = browser.entries
            #expect { try browser.load(root.appending(path: "Missing")) } throws: { error in
                guard case SessionFileBrowser.Failure.unreadableDirectory = error else { return false }
                return true
            }
            #expect(browser.directory == root.standardizedFileURL)
            #expect(browser.entries == previous)
            #expect(browser.errorMessage != nil)
            try browser.load(root)
            #expect(browser.errorMessage == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func oversizedDirectoryFailsBeforePublishingPartialListing() throws {
        try withDirectory { root in
            for index in 0..<SessionFileBrowser.maximumEntries {
                try Data().write(to: root.appending(path: ".\(index).txt"))
            }
            let browser = SessionFileBrowser()
            try browser.load(root)
            #expect(browser.entries.isEmpty)
            try Data().write(to: root.appending(path: "Visible.swift"))
            #expect { try browser.load(root) } throws: { error in
                guard case SessionFileBrowser.Failure.tooManyEntries = error else { return false }
                return true
            }
            #expect(browser.directory == root.standardizedFileURL)
            #expect(browser.entries.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func creationNeverOverwritesAnExistingSession() throws {
        try withDirectory { root in
            let browser = SessionFileBrowser()
            let destination = root.appending(path: "Session.swift")
            try browser.create(at: destination, source: "original")
            #expect { try browser.create(at: destination, source: "replacement") } throws: { error in
                guard case SessionFileBrowser.Failure.fileExists = error else { return false }
                return true
            }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
            #expect(throws: SessionFileBrowser.Failure.self) {
                try browser.create(at: root.appending(path: "Session.txt"), source: "invalid")
            }
            #expect {
                try browser.create(at: root.appending(path: "Missing/New.swift"), source: "invalid")
            } throws: { error in
                guard case SessionFileBrowser.Failure.creationFailed = error else { return false }
                return true
            }
        }
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error) }
        }
        try operation(root)
    }
}
