/// An eventless internal named-bus return.
public struct BusReturn: Sound, Sendable, Equatable, Hashable {
    public typealias Body = Never

    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var body: Never {
        fatalError("BusReturn is a compiler terminal")
    }
}

extension BusReturn: _SoundPrimitive {
    internal var _node: _SoundNode {
        .busReturn(name)
    }
}
