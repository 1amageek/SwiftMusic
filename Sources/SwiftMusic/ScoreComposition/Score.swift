/// A reusable, composable declaration of musical events.
public protocol Score: Sendable {
    associatedtype Body: Score

    @ScoreBuilder
    var body: Body { get }
}

extension Never: Score {
    public typealias Body = Never

    public var body: Never {
        fatalError("Never has no score body")
    }
}
