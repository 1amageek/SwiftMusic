import AppKit
import MusicPlaygourndCore
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class SessionModel {
    var source = SessionModel.initialSource
    var bpm = 120.0 {
        didSet {
            guard bpm.isFinite, (40...240).contains(bpm) else {
                bpm = oldValue
                diagnostic = "Tempo must be between 40 and 240 BPM."
                return
            }
            do { try engine?.setPlaybackRate(Float(bpm / 120)) }
            catch { bpm = oldValue; diagnostic = error.localizedDescription }
        }
    }
    var lowPass = 20_000.0 {
        didSet {
            do { try engine?.setLowPass(cutoff: lowPass >= 19_999 ? nil : Float(lowPass)) }
            catch { lowPass = oldValue; diagnostic = error.localizedDescription }
        }
    }
    var delayMix = 0.0 {
        didSet {
            do { try engine?.setDelay(mix: Float(delayMix)) }
            catch { delayMix = oldValue; diagnostic = error.localizedDescription }
        }
    }
    var reverbMix = 0.0 {
        didSet {
            do { try engine?.setReverb(mix: Float(reverbMix)) }
            catch { reverbMix = oldValue; diagnostic = error.localizedDescription }
        }
    }
    var outputSamples = [Float](repeating: 0, count: 4096)
    var beatsPerBar = 4
    var diagnostic = ""
    var status = "Ready to play"
    var isPreparing = false
    var isPlaying = false
    private(set) var isRecording = false
    private(set) var isExportingStems = false
    private var stemExportTask: Task<StemExportSnapshot, Error>?
    private var stemExportID = UUID()
    private var isShuttingDown = false
    var loop: PreparedLoop?
    var beatPosition = 0.0
    var currentRevision: UInt64?
    var revision: UInt64 = 0
    var selectionLine: Int?
    var selectionToken = 0
    var fileURL: URL?
    var hasUnsavedChanges = false
    var inlineLayout = true
    var bottomLayout = false
    var audioError = ""
    var completionStatus = ""
    var rowLines: [Int: Int] = [:]
    var resultLines: [Int: Int] = [:]
    var spectrum = [Float](repeating: -90, count: SpectrumAnalyzer.bandCount)
    private var lineMaps: [UInt64: SourceLineMap] = [:]
    private var analyzer: SpectrumAnalyzer?
    private var engine: AudioLoopEngine?
    private var midiService: (any MIDIServiceProtocol)?
    private(set) var midiRoute = MIDISessionRoute.disabled
    private(set) var midiSnapshot: MIDIServiceSnapshot?
    private var midiSchedulingTask: Task<Void, Never>?
    private var midiConfigurationInProgress = false
    private var midiClosed = false
    private var lastMIDICommandGeneration: UInt64 = 0
    private var lastMIDIHealth: MIDIClockHealth?
    private let evaluator: SourceEvaluator
    private let completionService: SwiftCompletionService
    private var evaluationTask: Task<Void, Never>?
    private var wantsPlayback = false
    private(set) var controlCatalog: LiveControlCatalog?
    private(set) var controlsAvailable = false
    private(set) var overrideGeneration: UInt64 = 0
    private var candidateCatalogs: [UInt64: LiveControlCatalog] = [:]
    private var overrides: [LiveControlAddress: LiveControlValue] = [:]
    private var lastRenderedGeneration: UInt64 = 0
    private var lastRenderedOverrides: [LiveControlAddress: LiveControlValue] = [:]
    private var requestedGeneration: UInt64 = 0
    private var controlTask: Task<Void, Never>?
    private var adoptionTask: Task<Void, Never>?
    private var controlHealthTask: Task<Void, Never>?
    private var lastControlHealthCheck = ContinuousClock.now

    init() {
        let bundle = Bundle.main
        let package = bundle.resourceURL?.appending(path: "SwiftMusic/MusicPlaygournd")
        let sourcePackage = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let packageURL = package.flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "Package.swift").path) ? $0 : nil } ?? sourcePackage
        // ponytail: per-process compiler cache; persist a versioned cache if cold-start cost dominates.
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MusicPlaygournd/Evaluation-\(ProcessInfo.processInfo.processIdentifier)")
        let swift = bundle.object(forInfoDictionaryKey: "SwiftExecutable") as? String ?? "/usr/bin/swift"
        evaluator = SourceEvaluator(packageURL: packageURL, workspace: cache, swiftExecutable: swift)
        completionService = SwiftCompletionService(packageURL: packageURL,
            workspace: cache.deletingLastPathComponent().appending(path: "Completion-\(ProcessInfo.processInfo.processIdentifier)"),
            sourceKitLSPExecutable: URL(fileURLWithPath: swift).deletingLastPathComponent().appending(path: "sourcekit-lsp").path)
        do { analyzer = try SpectrumAnalyzer() }
        catch { diagnostic = "Spectrum analyzer could not initialize: \(error)" }
        do { engine = try AudioLoopEngine() }
        catch { audioError = error.localizedDescription; diagnostic = audioError }
    }

    init(evaluator: SourceEvaluator, completionService: SwiftCompletionService, engine: AudioLoopEngine,
         midiService: (any MIDIServiceProtocol)? = nil) {
        self.evaluator = evaluator
        self.completionService = completionService
        self.engine = engine
        self.midiService = midiService
        do { analyzer = try SpectrumAnalyzer() }
        catch { diagnostic = "Spectrum analyzer could not initialize: \(error)" }
    }

    func completions(source: String, utf16Offset: Int) async throws -> [SwiftCompletion] {
        try await completionService.completions(source: source, utf16Offset: utf16Offset)
    }

    func sourceChanged() {
        hasUnsavedChanges = true
        updateRowLines()
        scheduleEvaluation()
    }

    func scheduleEvaluation(immediate: Bool = false) {
        refresh()
        evaluationTask?.cancel()
        guard revision < UInt64.max else { diagnostic = "Revision limit reached. Reopen the app."; return }
        revision += 1
        let requested = revision
        lineMaps = lineMaps.filter { $0.key == currentRevision }
        engine?.beginUpdate(revision: requested)
        // Reconcile adoption after atomically clearing pending audio: a bar may have
        // adopted the previous candidate between the earlier snapshot and beginUpdate.
        refresh()
        let text = source
        let tempo = 120.0
        let meter = beatsPerBar
        diagnostic = ""
        isPreparing = true
        status = loop == nil ? "Preparing your first loop…" : "Preparing edit · current loop continues"
        evaluationTask = Task { [weak self, evaluator] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(650)) }
                await self?.adoptionTask?.value
                let evaluation = try await evaluator.evaluateRetained(source: text, bpm: tempo, beatsPerBar: meter, revision: requested)
                let candidate = evaluation.loop
                try Task.checkCancellation()
                guard let self, requested == self.revision else { return }
                guard let engine = self.engine else { throw EvaluationError.invalidResult(self.audioError) }
                self.lineMaps[requested] = SourceLineMap(source: text, lines: candidate.rows.flatMap { [$0.anchor?.line, $0.resultLine].compactMap { $0 } })
                self.candidateCatalogs = [requested: evaluation.catalog]
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
            overrideGeneration = snapshot.overrideGeneration
            requestedGeneration = 0
            overrides.removeAll()
            lastRenderedOverrides.removeAll()
            lastRenderedGeneration = 0
            controlTask?.cancel()
            controlsAvailable = false
            controlCatalog = nil
            adoptionTask?.cancel()
            if let adoptedRevision = snapshot.revision,
               let catalog = candidateCatalogs[adoptedRevision] {
                adoptionTask = Task { [weak self, evaluator] in
                    let adopted = await evaluator.adopt(revision: adoptedRevision)
                    let available = await evaluator.controlsAvailable(revision: adoptedRevision)
                    guard let self, self.currentRevision == adoptedRevision, !Task.isCancelled else { return }
                    guard adopted, available else {
                        self.diagnostic = "The adopted loop has no live render worker. Audio continues."
                        return
                    }
                    do {
                        self.controlCatalog = try self.catalogWithMasters(catalog, revision: adoptedRevision)
                        self.controlsAvailable = true
                    } catch { self.diagnostic = error.localizedDescription }
                }
            }
            lineMaps = lineMaps.filter { $0.key == currentRevision || $0.key == revision }
            updateRowLines()
        }
        if overrideGeneration != snapshot.overrideGeneration {
            overrideGeneration = snapshot.overrideGeneration
            loop = snapshot.loop
            updateRowLines()
        }
        if controlsAvailable, controlHealthTask == nil, let currentRevision,
           lastControlHealthCheck.duration(to: .now) >= .seconds(1) {
            lastControlHealthCheck = .now
            controlHealthTask = Task { [weak self, evaluator] in
                let available = await evaluator.controlsAvailable(revision: currentRevision)
                guard let self else { return }
                defer { self.controlHealthTask = nil }
                guard !Task.isCancelled, self.currentRevision == currentRevision else { return }
                if !available {
                    self.controlsAvailable = false
                    self.diagnostic = "The live render worker stopped. Audio continues; evaluate a new edit to restore controls."
                }
            }
        }
        if let capture = engine?.outputMeter() {
            outputSamples = capture.interleavedSamples
            if let analyzer {
                spectrum = analyzer.analyze(interleavedSamples: outputSamples,
                    sampleRate: capture.sampleRate, isPlaying: isPlaying)
            }
        }
        if !isPreparing, diagnostic.isEmpty, snapshot.revision == revision {
            status = isPlaying ? "Live · edit freely" : "Paused"
        }
    }

    /// A nil value releases this address back to its score or persistent master target.
    func setControl(_ address: LiveControlAddress, value: LiveControlValue?) throws {
        guard let currentRevision, address.revision == currentRevision else {
            throw LiveControlError.staleRevision(expected: currentRevision ?? 0, actual: address.revision)
        }
        guard controlCatalog?.descriptor(for: address) != nil else {
            throw LiveControlError.unknownAddress(address)
        }
        if address.target == .master {
            try applyMaster(address, value: value)
            return
        }
        guard controlsAvailable else { throw EvaluationError.invalidResult("Live controls are unavailable. Audio continues.") }
        guard requestedGeneration < UInt64.max else { throw EvaluationError.invalidResult("Control generation limit reached.") }
        overrides[address] = value
        requestedGeneration += 1
        let generation = requestedGeneration
        let values = overrides.map { LiveControlOverride(address: $0.key, value: $0.value) }
        controlTask?.cancel()
        controlTask = Task { [weak self, evaluator] in
            do {
                let rendered = try await evaluator.render(overrides: values, revision: currentRevision, generation: generation)
                try Task.checkCancellation()
                guard let self, self.currentRevision == currentRevision,
                      self.requestedGeneration == generation, let engine = self.engine else { return }
                try engine.replace(loop: rendered, revision: currentRevision, generation: generation)
                self.lastRenderedGeneration = generation
                self.lastRenderedOverrides = Dictionary(uniqueKeysWithValues: values.map { ($0.address, $0.value) })
                self.refresh()
            } catch is CancellationError { }
            catch {
                let available = await evaluator.controlsAvailable(revision: currentRevision)
                guard let self, self.currentRevision == currentRevision,
                      self.requestedGeneration == generation else { return }
                self.controlsAvailable = available
                self.overrides = self.lastRenderedOverrides
                self.diagnostic = error.localizedDescription
            }
        }
    }

    private func catalogWithMasters(_ catalog: LiveControlCatalog, revision: UInt64) throws -> LiveControlCatalog {
        let masters: [(LiveControlParameter, String, LiveControlBaseline)] = [
            (.playbackRate, "Master Tempo", .scalar(bpm / 120)),
            (.lowPassCutoff, "Master Filter", lowPass >= 19_999 ? .bypassed : .scalar(lowPass)),
            (.delayMix, "Master Delay", .scalar(delayMix)),
            (.reverbMix, "Master Reverb", .scalar(reverbMix))
        ]
        return try LiveControlCatalog(descriptors: catalog.descriptors + masters.map {
            LiveControlDescriptor(address: .init(revision: revision, target: .master, parameter: $0.0),
                                  label: $0.1, baseline: $0.2)
        })
    }

    private func applyMaster(_ address: LiveControlAddress, value: LiveControlValue?) throws {
        guard let engine else { throw EvaluationError.invalidResult(audioError) }
        let number: Double?
        switch value {
        case .number(let scalar):
            guard scalar.isFinite else { throw LiveControlError.invalidValue(address) }
            number = scalar
        case .bypassed:
            guard address.parameter == .lowPassCutoff else { throw LiveControlError.invalidValue(address) }
            number = nil
        case nil: number = nil
        }
        switch address.parameter {
        case .playbackRate: try engine.setPlaybackRate(Float(number ?? bpm / 120))
        case .lowPassCutoff:
            let cutoff = value == .bypassed ? nil : (number ?? (lowPass >= 19_999 ? nil : lowPass))
            try engine.setLowPass(cutoff: cutoff.map(Float.init))
        case .delayMix: try engine.setDelay(mix: Float(number ?? delayMix))
        case .reverbMix: try engine.setReverb(mix: Float(number ?? reverbMix))
        default: throw LiveControlError.unsupportedAddress(address)
        }
    }

    var activeTokens: [Int: Set<Int>] {
        guard isPlaying, let loop else { return [:] }
        var tokens: [Int: Set<Int>] = [:]
        for event in loop.events where event.gain > 0 && event.isActive(at: beatPosition, in: loop.beatCount) {
            if let index = event.patternStepIndex { tokens[event.sourceID, default: []].insert(index) }
        }
        return tokens
    }

    func beforeEdit(range: NSRange, replacement: String) {
        for key in Array(lineMaps.keys) { lineMaps[key]?.applyEdit(range: range, replacement: replacement) }
    }

    private func updateRowLines() {
        rowLines = [:]
        resultLines = [:]
        guard let loop, let currentRevision, let map = lineMaps[currentRevision] else { return }
        for row in loop.rows {
            guard let anchor = row.anchor,
                  anchor.fileID == "Session.swift" || anchor.fileID.hasSuffix("/Session.swift") else { continue }
            if let line = map.currentLine(for: anchor.line, in: source) { rowLines[row.sourceID] = line }
            if let end = row.resultLine, let result = map.currentLine(for: end, in: source) {
                resultLines[row.sourceID] = result
            }
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
            lineMaps = [:]
            rowLines = [:]
            resultLines = [:]
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

    func configureMIDI(_ route: MIDISessionRoute) async throws {
        guard !midiClosed else { throw MIDIError.serviceShutDown }
        guard !midiConfigurationInProgress else {
            throw MIDIError.invalidLoop("MIDI route configuration is already in progress")
        }
        try route.validate()
        if route == .disabled, midiService == nil { return }
        midiConfigurationInProgress = true
        defer { midiConfigurationInProgress = false }
        if midiService == nil { midiService = try CoreMIDIService() }
        guard let service = midiService else { throw MIDIError.serviceShutDown }
        let endpoints = try await service.enumerateEndpoints()
        for input in route.inputIDs {
            guard endpoints.contains(where: { $0.id == input && $0.direction == .input }) else {
                throw MIDIError.endpointNotFound(input)
            }
        }
        if let output = route.output {
            guard endpoints.contains(where: { $0.id == output && $0.direction == .output }) else {
                throw MIDIError.endpointNotFound(output)
            }
        }
        let previous = midiRoute
        midiSchedulingTask?.cancel()
        await midiSchedulingTask?.value
        midiSchedulingTask = nil
        do {
            try await applyMIDIRoute(route, replacing: previous, service: service)
            try Task.checkCancellation()
            guard !midiClosed else { throw MIDIError.serviceShutDown }
            midiRoute = route
            if previous.clockMode != route.clockMode { lastMIDICommandGeneration = 0 }
            startMIDIScheduling()
        } catch {
            let original = error
            if !midiClosed {
                do { try await applyMIDIRoute(previous, replacing: route, service: service) }
                catch {
                    diagnostic = "MIDI route failed: \(original). Restoring the previous route also failed: \(error)"
                }
                startMIDIScheduling()
            }
            throw original
        }
    }

    private func applyMIDIRoute(_ route: MIDISessionRoute, replacing previous: MIDISessionRoute,
                               service: any MIDIServiceProtocol) async throws {
        for id in previous.inputIDs.subtracting(route.inputIDs) { try await service.disconnectInput(id) }
        for id in route.inputIDs.subtracting(previous.inputIDs) { try await service.connectInput(id) }
        try await service.setOutput(route.output)
        try await service.setClockMode(route.clockMode)
    }

    private func startMIDIScheduling() {
        guard midiRoute != .disabled, !midiClosed, midiSchedulingTask == nil else { return }
        midiSchedulingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.updateMIDI()
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch is CancellationError { return }
                catch { self.diagnostic = error.localizedDescription; return }
            }
        }
    }

    /// Runs the same bounded step for the owned task and focused session tests.
    func updateMIDI(clockAnchor: PlaybackClockAnchor? = nil, hostTime: UInt64? = nil) async {
        guard let service = midiService, !midiClosed else { return }
        do {
            let anchor: PlaybackClockAnchor?
            do { anchor = try clockAnchor ?? engine?.playbackClockAnchor() }
            catch PlaybackClockError.unavailable { anchor = nil }
            await service.updateClockAnchor(anchor)
            if let anchor, anchor.isPlaying, let loop = engine?.snapshot().loop {
                let now = hostTime ?? mach_absolute_time()
                // A future presentation anchor is itself a valid scheduling origin.
                // Do not query a negative audible beat or clamp a failed conversion.
                let start = now < anchor.presentationHostTime
                    ? anchor.accumulatedBeatPosition : try anchor.beat(atHostTime: now)
                let end = start + anchor.beatsPerMinute / 60 * 0.1
                if midiRoute.sendsLoopNotes {
                    try await service.schedule(loop: loop, from: start, through: end, channel: midiRoute.channel)
                }
                if case .send = midiRoute.clockMode {
                    try await service.scheduleClock(from: start, through: end)
                }
            }
            let snapshot = await service.snapshot()
            midiSnapshot = snapshot
            applyReceivedMIDIClock(snapshot)
            if lastMIDIHealth != snapshot.clockHealth {
                lastMIDIHealth = snapshot.clockHealth
                switch snapshot.clockHealth {
                case .disconnected: diagnostic = "The selected MIDI endpoint disconnected. Audio continues."
                case .failed(let message): diagnostic = "MIDI: \(message)"
                default: break
                }
            }
        } catch is CancellationError {
            return
        } catch {
            let health = MIDIClockHealth.failed(error.localizedDescription)
            if lastMIDIHealth != health {
                lastMIDIHealth = health
                diagnostic = "MIDI: \(error.localizedDescription)"
            }
        }
    }

    private func applyReceivedMIDIClock(_ snapshot: MIDIServiceSnapshot) {
        guard case .receive = midiRoute.clockMode, let clock = snapshot.receivedClock else { return }
        if let tempo = clock.estimatedBPM, tempo.isFinite, (40...240).contains(tempo), tempo != bpm {
            bpm = tempo
        }
        guard clock.commandGeneration > lastMIDICommandGeneration else { return }
        lastMIDICommandGeneration = clock.commandGeneration
        do {
            switch clock.lastCommand {
            case .start:
                wantsPlayback = true
                if loop == nil { scheduleEvaluation(immediate: true) }
                else { try engine?.restartFromBeginning() }
            case .continue:
                wantsPlayback = true
                if loop == nil { scheduleEvaluation(immediate: true) }
                else { try engine?.play() }
            case .stop:
                wantsPlayback = false
                engine?.stop()
            default: break
            }
            refresh()
        } catch { diagnostic = error.localizedDescription }
    }

    func startRecording(to destination: URL, maximumDuration: Duration) throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard let engine else { throw MasterRecordingError.notRecording }
        try engine.startRecording(MasterRecordingRequest(destination: destination, maximumDuration: maximumDuration))
        isRecording = true
    }

    func stopRecording() async throws -> MasterRecordingResult {
        guard let engine else { throw MasterRecordingError.notRecording }
        defer { isRecording = engine.isRecording }
        return try await engine.stopRecording()
    }

    func cancelRecording() async throws {
        defer { isRecording = engine?.isRecording ?? false }
        try await engine?.cancelRecording()
    }

    func exportStems(to destination: URL) async throws -> StemExportSnapshot {
        guard !isShuttingDown else { throw CancellationError() }
        guard stemExportTask == nil else { throw EvaluationError.invalidResult("A stem export is already in progress.") }
        refresh()
        guard let currentRevision, controlsAvailable,
              lastRenderedGeneration == overrideGeneration else {
            throw EvaluationError.invalidResult("Wait for the current live controls to be adopted before exporting stems.")
        }
        let generation = overrideGeneration
        let values = lastRenderedOverrides.map { LiveControlOverride(address: $0.key, value: $0.value) }
        let task = Task { [evaluator] in
            try await evaluator.exportStems(revision: currentRevision, generation: generation,
                overrides: values, destination: destination)
        }
        let id = UUID()
        stemExportID = id
        stemExportTask = task
        isExportingStems = true
        defer {
            if stemExportID == id { stemExportTask = nil; isExportingStems = false }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancelStemExport() async throws {
        guard let task = stemExportTask else { return }
        let id = stemExportID
        task.cancel()
        defer {
            if stemExportID == id { stemExportTask = nil; isExportingStems = false }
        }
        do { _ = try await task.value }
        catch is CancellationError { return }
    }

    func shutdown() async throws {
        isShuttingDown = true
        var recordingFailure: Error?
        do { try await cancelRecording() }
        catch { recordingFailure = error; diagnostic = error.localizedDescription }
        do { try await cancelStemExport() }
        catch {
            diagnostic = recordingFailure.map { "\($0.localizedDescription)\n\(error.localizedDescription)" } ?? error.localizedDescription
            if recordingFailure == nil { recordingFailure = error }
        }
        midiClosed = true
        midiSchedulingTask?.cancel()
        await midiSchedulingTask?.value
        midiSchedulingTask = nil
        engine?.stop()
        if let midiService {
            do { await midiService.updateClockAnchor(try engine?.playbackClockAnchor()) }
            catch { diagnostic = error.localizedDescription }
            await midiService.shutdown()
        }
        evaluationTask?.cancel()
        controlTask?.cancel()
        adoptionTask?.cancel()
        controlHealthTask?.cancel()
        controlsAvailable = false
        engine?.stop()
        await evaluationTask?.value
        await controlTask?.value
        await adoptionTask?.value
        await controlHealthTask?.value
        async let completionShutdown: Void = completionService.shutdown()
        async let evaluationShutdown: Void = evaluator.shutdown()
        _ = try await (completionShutdown, evaluationShutdown)
        if let recordingFailure { throw recordingFailure }
    }

    static let initialSource = """
    import SwiftMusic

    struct Session: Music {
        var body: some Sound {
            Track("Kick") {
                Sample("kick")
                    .rhythm("x ~ x ~")
                    .gain("0.8 0.6")
            }

            Track("Hi-hat") {
                Sample("closedHat")
                    .rhythm("x [x x] x [x x]")
                    .gain("0.5 [0.2 0.4] 0.5 [0.2 0.3]")
                    .pan(0.2)
            }

            Track("Bass") {
                Synthesizer(.sine)
                    .notes("C2 ~ [Eb2 G2] G2")
                    .gain(0.4)
            }
        }
    }
    """
}
