/// The work-level entry point for a declarative sound tree.
public protocol Music: Sendable {
    associatedtype Body: Sound

    @SoundBuilder
    var body: Body { get }
}
