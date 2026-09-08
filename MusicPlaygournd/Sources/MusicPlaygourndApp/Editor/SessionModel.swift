import AppKit
import MusicPlaygourndCore
import Observation
import SwiftMusic
import UniformTypeIdentifiers

@MainActor @Observable
final class SessionModel {
    static let maximumOpenDocuments = 32
    private(set) var documents = [SessionDocument(source: SessionModel.initialSource)]
    private var activeDocumentIndex = 0
    var activeDocument: SessionDocument { documents[activeDocumentIndex] }
    var activeDocumentID: UUID { activeDocument.id }
    private var revisionDocuments: [UInt64: UUID] = [:]
    var audibleDocumentID: UUID? { currentRevision.flatMap { revisionDocuments[$0] } }
    var editorLoop: PreparedLoop? { audibleDocumentID == activeDocumentID ? loop : nil }
    var source: String {
        get { activeDocument.source }
        set { activeDocument.source = newValue; diagnosticRange = nil }
    }
    private var masterBPM = 120.0
    var bpm: Double {
        get { performanceBPMControlID.flatMap { performanceNumber($0) } ?? masterBPM }
        set {
            guard newValue.isFinite, (40...240).contains(newValue) else {
                diagnostic = "Tempo must be between 40 and 240 BPM."
                return
            }
            if let performanceBPMControlID {
                do { try setPerformanceValue(performanceBPMControlID, value: .double(newValue)) }
                catch { diagnostic = error.localizedDescription }
                return
            }
            masterBPM = newValue
            do {
                try engine?.setPlaybackRate(Float(newValue / (loop?.bpm ?? 120)))
                masterControlValues.removeValue(forKey: .playbackRate)
            } catch { diagnostic = error.localizedDescription }
        }
    }
    var lowPass = 20_000.0 {
        didSet {
            do { try engine?.setLowPass(cutoff: lowPass >= 19_999 ? nil : Float(lowPass)); masterControlValues.removeValue(forKey: .lowPassCutoff) }
            catch { lowPass = oldValue; diagnostic = error.localizedDescription }
        }
    }
    var delayMix = 0.0 {
        didSet {
            do { try engine?.setDelay(mix: Float(delayMix)); masterControlValues.removeValue(forKey: .delayMix) }
            catch { delayMix = oldValue; diagnostic = error.localizedDescription }
        }
    }
    var reverbMix = 0.0 {
        didSet {
            do { try engine?.setReverb(mix: Float(reverbMix)); masterControlValues.removeValue(forKey: .reverbMix) }
            catch { reverbMix = oldValue; diagnostic = error.localizedDescription }
        }
    }
    var outputSamples = [Float](repeating: 0, count: 4096)
    var beatsPerBar = 4
    var diagnostic = "" { didSet { diagnosticRange = nil } }
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
    var selectionRange: NSRange?
    private(set) var diagnosticRange: NSRange?
    private(set) var completionSites: [EditorSemanticMetadata.SampleCompletionSite] = []
    private var completionSource = ""
    private var candidateMetadata: [UInt64: EditorSemanticMetadata] = [:]
    var selectionToken = 0
    var fileURL: URL? {
        get { activeDocument.fileURL }
        set { activeDocument.fileURL = newValue }
    }
    var hasUnsavedChanges: Bool {
        get { activeDocument.isDirty }
        set { activeDocument.isDirty = newValue }
    }
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
    private(set) var candidateCatalogs: [UInt64: LiveControlCatalog] = [:]
    private(set) var performanceControlMetadata: [PerformanceControlMetadata] = []
    private(set) var performanceValues: [String: PerformanceControlValue] = [:]
    private(set) var candidatePerformanceControls: [UInt64: [PerformanceControlMetadata]] = [:]
    private(set) var candidatePerformanceTransferIssues: [UInt64: PerformanceControlError] = [:]
    private var overrides: [LiveControlAddress: LiveControlValue] = [:]
    private var lastRenderedGeneration: UInt64 = 0
    private var lastRenderedOverrides: [LiveControlAddress: LiveControlValue] = [:]
    private var requestedGeneration: UInt64 = 0
    private var controlTask: Task<Void, Never>?
    private var adoptionTask: Task<Void, Never>?
    private var controlHealthTask: Task<Void, Never>?
    private var lastControlHealthCheck = ContinuousClock.now
    var selectedControl: LiveControlAddress? {
        didSet { if oldValue != selectedControl { requestControlVisualization() } }
    }
    private(set) var controlVisualization: PreparedControlVisualization?
    private(set) var visualizationStatus = "Choose a score control to inspect its trajectories."
    private var visualizationTask: Task<Void, Never>?
    private var selectionGeneration: UInt64 = 0
    var xyX: LiveControlAddress?
    var xyY: LiveControlAddress?
    var hostDiagnostic = ""
    private(set) var learnAddress: LiveControlAddress?
    private(set) var learnedBindings: [DocumentHostStateStore.LearnBinding] = []
    private(set) var midiEndpoints: [MIDIEndpointDescriptor] = []
    private(set) var audioEffects: [HostedAudioUnitDescriptor] = []
    private(set) var hostedEffect = HostedAudioUnitSnapshot.none
    private(set) var isLoadingEffect = false
    private(set) var performance: PlaybackPerformanceSnapshot?
    private var masterControlValues: [LiveControlParameter: LiveControlValue] = [:]
    private var midiEventTask: Task<Void, Never>?
    private var effectTask: Task<Void, Error>?
    private var effectRequestID = UUID()
    private var hostRestoreTask: Task<Void, Never>?
    private var pendingHostState: DocumentHostStateStore.State?
    private var adoptedSourceDigest: String?
    private(set) var candidateSourceDigests: [UInt64: String] = [:]
    private let hostStateStore: DocumentHostStateStore
    private(set) var isRestoringHostState = false

    private struct PerformanceIntent {
        let revision: UInt64
        let generation: UInt64
        let values: [String: PerformanceControlValue]
    }

    private struct PerformanceTransaction {
        let revision: UInt64
        let generation: UInt64
        let values: [String: PerformanceControlValue]
        let evaluation: RetainedEvaluation
    }

    private var requestedPerformanceGeneration: UInt64 = 0
    private var pendingPerformanceIntent: PerformanceIntent?
    private var activePerformanceIntent: PerformanceIntent?
    private var performanceTask: Task<Void, Never>?
    private var performanceConfirmationTask: Task<Void, Never>?
    private var performanceTransaction: PerformanceTransaction?
    private var deferredEvaluation = false
    private var deferredEvaluationImmediate = false
    private var publishedPerformanceGeneration: UInt64 = 0
    private var reservedPerformanceToken: PerformanceReplacementToken?
    internal var performanceReservationDidPrepare: (() async -> Void)?
    private var requiresEvaluatorReset = false
    private var evaluatorResetTask: Task<Void, Never>?

