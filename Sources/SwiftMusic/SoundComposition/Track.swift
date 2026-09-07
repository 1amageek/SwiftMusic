/// An optional named mix boundary that preserves child timing.
public struct Track: Sound, Sendable {
    public typealias Body = Never

    public let name: String
    internal let content: SoundGroup
    internal var level = 1.0
    internal var pan: Double?
    internal var isMuted = false
    internal var isSoloed = false

    public init(
        _ name: String,
        @SoundBuilder content: () -> SoundGroup
    ) {
        self.name = name
        self.content = content()
    }

    /// Returns a copy with a compiler-validated linear track level.
    public func trackLevel(_ value: Double) -> Track {
        var copy = self
        copy.level = value
        return copy
    }

    /// Returns a copy with an optional equal-power track pan.
    public func trackPan(_ value: Double?) -> Track {
        var copy = self
        copy.pan = value
        return copy
    }

    /// Returns a copy with the requested track mute state.
    public func trackMuted(_ value: Bool = true) -> Track {
        var copy = self
        copy.isMuted = value
        return copy
    }

    /// Returns a copy with the requested track solo state.
    public func trackSolo(_ value: Bool = true) -> Track {
        var copy = self
        copy.isSoloed = value
        return copy
    }

    public var body: Never {
        fatalError("Track is a compiler terminal")
    }
}

extension Track: _SoundPrimitive {
    internal var _node: _SoundNode {
        .track(self)
    }
}
