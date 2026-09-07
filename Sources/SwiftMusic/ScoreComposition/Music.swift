/// The work-level entry point for a declarative score.
public protocol Music: Sendable {
    associatedtype ScoreContent: Score

    @ScoreBuilder
    var score: ScoreContent { get }
}
