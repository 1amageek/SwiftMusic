/// Builds an immutable parallel score from sibling declarations.
@resultBuilder
public enum ScoreBuilder {
    public static func buildBlock() -> ScoreGroup {
        ScoreGroup(elements: [])
    }

    public static func buildBlock(_ components: ScoreGroup...) -> ScoreGroup {
        ScoreGroup(elements: components.flatMap(\.elements))
    }

    public static func buildBlock(_ component: Never) -> Never {
        switch component {}
    }

    public static func buildExpression<S: Score>(_ expression: S) -> ScoreGroup {
        ScoreGroup(elements: [expression])
    }

    public static func buildExpression(_ expression: Never) -> Never {
        switch expression {}
    }

    public static func buildOptional(_ component: ScoreGroup?) -> ScoreGroup {
        component ?? ScoreGroup(elements: [])
    }

    public static func buildEither(first component: ScoreGroup) -> ScoreGroup {
        component
    }

    public static func buildEither(second component: ScoreGroup) -> ScoreGroup {
        component
    }

    public static func buildArray(_ components: [ScoreGroup]) -> ScoreGroup {
        ScoreGroup(elements: components.flatMap(\.elements))
    }

    public static func buildLimitedAvailability(_ component: ScoreGroup) -> ScoreGroup {
        component
    }
}
