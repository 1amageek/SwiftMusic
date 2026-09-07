/// A reusable, composable declaration of sound events.
public protocol Sound: Sendable {
    associatedtype Body: Sound

    @SoundBuilder
    var body: Body { get }
}

extension Never: Sound {
    public typealias Body = Never

    public var body: Never {
        fatalError("Never has no sound body")
    }
}
