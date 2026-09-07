/// A dependency-ordered description of audio graph work for a client backend.
public enum CompiledRenderNode: Sendable, Equatable {
    case source(sourceID: Int)
    case mix(inputs: [Int])
    case effect(input: Int, effect: AudioEffect)
    case gain(input: Int, value: Double)
    case pan(input: Int, value: Double)
    case mute(input: Int)
    case send(input: Int, bus: String, level: Double)
    case output(input: Int, bus: String)
}
