import Observation

/// Owns declaration-local state shared by copies of a music value.
/// Hosts retain the music value for its session lifetime.
@propertyWrapper
@MainActor
@Observable
public final class State<Value: Sendable> {
    public var wrappedValue: Value

    public nonisolated init(wrappedValue: Value) {
        self._wrappedValue = wrappedValue
    }

    public var projectedValue: State<Value> { self }
}
