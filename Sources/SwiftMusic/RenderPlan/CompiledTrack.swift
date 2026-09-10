/// Track metadata emitted in deterministic pre-order.
public struct CompiledTrack: Sendable, Equatable, Identifiable {
    public internal(set) var id: Int
    public internal(set) var name: String
    public internal(set) var parentID: Int?
    public internal(set) var level: Double
    public internal(set) var pan: Double?
    public internal(set) var isMuted: Bool
    public internal(set) var isSoloed: Bool
    public internal(set) var renderNodeID: Int?

    internal init(
        id: Int,
        name: String,
        parentID: Int?,
        level: Double = 1,
        pan: Double? = nil,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        renderNodeID: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.level = level
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.renderNodeID = renderNodeID
    }
}