    init() {
        hostStateStore = DocumentHostStateStore()
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
        evaluator = SourceEvaluator(packageURL: packageURL, workspace: cache, swiftExecutable: swift,
            runtimeSDK: bundle.object(forInfoDictionaryKey: "SwiftExecutable") == nil ? nil : bundle.resourceURL?.appending(path: "RuntimeSDK"))
        completionService = SwiftCompletionService(packageURL: packageURL,
            workspace: cache.deletingLastPathComponent().appending(path: "Completion-\(ProcessInfo.processInfo.processIdentifier)"),
            sourceKitLSPExecutable: URL(fileURLWithPath: swift).deletingLastPathComponent().appending(path: "sourcekit-lsp").path)
        do { analyzer = try SpectrumAnalyzer() }
        catch { diagnostic = "Spectrum analyzer could not initialize: \(error)" }
        do { engine = try AudioLoopEngine() }
        catch { audioError = error.localizedDescription; diagnostic = audioError }
    }

    init(evaluator: SourceEvaluator, completionService: SwiftCompletionService, engine: AudioLoopEngine,
         midiService: (any MIDIServiceProtocol)? = nil, hostStateStore: DocumentHostStateStore = DocumentHostStateStore()) {
        self.hostStateStore = hostStateStore
        self.evaluator = evaluator
        self.completionService = completionService
        self.engine = engine
        self.midiService = midiService
        do { analyzer = try SpectrumAnalyzer() }
        catch { diagnostic = "Spectrum analyzer could not initialize: \(error)" }
    }

    func completions(source: String, utf16Offset: Int) async throws -> [SwiftCompletion] {
        if source == self.source, source == completionSource, let site = completionSites.first(where: {
            utf16Offset >= $0.contentRange.location && utf16Offset <= NSMaxRange($0.contentRange)
        }), NSMaxRange(site.contentRange) <= source.utf16.count {
            let prefix = (source as NSString).substring(with: NSRange(location: site.contentRange.location,
                length: utf16Offset - site.contentRange.location))
            return site.values.filter { $0.hasPrefix(prefix) }.map {
                SwiftCompletion(label: $0, detail: "Sample bank", insertion: $0, replacementRange: site.contentRange)
            }
        }
        return try await completionService.completions(source: source, utf16Offset: utf16Offset)
    }

    func sourceChanged() {
        hasUnsavedChanges = true
        updateRowLines()
        scheduleEvaluation()
    }

