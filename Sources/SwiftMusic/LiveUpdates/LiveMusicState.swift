/// Value-owned update state. The host isolates mutation and supplies musical boundaries.
public struct LiveMusicState: Sendable, Equatable {
    public private(set) var currentSound: CompiledSound?
    public private(set) var currentRevision: UInt64?
    public private(set) var pendingSound: CompiledSound?
    public private(set) var pendingRevision: UInt64?
    public private(set) var diagnostic: SoundCompilationError?
    public private(set) var diagnosticRevision: UInt64?
    public private(set) var latestRevision: UInt64?
    public private(set) var preparingRevision: UInt64?

    public init() {}

    /// Call when an edit arrives, before starting its potentially concurrent preparation.
    @discardableResult
    public mutating func beginUpdate(revision: UInt64) -> Bool {
        if let latestRevision, revision <= latestRevision { return false }
        latestRevision = revision
        preparingRevision = revision
        pendingSound = nil
        pendingRevision = nil
        diagnostic = nil
        diagnosticRevision = nil
        return true
    }

    /// Accepts the latest edit's completion once; stale results never change the state.
    @discardableResult
    public mutating func receive(_ update: LiveMusicUpdate) -> Bool {
        guard preparingRevision == update.revision else { return false }
        preparingRevision = nil
        switch update {
        case .prepared(let revision, let sound):
            pendingSound = sound
            pendingRevision = revision
        case .failed(let revision, let error):
            diagnostic = error
            diagnosticRevision = revision
        }
        return true
    }

    /// The host calls this only after backend preparation, at its chosen musical boundary.
    /// This operation adopts a plan; it does not start audio or advance a playback clock.
    @discardableResult
    public mutating func adoptPendingAtBoundary() -> CompiledSound? {
        guard let pendingSound else { return nil }
        currentSound = pendingSound
        currentRevision = pendingRevision
        self.pendingSound = nil
        pendingRevision = nil
        return currentSound
    }
}
