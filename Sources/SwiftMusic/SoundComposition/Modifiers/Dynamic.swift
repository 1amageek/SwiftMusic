public enum Dynamic: Sendable, Equatable, Hashable {
    case pp
    case p
    case mp
    case mf
    case f
    case ff

    public var velocity: Int {
        switch self {
        case .pp: 32
        case .p: 48
        case .mp: 64
        case .mf: 80
        case .f: 96
        case .ff: 112
        }
    }
}
