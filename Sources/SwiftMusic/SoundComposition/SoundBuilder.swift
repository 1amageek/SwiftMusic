/// Builds a typed parallel sound tree from sibling declarations and Swift control flow.
@resultBuilder
public enum SoundBuilder {
    public static func buildBlock() -> EmptySound { EmptySound() }

    public static func buildBlock<Content: Sound>(_ content: Content) -> Content { content }

    public static func buildBlock<each Content: Sound>(
        _ content: repeat each Content
    ) -> TupleSound<(repeat each Content)> {
        TupleSound((repeat each content))
    }

    public static func buildExpression<Content: Sound>(_ expression: Content) -> Content { expression }

    public static func buildOptional<Content: Sound>(_ component: Content?) -> Content? { component }

    public static func buildEither<First: Sound, Second: Sound>(
        first component: First
    ) -> ConditionalSound<First, Second> {
        ConditionalSound(storage: .first(component))
    }

    public static func buildEither<First: Sound, Second: Sound>(
        second component: Second
    ) -> ConditionalSound<First, Second> {
        ConditionalSound(storage: .second(component))
    }

    public static func buildArray<Content: Sound>(_ components: [Content]) -> ArraySound<Content> {
        ArraySound(components)
    }

    public static func buildLimitedAvailability<Content: Sound>(_ component: Content) -> AnySound {
        AnySound(component)
    }
}