    func scheduleEvaluation(immediate: Bool = false) {
        if requiresEvaluatorReset {
            deferredEvaluation = true
            deferredEvaluationImmediate = deferredEvaluationImmediate || immediate
            status = "Performance update in progress · edit queued"
            if performanceTask == nil { resumeDeferredEvaluationIfPossible() }
            return
        }
        if performanceTask != nil || performanceTransaction != nil || performanceConfirmationTask != nil {
            deferredEvaluation = true
            deferredEvaluationImmediate = deferredEvaluationImmediate || immediate
            status = "Performance update in progress · edit queued"
            return
        }
        refresh()
        evaluationTask?.cancel()
        guard revision < UInt64.max else { diagnostic = "Revision limit reached. Reopen the app."; return }
        revision += 1
        let requested = revision
        revisionDocuments = revisionDocuments.filter { $0.key == currentRevision || $0.key == requested - 1 }
        revisionDocuments[requested] = activeDocumentID
        lineMaps = lineMaps.filter { $0.key == currentRevision }
        engine?.beginUpdate(revision: requested)
        // Reconcile adoption after atomically clearing pending audio: a bar may have
        // adopted the previous candidate between the earlier snapshot and beginUpdate.
        refresh()
        let text = source
        let tempo = 120.0
        let meter = beatsPerBar
        diagnostic = ""
        diagnosticRange = nil
        isPreparing = true
        status = loop == nil ? "Preparing your first loop…" : "Preparing edit · current loop continues"
        evaluationTask = Task { [weak self, evaluator] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(150)) }
                await self?.adoptionTask?.value
                let evaluation = try await evaluator.evaluateRetained(source: text, bpm: tempo, beatsPerBar: meter, revision: requested)
                let candidate = evaluation.loop
                try Task.checkCancellation()
                guard let self, requested == self.revision else { return }
                guard let engine = self.engine else { throw EvaluationError.invalidResult(self.audioError) }
                self.lineMaps[requested] = SourceLineMap(source: text, lines: candidate.rows.flatMap { [$0.anchor?.line, $0.resultLine].compactMap { $0 } })
                self.candidateCatalogs = [requested: evaluation.catalog]
                self.candidateMetadata = [requested: evaluation.metadata]
                self.candidatePerformanceControls = [requested: evaluation.performanceControls]
                if let issue = evaluation.performanceTransferIssue {
                    self.candidatePerformanceTransferIssues = [requested: issue]
                } else {
                    self.candidatePerformanceTransferIssues = [:]
                }
                self.candidateSourceDigests = [requested: DocumentHostStateStore.sourceDigest(text)]
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
                if case EvaluationError.compilerDiagnostic(_, let range) = error, self.source == text {
                    self.diagnosticRange = range?.utf16Range
                }
                self.status = self.loop == nil ? "Fix the error to start" : "Edit failed · previous loop continues"
            }
        }
    }

    func prepareInitialSource() {
        guard revision == 0, !isPreparing, loop == nil else { return }
        scheduleEvaluation(immediate: true)
    }

    func togglePlayback() {
        guard let engine else { diagnostic = audioError; return }
        if isPlaying {
            wantsPlayback = false
            engine.stop()
        } else {
            wantsPlayback = true
            if loop == nil {
                if !isPreparing { scheduleEvaluation(immediate: true) }
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
            hostRestoreTask?.cancel()
            currentRevision = snapshot.revision
            loop = snapshot.loop
            overrideGeneration = snapshot.overrideGeneration
            requestedGeneration = 0
            overrides.removeAll()
            lastRenderedOverrides.removeAll()
            lastRenderedGeneration = 0
            requestedPerformanceGeneration = 0
            pendingPerformanceIntent = nil
            performanceTransaction = nil
            performanceConfirmationTask?.cancel()
            performanceConfirmationTask = nil
            performanceControlMetadata = []
            performanceValues = [:]
            publishedPerformanceGeneration = snapshot.performanceGeneration
            controlTask?.cancel()
            visualizationTask?.cancel()
            controlVisualization = nil
            controlsAvailable = false
            controlCatalog = nil
            adoptionTask?.cancel()
            if let adoptedRevision = snapshot.revision,
               let catalog = candidateCatalogs[adoptedRevision] {
                let performanceControls = candidatePerformanceControls[adoptedRevision] ?? []
                let transferIssue = candidatePerformanceTransferIssues[adoptedRevision]
                adoptionTask = Task { [weak self, evaluator] in
                    let adopted = await evaluator.adopt(revision: adoptedRevision)
                    let available = await evaluator.controlsAvailable(revision: adoptedRevision)
                    guard let self, self.currentRevision == adoptedRevision, !Task.isCancelled else { return }
                    guard adopted, available else {
                        self.diagnostic = "The adopted loop has no live render worker. Audio continues."
                        return
                    }
                    do {
                        self.performanceControlMetadata = performanceControls
                        self.performanceValues = Dictionary(uniqueKeysWithValues: performanceControls.map { ($0.controlID, $0.value) })
                        self.controlCatalog = try self.catalogWithMasters(catalog, revision: adoptedRevision)
                        if self.performanceBPMControlID != nil {
                            try self.engine?.setPlaybackRate(1)
                        } else if case .number(let rate) = self.masterControlValues[.playbackRate] {
                            try self.engine?.setPlaybackRate(Float(rate))
                        } else {
                            try self.engine?.setPlaybackRate(Float(self.masterBPM / (self.loop?.bpm ?? 120)))
                        }
                        self.controlsAvailable = true
                        self.adoptedControlsDidChange(revision: adoptedRevision)
                        if let transferIssue {
                            self.hostDiagnostic = transferIssue.localizedDescription
                        }
                    } catch { self.diagnostic = error.localizedDescription }
                }
            }
            lineMaps = lineMaps.filter { $0.key == currentRevision || $0.key == revision }
            candidatePerformanceControls = candidatePerformanceControls.filter { $0.key == currentRevision || $0.key == revision }
            candidatePerformanceTransferIssues = candidatePerformanceTransferIssues.filter { $0.key == currentRevision || $0.key == revision }
            updateRowLines()
        }
        if overrideGeneration != snapshot.overrideGeneration {
            overrideGeneration = snapshot.overrideGeneration
            loop = snapshot.loop
            updateRowLines()
            requestControlVisualization()
        }
        if let transaction = performanceTransaction,
           snapshot.revision == transaction.revision,
           snapshot.performanceGeneration == transaction.generation,
           performanceConfirmationTask == nil {
            let revision = transaction.revision
            let generation = transaction.generation
            performanceConfirmationTask = Task { [weak self, evaluator] in
                let confirmed = await evaluator.confirmPerformance(revision: revision, generation: generation)
                guard let self else { return }
                self.finishPerformanceConfirmation(revision: revision, generation: generation, confirmed: confirmed)
            }
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
            performance = capture.performance
            hostedEffect = engine?.audioEffectSnapshot() ?? .none
            if let analyzer {
                spectrum = analyzer.analyze(interleavedSamples: outputSamples,
                    sampleRate: capture.sampleRate, isPlaying: isPlaying)
            }
        }
        if !isPreparing, diagnostic.isEmpty, snapshot.revision == revision {
            status = isPlaying ? "Live · edit freely" : "Paused"
        }
    }

    var rowMuteStates: [Int: Bool] {
        guard audibleDocumentID == activeDocumentID, controlsAvailable, !isPreparing else { return [:] }
        return Dictionary(uniqueKeysWithValues: (controlCatalog?.descriptors ?? []).compactMap { descriptor in
            guard descriptor.address.parameter == .trackMute,
                  case .track(let id) = descriptor.address.target else { return nil }
            return (id, controlValue(descriptor) == 1)
        })
    }

    func toggleTrackMute(_ id: Int) {
        guard let muted = rowMuteStates[id], let revision = currentRevision else { return }
        do {
            try setControl(.init(revision: revision, target: .track(id), parameter: .trackMute),
                           value: .number(muted ? 0 : 1))
        } catch { hostDiagnostic = error.localizedDescription }
    }

    /// A nil value releases this address back to its score or persistent master target.
    func setControl(_ address: LiveControlAddress, value: LiveControlValue?) throws {
        try setControls([address: value])
    }

    /// Applies one complete score override generation for a knob or XY gesture.
    func setControls(_ updates: [LiveControlAddress: LiveControlValue?]) throws {
        guard !updates.isEmpty else { return }
        guard let currentRevision else { throw EvaluationError.invalidResult("No adopted score.") }
        for address in updates.keys {
            guard address.revision == currentRevision else {
                throw LiveControlError.staleRevision(expected: currentRevision, actual: address.revision)
            }
            guard controlCatalog?.descriptor(for: address) != nil else { throw LiveControlError.unknownAddress(address) }
        }
        if let master = updates.first(where: { $0.key.target == .master }) {
            guard updates.count == 1 else { throw LiveControlError.invalidCatalog("XY pairs require score controls.") }
            try applyMaster(master.key, value: master.value)
            masterControlValues[master.key.parameter] = master.value
            return
        }
        guard performanceTask == nil, performanceTransaction == nil,
              performanceConfirmationTask == nil else {
            throw EvaluationError.invalidResult("Wait for the performance update to become audible.")
        }
        guard controlsAvailable else { throw EvaluationError.invalidResult("Live controls are unavailable. Audio continues.") }
        guard requestedGeneration < UInt64.max else { throw EvaluationError.invalidResult("Control generation limit reached.") }
        var next = overrides
        for (address, value) in updates { next[address] = value }
        overrides = next
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
                self.controlTask = nil
                self.refresh()
            } catch is CancellationError { }
            catch {
                let available = await evaluator.controlsAvailable(revision: currentRevision)
                guard let self, self.currentRevision == currentRevision,
                      self.requestedGeneration == generation else { return }
                self.controlTask = nil
                self.controlTask = nil
                self.controlsAvailable = available
                self.overrides = self.lastRenderedOverrides
                self.diagnostic = error.localizedDescription
            }
        }
    }

    /// Applies one complete performance-model value set. The source and undo stack never change.
    func setPerformanceValue(_ controlID: String, value: PerformanceControlValue) throws {
        var values = pendingPerformanceIntent?.values ?? activePerformanceIntent?.values
            ?? performanceTransaction?.values ?? performanceValues
        guard values[controlID] != nil else { throw PerformanceControlError.unknownControl(controlID) }
        values[controlID] = value
        try requestPerformanceValues(values)
    }

    /// Applies both axes of one declared position control as one performance generation.
    func setPerformancePosition(_ controlID: String, x: Double? = nil, depth: Double? = nil) throws {
        let values = pendingPerformanceIntent?.values ?? activePerformanceIntent?.values
            ?? performanceTransaction?.values ?? performanceValues
        guard case .position(let position) = values[controlID] else {
            throw PerformanceControlError.valueTypeMismatch(controlID)
        }
        try setPerformanceValue(controlID, value: .position(SpatialPosition(
            x: x ?? position.x, depth: depth ?? position.depth)))
    }

    func performanceValue(_ controlID: String) -> PerformanceControlValue? {
        performanceValues[controlID]
    }

    func performanceNumber(_ controlID: String) -> Double? {
        guard case .double(let value) = performanceValues[controlID] else { return nil }
        return value
    }

    func performancePosition(_ controlID: String) -> SpatialPosition? {
        guard case .position(let value) = performanceValues[controlID] else { return nil }
        return value
    }

    var isPerformanceUpdating: Bool {
        performanceTask != nil || performanceTransaction != nil || performanceConfirmationTask != nil
    }

    private func requestPerformanceValues(_ values: [String: PerformanceControlValue]) throws {
        guard !isShuttingDown, !requiresEvaluatorReset else { throw CancellationError() }
        guard let revision = currentRevision, revision == self.revision, !isPreparing else {
            throw EvaluationError.invalidResult("Wait for the current score to finish loading before changing performance controls.")
        }
        guard controlsAvailable, !performanceControlMetadata.isEmpty else {
            throw EvaluationError.invalidResult("Performance controls are unavailable. Audio continues.")
        }
        guard controlTask == nil, lastRenderedGeneration == overrideGeneration else {
            throw EvaluationError.invalidResult("Wait for the current score controls to become audible.")
        }
        try PerformanceControlMetadata.validate(performanceControlMetadata.map { metadata in
            guard let value = values[metadata.controlID] else { return metadata }
            return PerformanceControlMetadata(modelID: metadata.modelID, controlID: metadata.controlID,
                label: metadata.label, domain: metadata.domain, value: value)
        })
        let knownIDs = Set(performanceControlMetadata.map(\.controlID))
        guard Set(values.keys) == knownIDs else {
            let missing = knownIDs.subtracting(values.keys).sorted().first
            let unknown = Set(values.keys).subtracting(knownIDs).sorted().first
            throw missing.map(PerformanceControlError.missingValue) ?? unknown.map(PerformanceControlError.unknownControl)
                ?? PerformanceControlError.invalidMapping("control set is incomplete")
        }
        guard requestedPerformanceGeneration < UInt64.max else {
            throw EvaluationError.invalidResult("Performance generation limit reached.")
        }
        requestedPerformanceGeneration += 1
        let intent = PerformanceIntent(revision: revision, generation: requestedPerformanceGeneration, values: values)
        pendingPerformanceIntent = intent
        if performanceTask == nil, performanceTransaction == nil {
            pendingPerformanceIntent = nil
            startPerformance(intent)
        } else {
            performanceTask?.cancel()
        }
    }

    private func startPerformance(_ intent: PerformanceIntent) {
        guard performanceTask == nil, performanceTransaction == nil else { return }
        activePerformanceIntent = intent
        status = "Rendering performance update…"
        performanceTask = Task { @MainActor [weak self] in
            await self?.runPerformance(intent)
            self?.performanceTaskFinished(intent.generation)
        }
    }

    private func runPerformance(_ intent: PerformanceIntent) async {
        guard currentRevision == intent.revision, revision == intent.revision, !isPreparing,
              let engine else { return }
        var reservedToken: PerformanceReplacementToken?
        do {
            try Task.checkCancellation()
            let scoreOverrides = lastRenderedOverrides.map { LiveControlOverride(address: $0.key, value: $0.value) }
            let rendered = try await evaluator.renderPerformance(values: intent.values,
                overrides: scoreOverrides, revision: intent.revision, generation: intent.generation)
            try Task.checkCancellation()
            guard currentRevision == intent.revision, revision == intent.revision,
                  requestedPerformanceGeneration == intent.generation else {
                await evaluator.discardPerformance(revision: intent.revision, generation: intent.generation)
                return
            }
            reservedToken = try engine.preparePerformanceReplacement(loop: rendered.loop,
                revision: intent.revision, generation: intent.generation)
            self.reservedPerformanceToken = reservedToken
            await performanceReservationDidPrepare?()
            try Task.checkCancellation()
            guard !requiresEvaluatorReset, !isShuttingDown else { throw CancellationError() }

            // Once the worker ACK is requested, cancellation cannot abandon the transaction.
            let acknowledged = await evaluator.adoptPerformance(revision: intent.revision, generation: intent.generation)
            guard let token = reservedToken else {
                await evaluator.discardPerformance(revision: intent.revision, generation: intent.generation)
                return
            }
            guard self.reservedPerformanceToken == token else {
                await evaluator.discardPerformance(revision: intent.revision, generation: intent.generation)
                return
            }
            guard acknowledged else {
                _ = engine.discardPerformanceReplacement(token)
                self.reservedPerformanceToken = nil
                await evaluator.discardPerformance(revision: intent.revision, generation: intent.generation)
                throw EvaluationError.invalidResult("The performance worker rejected the requested generation.")
            }
            guard engine.commitPerformanceReplacement(token) else {
                self.reservedPerformanceToken = nil
                controlsAvailable = false
                diagnostic = "The performance replacement reservation expired; edit the score to restore controls."
                return
            }
            self.performanceTransaction = PerformanceTransaction(revision: intent.revision,
                generation: intent.generation, values: intent.values, evaluation: rendered)
            self.status = "Performance update · waiting for fade"
            self.reservedPerformanceToken = nil
            reservedToken = nil
        } catch is CancellationError {
            if let reservedToken {
                _ = engine.discardPerformanceReplacement(reservedToken)
                if self.reservedPerformanceToken == reservedToken { self.reservedPerformanceToken = nil }
            }
            await evaluator.discardPerformance(revision: intent.revision, generation: intent.generation)
        } catch {
            if let reservedToken {
                _ = engine.discardPerformanceReplacement(reservedToken)
                if self.reservedPerformanceToken == reservedToken { self.reservedPerformanceToken = nil }
            }
            await evaluator.discardPerformance(revision: intent.revision, generation: intent.generation)
            guard currentRevision == intent.revision, revision == intent.revision,
                  requestedPerformanceGeneration == intent.generation else { return }
            diagnostic = error.localizedDescription
            if case EvaluationError.compilerDiagnostic(_, let range) = error,
               adoptedSourceDigest == DocumentHostStateStore.sourceDigest(source) {
                diagnosticRange = range?.utf16Range
            }
            status = "Performance update failed · previous loop continues"
        }
    }

    private func performanceTaskFinished(_ generation: UInt64) {
        guard activePerformanceIntent?.generation == generation else { return }
        activePerformanceIntent = nil
        performanceTask = nil
        guard performanceTransaction == nil else { return }
        guard let pending = pendingPerformanceIntent, pending.generation == requestedPerformanceGeneration else {
            resumeDeferredEvaluationIfPossible()
            return
        }
        pendingPerformanceIntent = nil
        startPerformance(pending)
    }

    private func finishPerformanceConfirmation(revision: UInt64, generation: UInt64, confirmed: Bool) {
        guard let transaction = performanceTransaction,
              transaction.revision == revision, transaction.generation == generation else { return }
        performanceConfirmationTask = nil
        guard confirmed else {
            performanceTransaction = nil
            controlsAvailable = false
            diagnostic = "The performance worker and playback snapshot disagreed; controls remain unavailable."
            status = "Performance update could not be confirmed · previous values retained"
            resumeDeferredEvaluationIfPossible()
            return
        }
        let previousLoop = loop
        let previousCatalog = controlCatalog
        let previousPerformanceControls = performanceControlMetadata
        let previousPerformanceValues = performanceValues
        let nextLoop = transaction.evaluation.loop
        let nextPerformanceControls = transaction.evaluation.performanceControls
        performanceControlMetadata = nextPerformanceControls
        performanceValues = Dictionary(uniqueKeysWithValues: nextPerformanceControls.map { ($0.controlID, $0.value) })
        let nextCatalog: LiveControlCatalog
        do {
            nextCatalog = try catalogWithMasters(transaction.evaluation.catalog, revision: revision)
        } catch {
            performanceControlMetadata = previousPerformanceControls
            performanceValues = previousPerformanceValues
            performanceTransaction = nil
            controlsAvailable = false
            diagnostic = error.localizedDescription
            status = "Performance update could not be confirmed · previous values retained"
            return
        }
        let graphChanged = !controlLayoutMatches(previousCatalog, nextCatalog)
            || !rowProvenanceMatches(previousLoop, nextLoop)
        loop = nextLoop
        if adoptedSourceDigest == DocumentHostStateStore.sourceDigest(source) {
            lineMaps[revision] = SourceLineMap(source: source,
                lines: nextLoop.rows.flatMap { [$0.anchor?.line, $0.resultLine].compactMap { $0 } })
        }
        controlCatalog = nextCatalog
        candidateCatalogs[revision] = transaction.evaluation.catalog
        candidateMetadata[revision] = transaction.evaluation.metadata
        completionSource = source
        completionSites = adoptedSourceDigest == DocumentHostStateStore.sourceDigest(source)
            ? transaction.evaluation.metadata.completionSites : []
        candidatePerformanceControls[revision] = nextPerformanceControls
        candidatePerformanceTransferIssues.removeValue(forKey: revision)
        if graphChanged {
            overrides.removeAll()
            lastRenderedOverrides.removeAll()
            lastRenderedGeneration = overrideGeneration
            reconcilePerformanceHandles(after: nextCatalog)
        }
        updateRowLines()
        publishedPerformanceGeneration = generation
        performanceTransaction = nil
        requestControlVisualization()
        refresh()
        status = isPlaying ? "Live · edit freely" : "Paused"
        if let pending = pendingPerformanceIntent {
            pendingPerformanceIntent = nil
            startPerformance(pending)
        } else {
            resumeDeferredEvaluationIfPossible()
        }
    }

    private func controlLayoutMatches(_ previous: LiveControlCatalog?, _ next: LiveControlCatalog) -> Bool {
        guard let previous, previous.descriptors.count == next.descriptors.count else { return false }
        return zip(previous.descriptors, next.descriptors).allSatisfy { old, new in
            old.address == new.address && old.label == new.label
        }
    }

    private func rowProvenanceMatches(_ previous: PreparedLoop?, _ next: PreparedLoop) -> Bool {
        guard let previous, previous.rows.count == next.rows.count else { return false }
        return zip(previous.rows, next.rows).allSatisfy { old, new in
            old.sourceID == new.sourceID
                && old.label == new.label
                && old.anchor == new.anchor
                && old.patternText == new.patternText
                && old.resultLine == new.resultLine
        }
    }

    private func reconcilePerformanceHandles(after catalog: LiveControlCatalog) {
        if let selectedControl,
           selectedControl.target != .master || catalog.descriptor(for: selectedControl) == nil {
            self.selectedControl = nil
        }
        xyX = nil
        xyY = nil
        let previousBindingCount = learnedBindings.count
        learnedBindings.removeAll { binding in
            binding.address.target != .master || catalog.descriptor(for: binding.address) == nil
        }
        if previousBindingCount != learnedBindings.count {
            hostDiagnostic = "MIDI Learn bindings were detached after the performance graph changed."
        }
        if let learnAddress,
           learnAddress.target != .master || catalog.descriptor(for: learnAddress) == nil {
            self.learnAddress = nil
        }
        controlVisualization = nil
        visualizationStatus = "Choose a score control to inspect its trajectories."
    }

    private func resumeDeferredEvaluationIfPossible() {
        guard deferredEvaluation, performanceTask == nil, performanceTransaction == nil,
              performanceConfirmationTask == nil else { return }
        let immediate = deferredEvaluationImmediate
        deferredEvaluation = false
        deferredEvaluationImmediate = false
        if requiresEvaluatorReset {
            deferredEvaluation = true
            deferredEvaluationImmediate = immediate
            guard evaluatorResetTask == nil else { return }
            evaluatorResetTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.evaluationTask?.value
                await self.controlTask?.value
                await self.adoptionTask?.value
                do { try await self.evaluator.shutdown() }
                catch {
                    self.diagnostic = error.localizedDescription
                    self.evaluatorResetTask = nil
                    self.deferredEvaluation = false
                    return
                }
                self.requiresEvaluatorReset = false
                self.evaluatorResetTask = nil
                guard !self.isShuttingDown else { return }
                self.resumeDeferredEvaluationIfPossible()
            }
            return
        }
        scheduleEvaluation(immediate: immediate)
    }

    private func catalogWithMasters(_ catalog: LiveControlCatalog, revision: UInt64) throws -> LiveControlCatalog {
        let hasPerformanceBPM = performanceControlMetadata.contains { metadata in
            if case .double(_, let role) = metadata.domain { return role == .beatsPerMinute }
            return false
        }
        let masters: [(LiveControlParameter, String, LiveControlBaseline)] = [
            (.lowPassCutoff, "Master Filter", lowPass >= 19_999 ? .bypassed : .scalar(lowPass)),
            (.delayMix, "Master Delay", .scalar(delayMix)),
            (.reverbMix, "Master Reverb", .scalar(reverbMix))
        ]
        let tempo: [(LiveControlParameter, String, LiveControlBaseline)] = hasPerformanceBPM
            ? [] : [(.playbackRate, "Master Tempo", .scalar(masterBPM / (loop?.bpm ?? 120)))]
        return try LiveControlCatalog(descriptors: catalog.descriptors + (tempo + masters).map {
            LiveControlDescriptor(address: .init(revision: revision, target: .master, parameter: $0.0),
                                  label: $0.1, baseline: $0.2,
                                  presentation: try .suggested(for: $0.0))
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
        case .playbackRate: try engine.setPlaybackRate(Float(number ?? masterBPM / (loop?.bpm ?? 120)))
        case .lowPassCutoff:
            let cutoff = value == .bypassed ? nil : (number ?? (lowPass >= 19_999 ? nil : lowPass))
            try engine.setLowPass(cutoff: cutoff.map(Float.init))
        case .delayMix: try engine.setDelay(mix: Float(number ?? delayMix))
        case .reverbMix: try engine.setReverb(mix: Float(number ?? reverbMix))
        default: throw LiveControlError.unsupportedAddress(address)
        }
    }

    var activeTokens: [Int: Set<Int>] {
        guard audibleDocumentID == activeDocumentID else { return [:] }
        guard isPlaying, let loop else { return [:] }
        var tokens: [Int: Set<Int>] = [:]
        for event in loop.events where event.gain > 0 && event.isActive(at: beatPosition, in: loop.beatCount) {
            if let index = event.patternStepIndex { tokens[event.sourceID, default: []].insert(index) }
        }
        return tokens
    }

    func beforeEdit(range: NSRange, replacement: String) {
        diagnosticRange = nil
        selectionRange = nil
        if source != completionSource || range.location < 0 || range.length < 0 || range.location > source.utf16.count
            || range.length > source.utf16.count - range.location {
            completionSites = []
            completionSource = ""
        } else {
            completionSource = (source as NSString).replacingCharacters(in: range, with: replacement)
        }
        let delta = replacement.utf16.count - range.length
        completionSites = completionSites.compactMap { site in
            var content = site.contentRange
            if range.location >= content.location, NSMaxRange(range) <= NSMaxRange(content),
                    !replacement.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) {
                content.length += delta
            } else { return nil }
            guard content.length >= 0 else { return nil }
            do { return try .init(sourceID: site.sourceID, contentRange: content, values: site.values) }
            catch { hostDiagnostic = error.localizedDescription; return nil }
        }
        for key in Array(lineMaps.keys) { lineMaps[key]?.applyEdit(range: range, replacement: replacement) }
    }

    private func updateRowLines() {
        rowLines = [:]
        resultLines = [:]
        guard audibleDocumentID == activeDocumentID, let loop, let currentRevision, let map = lineMaps[currentRevision] else { return }
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
        guard let diagnosticRange else { return }
        selectionRange = diagnosticRange
        selectionToken += 1
    }

    func revealTrack(_ name: String) {
        selectionRange = nil
        let literal = "Track(\"\(name)\""
        guard let range = source.range(of: literal) else { return }
        selectionLine = source[..<range.lowerBound].filter { $0 == "\n" }.count + 1
        selectionToken += 1
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.swiftSource, .plainText]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try openDocument(at: url) }
        catch { diagnostic = error.localizedDescription }
    }

    enum DocumentFailure: LocalizedError {
        case tabLimit, duplicateDestination
        var errorDescription: String? {
            switch self {
            case .tabLimit: "Close a tab before opening another. The limit is 32 documents."
            case .duplicateDestination: "This file is already open in another tab."
            }
        }
    }

    func openDocument(at url: URL) throws {
        let identity = url.standardizedFileURL.resolvingSymlinksInPath()
        if let document = documents.first(where: { $0.fileURL == identity }) {
            selectDocument(document.id)
            return
        }
        guard documents.count < Self.maximumOpenDocuments else { throw DocumentFailure.tabLimit }
        let text = try String(contentsOf: identity, encoding: .utf8)
        guard text.utf8.count <= 65_536 else { throw EvaluationError.invalidSource("Source exceeds 64 KiB.") }
        let document = SessionDocument(source: text, fileURL: identity)
        documents.append(document)
        selectDocument(document.id)
    }

    func selectDocument(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }), index != activeDocumentIndex else { return }
        abortPerformanceForDocumentChange()
        activeDocumentIndex = index
        lineMaps = [:]
        rowLines = [:]
        resultLines = [:]
        completionSites = []
        completionSource = ""
        completionStatus = ""
        diagnostic = ""
        selectionRange = nil
        selectionLine = nil
        controlVisualization = nil
        visualizationTask?.cancel()
        loadHostSettings(for: fileURL)
        scheduleEvaluation(immediate: true)
    }

    enum CloseDecision { case save, cancel, discard }

    private func closeDecision(for document: SessionDocument) -> CloseDecision {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.name)?"
        alert.informativeText = "Your unsaved Swift code will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    @discardableResult
    func closeDocument(_ id: UUID, decision: CloseDecision? = nil) -> Bool {
        guard let document = documents.first(where: { $0.id == id }) else { return true }
        if document.isDirty {
            switch decision ?? closeDecision(for: document) {
            case .save: guard saveDocument(document) else { return false }
            case .cancel: return false
            case .discard: break
            }
        }
        let wasActive = id == activeDocumentID
        let retainedID = activeDocumentID
        if documents.count == 1 { documents.append(SessionDocument(source: Self.initialSource)) }
        if wasActive, let replacement = documents.first(where: { $0.id != id }) { selectDocument(replacement.id) }
        let selectedID = wasActive ? activeDocumentID : retainedID
        documents.removeAll { $0.id == id }
        activeDocumentIndex = documents.firstIndex { $0.id == selectedID } ?? 0
        return true
    }

    func confirmAllDocuments(decision: ((SessionDocument) -> CloseDecision)? = nil) -> Bool {
        for document in documents where document.isDirty {
            switch decision?(document) ?? closeDecision(for: document) {
            case .save: guard saveDocument(document) else { return false }
            case .cancel: return false
            case .discard: break
            }
        }
        return true
    }

    private func abortPerformanceForDocumentChange() {
        requiresEvaluatorReset = true
        evaluationTask?.cancel()
        controlTask?.cancel()
        adoptionTask?.cancel()
        if let reservedPerformanceToken {
            _ = engine?.discardPerformanceReplacement(reservedPerformanceToken)
            self.reservedPerformanceToken = nil
        }
        performanceTask?.cancel()
        performanceConfirmationTask?.cancel()
        performanceConfirmationTask = nil
        pendingPerformanceIntent = nil
        performanceTransaction = nil
        controlsAvailable = false
    }

    @discardableResult func saveDocument() -> Bool { saveDocument(activeDocument) }

    @discardableResult
    func saveDocument(_ document: SessionDocument, to url: URL? = nil) -> Bool {
        var destination = url ?? document.fileURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Session.swift"
            panel.allowedContentTypes = [.swiftSource]
            guard panel.runModal() == .OK else { return false }
            destination = panel.url
        }
        guard let destination = destination?.standardizedFileURL.resolvingSymlinksInPath() else { return false }
        do {
            guard !documents.contains(where: { $0.id != document.id && $0.fileURL == destination }) else { throw DocumentFailure.duplicateDestination }
            try document.source.write(to: destination, atomically: true, encoding: .utf8)
            document.fileURL = destination
            if document.id == activeDocumentID { try saveHostSettings(for: destination) }
            document.isDirty = false
            return true
        } catch { diagnostic = error.localizedDescription; return false }
    }

    func confirmDiscard() -> Bool {
        guard activeDocument.isDirty else { return true }
        switch closeDecision(for: activeDocument) {
        case .save: return saveDocument()
        case .cancel: return false
        case .discard: return true
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
            if route.input != nil { try await startMIDIEvents() }
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
        if let reservedPerformanceToken {
            _ = engine?.discardPerformanceReplacement(reservedPerformanceToken)
            self.reservedPerformanceToken = nil
        }
        await evaluatorResetTask?.value
        visualizationTask?.cancel()
        await visualizationTask?.value
        hostRestoreTask?.cancel()
        effectTask?.cancel()
        midiEventTask?.cancel()
        await hostRestoreTask?.value
        if let effectTask {
            do { try await effectTask.value }
            catch is CancellationError { }
            catch { hostDiagnostic = error.localizedDescription }
        }
        var recordingFailure: Error?
        do { try await cancelRecording() }
        catch { recordingFailure = error; diagnostic = error.localizedDescription }
        do { try await cancelStemExport() }
        catch {
            diagnostic = recordingFailure.map { "\($0.localizedDescription)\n\(error.localizedDescription)" } ?? error.localizedDescription
            if recordingFailure == nil { recordingFailure = error }
        }
        performanceTask?.cancel()
        if let reservedPerformanceToken {
            _ = engine?.discardPerformanceReplacement(reservedPerformanceToken)
            self.reservedPerformanceToken = nil
        }
        await performanceTask?.value
        performanceConfirmationTask?.cancel()
        await performanceConfirmationTask?.value
        performanceTask = nil
        performanceConfirmationTask = nil
        pendingPerformanceIntent = nil
        performanceTransaction = nil
        deferredEvaluation = false
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
        await midiEventTask?.value
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

    private func requestControlVisualization() {
        visualizationTask?.cancel()
        controlVisualization = nil
        guard selectionGeneration < UInt64.max else {
            visualizationStatus = "Selection generation limit reached. Reopen the app."
            return
        }
        selectionGeneration += 1
        let selection = selectionGeneration
        guard let address = selectedControl, let currentRevision, address.revision == currentRevision,
              controlsAvailable, overrideGeneration == lastRenderedGeneration else {
            visualizationStatus = "Waiting for an adopted score control."
            return
        }
        guard address.target != .master else {
            visualizationStatus = "Master controls use the live output monitor."
            return
        }
        let generation = overrideGeneration
        let values = lastRenderedOverrides.map { LiveControlOverride(address: $0.key, value: $0.value) }
        visualizationStatus = "Loading control trajectories…"
        visualizationTask = Task { [weak self, evaluator] in
            do {
                let result = try await evaluator.visualization(address: address, overrides: values,
                    revision: currentRevision, selectionGeneration: selection)
                try Task.checkCancellation()
                guard let self, self.selectionGeneration == selection, self.currentRevision == currentRevision,
                      self.overrideGeneration == generation, self.selectedControl == address else { return }
                self.controlVisualization = result
                self.visualizationStatus = "Mint: selected · Cyan: amplitude · Orange: pitch · Purple: filter · Individual scales"
            } catch is CancellationError { }
            catch {
                let available = await evaluator.controlsAvailable(revision: currentRevision)
                guard let self, self.selectionGeneration == selection, self.currentRevision == currentRevision else { return }
                self.controlsAvailable = available
                self.visualizationStatus = "Trajectories unavailable: \(error)"
                self.hostDiagnostic = self.visualizationStatus
            }
        }
    }

    private var performanceBPMControlID: String? {
        performanceControlMetadata.first { metadata in
            if case .double(_, let role) = metadata.domain { return role == .beatsPerMinute }
            return false
        }?.controlID
    }

    func resetPerformanceDiagnostics() { engine?.resetDiagnostics() }

    var displayedBPM: Double {
        if let performanceBPMControlID, let value = performanceNumber(performanceBPMControlID) {
            return value
        }
        if case .number(let rate) = masterControlValues[.playbackRate] { return rate * 120 }
        return bpm
    }

    var xyControls: [LiveControlDescriptor] {
        (controlCatalog?.descriptors ?? []).filter { $0.address.target != .master && $0.presentation != nil }
    }

    func controlValue(_ descriptor: LiveControlDescriptor) -> Double? {
        let value = descriptor.address.target == .master
            ? masterControlValues[descriptor.address.parameter] : overrides[descriptor.address]
        if case .number(let number) = value { return number }
        if value == .bypassed { return nil }
        if descriptor.address.target == .master {
            switch descriptor.address.parameter {
            case .playbackRate: return masterBPM / (loop?.bpm ?? 120)
            case .lowPassCutoff: return lowPass >= 19_999 ? nil : lowPass
            case .delayMix: return delayMix
            case .reverbMix: return reverbMix
            default: return nil
            }
        }
        if case .scalar(let number) = descriptor.baseline { return number }
        return nil
    }

    func setXY(x: Double, y: Double) throws {
        guard let xyX, let xyY, xyX != xyY,
              let a = controlCatalog?.descriptor(for: xyX), let b = controlCatalog?.descriptor(for: xyY),
              xyX.target != .master, xyY.target != .master,
              let first = a.presentation, let second = b.presentation else {
            throw LiveControlError.invalidCatalog("Choose two score controls for the XY pad.")
        }
        try setControls([xyX: .number(first.value(at: x)), xyY: .number(second.value(at: y))])
    }

    func refreshHostDevices() async throws {
        guard !isShuttingDown else { throw MIDIError.serviceShutDown }
        if let engine { audioEffects = try engine.discoverAudioEffects() }
        if midiService == nil { midiService = try CoreMIDIService() }
        guard let midiService else { throw MIDIError.serviceShutDown }
        let endpoints = try await midiService.enumerateEndpoints()
        guard !isShuttingDown else { throw MIDIError.serviceShutDown }
        midiEndpoints = endpoints
    }

    func selectHostedEffect(_ id: HostedAudioUnitID?, restoring state: HostedAudioUnitState? = nil) async throws {
        guard !isShuttingDown, !isRecording, let engine else {
            throw EvaluationError.invalidResult("Stop recording before changing the hosted effect.")
        }
        effectTask?.cancel()
        let task = Task { if let id { try await engine.selectAudioEffect(id, restoring: state) }
            else { try engine.clearAudioEffect() } }
        effectTask = task
        let requestID = UUID()
        effectRequestID = requestID
        isLoadingEffect = true
        defer {
            if effectRequestID == requestID { isLoadingEffect = false; hostedEffect = engine.audioEffectSnapshot() }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func bypassHostedEffect(_ bypassed: Bool) throws {
        guard let engine else { throw EvaluationError.invalidResult(audioError) }
        try engine.setAudioEffectBypassed(bypassed)
        hostedEffect = engine.audioEffectSnapshot()
    }

    func beginMIDILearn(_ address: LiveControlAddress) throws {
        guard midiRoute.input != nil, midiEventTask != nil else { throw MIDIError.invalidLoop("Select an active MIDI input before learning a control.") }
        guard address.revision == currentRevision, controlCatalog?.descriptor(for: address)?.presentation != nil else {
            throw LiveControlError.unknownAddress(address)
        }
        learnAddress = address
    }

    func clearMIDILearn(_ address: LiveControlAddress) {
        learnedBindings.removeAll { $0.address == address }
        if learnAddress == address { learnAddress = nil }
    }

    private func startMIDIEvents() async throws {
        guard midiEventTask == nil, let midiService else { return }
        let events = try await midiService.eventStream()
        midiEventTask = Task { [weak self] in
            defer {
                self?.midiEventTask = nil
                if !Task.isCancelled, self?.midiClosed == false {
                    self?.learnAddress = nil
                    self?.hostDiagnostic = "MIDI input stream ended. Reconnect the input to resume Learn."
                }
            }
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receiveControlChange(event)
            }
        }
    }

    private func receiveControlChange(_ event: TimestampedMIDIEvent) {
        guard event.sourceID == midiRoute.input,
              case .controlChange(let channel, let controller, let value) = event.message else { return }
        do {
            _ = try event.message.validated()
            if let address = learnAddress {
                guard address.revision == currentRevision, adoptedSourceDigest != nil else {
                    learnAddress = nil
                    throw LiveControlError.unknownAddress(address)
                }
                learnedBindings.removeAll { $0.address == address || ($0.endpoint == event.sourceID && $0.channel == channel && $0.controller == controller) }
                guard learnedBindings.count < DocumentHostStateStore.maximumBindingCount else {
                    throw DocumentHostStateStore.Failure.tooLarge
                }
                learnedBindings.append(.init(endpoint: event.sourceID, channel: channel, controller: controller, address: address))
                learnAddress = nil
            }
            guard let binding = learnedBindings.first(where: { $0.endpoint == event.sourceID && $0.channel == channel && $0.controller == controller }),
                  binding.address.revision == currentRevision,
                  let descriptor = controlCatalog?.descriptor(for: binding.address),
                  let presentation = descriptor.presentation else { return }
            let range = binding.range
            let mapping = try LiveControlPresentation(unit: presentation.unit,
                minimum: range?.lowerBound ?? presentation.minimum, maximum: range?.upperBound ?? presentation.maximum,
                scale: presentation.scale)
            try setControl(binding.address, value: .number(mapping.value(at: Double(value) / 127)))
        } catch { hostDiagnostic = error.localizedDescription }
    }

    func saveHostSettings(for document: URL) throws {
        let effect: HostedAudioUnitState?
        let bypassed: Bool
        switch engine?.audioEffectSnapshot() ?? .none {
        case .none: effect = nil; bypassed = false
        case .loaded(_, let value): effect = try engine?.captureAudioEffectState(); bypassed = value
        }
        try hostStateStore.save(.init(adoptedSourceDigest: adoptedSourceDigest, route: midiRoute,
            effect: effect, effectBypassed: bypassed, bindings: learnedBindings), for: document)
    }

    private func loadHostSettings(for document: URL?) {
        hostRestoreTask?.cancel()
        effectTask?.cancel()
        pendingHostState = nil
        do {
            let saved = try document.flatMap { try hostStateStore.load(for: $0) }
            pendingHostState = saved ?? .init(adoptedSourceDigest: nil, route: .disabled,
                effect: nil, effectBypassed: false, bindings: [])
        }
        catch { hostDiagnostic = error.localizedDescription }
    }

    private func adoptedControlsDidChange(revision: UInt64) {
        adoptedSourceDigest = candidateSourceDigests[revision]
        completionSource = source
        completionSites = adoptedSourceDigest == DocumentHostStateStore.sourceDigest(source)
            ? (candidateMetadata[revision]?.completionSites ?? []) : []
        candidateMetadata = candidateMetadata.filter { $0.key == revision }
        candidateSourceDigests = candidateSourceDigests.filter { $0.key == revision }
        if !learnedBindings.isEmpty { hostDiagnostic = "MIDI Learn bindings were detached after the score changed." }
        learnedBindings.removeAll()
        learnAddress = nil
        selectedControl = controlCatalog?.descriptors.first?.address
        xyX = xyControls.first(where: { $0.address.parameter == .pan })?.address ?? xyControls.first?.address
        xyY = xyControls.first(where: { $0.address != xyX })?.address
        let state = pendingHostState
        pendingHostState = nil
        let previousRestore = hostRestoreTask
        previousRestore?.cancel()
        hostRestoreTask = Task { [weak self] in
            await previousRestore?.value
            guard let self, !Task.isCancelled, self.currentRevision == revision, let state else { return }
            do { try await self.restoreHostSettings(state, revision: revision) }
            catch is CancellationError { }
            catch { self.hostDiagnostic = error.localizedDescription }
        }
    }

    func restoreHostSettings(_ state: DocumentHostStateStore.State, revision: UInt64) async throws {
        try state.validate()
        guard !isRestoringHostState else { throw EvaluationError.invalidResult("Host restore is already in progress.") }
        isRestoringHostState = true
        defer { isRestoringHostState = false }
        guard currentRevision == revision, let catalog = controlCatalog else {
            throw LiveControlError.staleRevision(expected: currentRevision ?? 0, actual: revision)
        }
        try await refreshHostDevices()
        try Task.checkCancellation()
        guard currentRevision == revision else { throw CancellationError() }
        if let effect = state.effect, !audioEffects.contains(where: { $0.id == effect.id }) {
            throw HostedAudioUnitError.missingComponent
        }
        for input in state.route.inputIDs {
            guard midiEndpoints.contains(where: { $0.id == input && $0.direction == .input }) else { throw MIDIError.endpointNotFound(input) }
        }
        if let output = state.route.output,
           !midiEndpoints.contains(where: { $0.id == output && $0.direction == .output }) { throw MIDIError.endpointNotFound(output) }
        var bindings: [DocumentHostStateStore.LearnBinding] = []
        for binding in state.bindings where state.adoptedSourceDigest == adoptedSourceDigest {
            let address = LiveControlAddress(revision: revision, target: binding.address.target, parameter: binding.address.parameter)
            guard binding.endpoint == state.route.input, let descriptor = catalog.descriptor(for: address),
                  descriptor.presentation != nil else { continue }
            if let range = binding.range {
                do {
                    for endpoint in [range.lowerBound, range.upperBound] {
                        if address.target == .master { try AudioLoopEngine.validateMasterControl(address.parameter, value: Float(endpoint)) }
                        else { try catalog.validate(value: .number(endpoint), for: address) }
                    }
                } catch { continue }
            }
            bindings.append(.init(endpoint: binding.endpoint, channel: binding.channel, controller: binding.controller,
                                  address: address, range: binding.range))
        }
        guard let engine else { throw EvaluationError.invalidResult(audioError) }
        let previous = midiRoute
        let previousEffect = engine.audioEffectSnapshot()
        let previousEffectState: HostedAudioUnitState?
        if case .loaded = previousEffect { previousEffectState = try engine.captureAudioEffectState() }
        else { previousEffectState = nil }
        try await configureMIDI(state.route)
        do {
            try Task.checkCancellation()
            guard currentRevision == revision else { throw CancellationError() }
            try await selectHostedEffect(state.effect?.id, restoring: state.effect)
            try Task.checkCancellation()
            guard currentRevision == revision else { throw CancellationError() }
            if state.effect != nil { try bypassHostedEffect(state.effectBypassed) }
        } catch {
            let original = error
            // Rollback must finish even when the owning restore was cancelled; its caller awaits it.
            let rollback = Task { @MainActor in
                var failures: [String] = []
                do {
                    if let previousEffectState {
                        try await engine.selectAudioEffect(previousEffectState.id, restoring: previousEffectState)
                        if case .loaded(_, let bypassed) = previousEffect { try engine.setAudioEffectBypassed(bypassed) }
                    } else { try engine.clearAudioEffect() }
                } catch { failures.append("Audio Unit rollback: \(error)") }
                do { try await self.configureMIDI(previous) } catch { failures.append("MIDI rollback: \(error)") }
                return failures
            }
            let failures = await rollback.value
            if !failures.isEmpty { throw EvaluationError.invalidResult("Host restore failed: \(original); " + failures.joined(separator: "; ")) }
            throw original
        }
        learnedBindings = bindings
        if bindings.count != state.bindings.count { hostDiagnostic = "Stale MIDI Learn bindings were left unattached." }
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
