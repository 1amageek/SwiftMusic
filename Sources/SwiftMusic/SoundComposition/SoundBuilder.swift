/// Builds an immutable parallel sound tree from sibling declarations.
@resultBuilder
public enum SoundBuilder {
    public static func buildBlock() -> SoundGroup {
        SoundGroup(elements: [])
    }

    public static func buildBlock(_ components: SoundGroup...) -> SoundGroup {
        SoundGroup(elements: components.flatMap(\.elements))
    }

    public static func buildBlock(_ component: Never) -> Never {
        switch component {}
    }

    public static func buildExpression<S: Sound>(_ expression: S) -> SoundGroup {
        SoundGroup(elements: [expression])
    }

    public static func buildExpression(_ expression: Never) -> Never {
        switch expression {}
    }

    public static func buildOptional(_ component: SoundGroup?) -> SoundGroup {
        component ?? SoundGroup(elements: [])
    }

    public static func buildEither(first component: SoundGroup) -> SoundGroup {
        component
    }

    public static func buildEither(second component: SoundGroup) -> SoundGroup {
        component
    }

    public static func buildArray(_ components: [SoundGroup]) -> SoundGroup {
        SoundGroup(elements: components.flatMap(\.elements))
    }

    public static func buildLimitedAvailability(_ component: SoundGroup) -> SoundGroup {
        component
    }
}
