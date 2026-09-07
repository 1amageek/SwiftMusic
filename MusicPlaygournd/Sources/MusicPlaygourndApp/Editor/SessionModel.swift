import AppKit
import MusicPlaygourndCore
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class SessionModel {
    var source = SessionModel.initialSource
    var bpm = 120.0
    var beatsPerBar = 4
    var diagnostic = ""
    var status = "Ready to play"
    var isPreparing = false
    var isPlaying = false
    var loop: PreparedLoop?
    var beatPosition = 0.0
    var currentRevision: UInt64?
    var revision: UInt64 = 0
    var selectionLine: Int?
    var selectionToken = 0
    var fileURL: URL?
    var hasUnsavedChanges = false
    var bottomLayout = false
    var audioError = ""
    private var engine: AudioLoopEngine?
    private let evaluator: SourceEvaluator
    private var evaluationTask: Task<Void, Never>?
    private var wantsPlayback = false

    init() {
        let bundle = Bundle.main
        let package = bundle.resourceURL?.appending(path: "MusicPlaygournd")
        let sourcePackage = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let packageURL = package.flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "Package.swift").path) ? $0 : nil } ?? sourcePackage
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MusicPlaygournd/Evaluation-\(ProcessInfo.processInfo.processIdentifier)")
        let swift = bundle.object(forInfoDictionaryKey: "SwiftExecutable") as? String ?? "/usr/bin/swift"
        evaluator = SourceEvaluator(packageURL: packageURL, workspace: cache, swiftExecutable: swift)
        do { engine = try AudioLoopEngine() }
        catch { audioError = error.localizedDescription; diagnostic = audioError }
    }

    func sourceChanged() {
        hasUnsavedChanges = true
        scheduleEvaluation()
    }

    func scheduleEvaluation(immediate: Bool = false) {
        evaluationTask?.cancel()
        guard revision < UInt64.max else { diagnostic = "Revision limit reached. Reopen the app."; return }
        revision += 1
        let requested = revision
        engine?.beginUpdate(revision: requested)
        let text = source
        let tempo = bpm
        let meter = beatsPerBar
        diagnostic = ""
        isPreparing = true
        status = loop == nil ? "Preparing your first loop…" : "Preparing edit · current loop continues"
        evaluationTask = Task { [weak self, evaluator] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(650)) }
                let candidate = try await evaluator.evaluate(source: text, bpm: tempo, beatsPerBar: meter)
                try Task.checkCancellation()
                guard let self, requested == self.revision else { return }
                guard let engine = self.engine else { throw EvaluationError.invalidResult(self.audioError) }
                try engine.submit(loop: candidate, revision: requested)
                if self.wantsPlayback { try engine.play() }
                self.isPreparing = false
                self.status = "Ready · waiting for the next bar"
                self.refresh()
            } catch is CancellationError {
                // A newer revision owns the UI and pending state.
            } catch {
                guard let self, requested == self.revision else { return }
                self.isPreparing = false
                self.diagnostic = error.localizedDescription
                self.status = self.loop == nil ? "Fix the error to start" : "Edit failed · previous loop continues"
            }
        }
    }

    func togglePlayback() {
        guard let engine else { diagnostic = audioError; return }
        if isPlaying {
            wantsPlayback = false
            engine.stop()
        } else {
            wantsPlayback = true
            if loop == nil {
                scheduleEvaluation(immediate: true)
                return
            }
            do { try engine.play() }
            catch { diagnostic = error.localizedDescription; wantsPlayback = false }
        }
        refresh()
    }

    func refresh() {
        guard let snapshot = engine?.snapshot() else { return }
        isPlaying = snapshot.isPlaying
        beatPosition = snapshot.beatPosition
        if currentRevision != snapshot.revision {
            currentRevision = snapshot.revision
            loop = snapshot.loop
        }
        if !isPreparing, diagnostic.isEmpty, snapshot.revision == revision {
            status = isPlaying ? "Live · edit freely" : "Paused"
        }
    }

    func revealDiagnostic() {
        guard let range = diagnostic.range(of: #"Session\.swift:([0-9]+):"#, options: .regularExpression) else { return }
        let part = String(diagnostic[range]).split(separator: ":")
        if part.count > 1, let line = Int(part[1]) { selectionLine = line; selectionToken += 1 }
    }

    func revealTrack(_ name: String) {
        let literal = "Track(\"\(name)\""
        guard let range = source.range(of: literal) else { return }
        selectionLine = source[..<range.lowerBound].filter { $0 == "\n" }.count + 1
        selectionToken += 1
    }

    func openDocument() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.swiftSource, .plainText]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.utf8.count <= 65_536 else { throw EvaluationError.invalidSource("Source exceeds 64 KiB.") }
            source = text
            fileURL = url
            hasUnsavedChanges = false
            scheduleEvaluation(immediate: true)
        } catch { diagnostic = error.localizedDescription }
    }

    @discardableResult func saveDocument() -> Bool {
        var destination = fileURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Session.swift"
            panel.allowedContentTypes = [.swiftSource]
            guard panel.runModal() == .OK else { return false }
            destination = panel.url
        }
        guard let destination else { return false }
        do {
            try source.write(to: destination, atomically: true, encoding: .utf8)
            fileURL = destination
            hasUnsavedChanges = false
            return true
        } catch { diagnostic = error.localizedDescription; return false }
    }

    func confirmDiscard() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to your session?"
        alert.informativeText = "Your unsaved Swift code will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveDocument()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func shutdown() async throws {
        evaluationTask?.cancel()
        engine?.stop()
        await evaluationTask?.value
        try await evaluator.shutdown()
    }

    static let initialSource = """
    import SwiftMusic

    struct Session: Music {
        var body: some Sound {
            Track("Kick") {
                Sample("kick")
                    .rhythm("x ~ x ~")
                    .gain(0.8)
            }

            Track("Hi-hat") {
                Sample("closedHat")
                    .rhythm("x x x x x x x x")
                    .gain(0.3)
                    .pan(0.2)
            }

            Track("Bass") {
                Synthesizer(.sine)
                    .notes("C2 ~ Eb2 G2")
                    .gain(0.4)
            }
        }
    }
    """
}
