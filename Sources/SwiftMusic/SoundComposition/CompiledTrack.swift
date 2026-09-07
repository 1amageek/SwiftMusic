/// Track metadata emitted in deterministic pre-order.
public struct CompiledTrack: Sendable, Equatable, Identifiable {
    public internal(set) var id: Int
    public internal(set) var name: String
    public internal(set) var parentID: Int?

    internal init(id: Int, name: String, parentID: Int?) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}
