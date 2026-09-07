/// A dependency-ordered description of audio graph work for a client backend.
public enum CompiledRenderNode: Sendable, Equatable {
    case source(sourceID: Int)
    case mix(inputs: [Int])
    case effect(input: Int, effect: AudioEffect)
    case gain(input: Int, value: Double)
    case gainAutomation(input: Int, automation: GainAutomation)
    case pan(input: Int, value: Double)
    case panAutomation(input: Int, automation: PanAutomation)
    case mute(input: Int)
    case track(input: Int, trackID: Int)
    case send(input: Int, bus: String, level: Double)
    case trackSend(input: Int, bus: String, level: Double, trackID: Int, placement: TrackSendPlacement)
    case busReturn(bus: String, inputs: [Int])
    case output(input: Int, bus: String)
}
