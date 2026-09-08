import Foundation
import Observation

@MainActor @Observable
final class SessionFileBrowser {
    struct Entry: Identifiable, Equatable {
        let url: URL
        let isDirectory: Bool
        var id: URL { url }
    }

    enum Failure: LocalizedError {
        case notDirectory
        case unreadableDirectory(String)
        case creationFailed(String)
        case fileExists
        case tooManyEntries
        case invalidSessionName

        var errorDescription: String? {
            switch self {
            case .notDirectory: "Choose a local folder."
            case .unreadableDirectory(let reason): "The folder could not be read: \(reason)"
            case .creationFailed(let reason): "The session could not be created: \(reason)"
            case .fileExists: "A file already exists at this destination."
            case .tooManyEntries: "This folder exceeds the 4096-entry limit. Choose a smaller folder."
            case .invalidSessionName: "A session must use the .swift extension."
            }
        }
    }

    static let maximumEntries = 4096
    private(set) var directory: URL?
    private(set) var entries: [Entry] = []
    var errorMessage: String?

    func load(_ url: URL) throws(Failure) {
        do {
            guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw Failure.notDirectory
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]
            var failure: Error?
            guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                errorHandler: { _, error in failure = error; return false }) else {
                throw Failure.unreadableDirectory("Directory enumeration is unavailable.")
            }
            var loaded: [Entry] = []
            var count = 0
            for case let child as URL in iterator {
                count += 1
                guard count <= Self.maximumEntries else { throw Failure.tooManyEntries }
                let values = try child.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true, values.isHidden != true else { continue }
                let isDirectory = values.isDirectory == true
                if isDirectory || (values.isRegularFile == true && child.pathExtension.lowercased() == "swift") {
                    loaded.append(Entry(url: child, isDirectory: isDirectory))
                }
            }
            if let failure { throw failure }
            loaded.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            directory = url.standardizedFileURL
            entries = loaded
            errorMessage = nil
        } catch {
            let failure = (error as? Failure) ?? .unreadableDirectory(error.localizedDescription)
            errorMessage = failure.localizedDescription
            throw failure
        }
    }

    func create(at url: URL, source: String) throws(Failure) {
        guard url.isFileURL, url.pathExtension.lowercased() == "swift" else { throw Failure.invalidSessionName }
        do { try Data(source.utf8).write(to: url, options: .withoutOverwriting) }
        catch let error as CocoaError where error.code == .fileWriteFileExists { throw .fileExists }
        catch { throw .creationFailed(error.localizedDescription) }
    }
}
