/// Track metadata emitted by `ScoreCompiler` in deterministic pre-order.
public struct CompiledTrack: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let parentID: Int?

    internal init(id: Int, name: String, parentID: Int?) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}
