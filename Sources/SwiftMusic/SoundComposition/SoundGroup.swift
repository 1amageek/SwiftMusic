/// An explicit parallel scope for shared modifiers, without track metadata.
public struct SoundGroup<Content: Sound>: Sound {
    public let content: Content

    public init(@SoundBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Content { content }
}
