import MusicPlaygourndCore

struct MIDISessionRoute: Codable, Sendable, Equatable {
    var input: MIDIEndpointID?
    var output: MIDIEndpointID?
    var sendsLoopNotes: Bool
    var channel: Int
    var clockMode: MIDIClockMode

    static let disabled = MIDISessionRoute(input: nil, output: nil, sendsLoopNotes: false,
                                          channel: 1, clockMode: .off)

    var inputIDs: Set<MIDIEndpointID> {
        var values = Set<MIDIEndpointID>()
        if let input { values.insert(input) }
        if case .receive(let input) = clockMode { values.insert(input) }
        return values
    }

    func validate() throws {
        guard (1...16).contains(channel) else { throw MIDIError.invalidMessage("channel must be in 1...16") }
        guard !sendsLoopNotes || output != nil else {
            throw MIDIError.invalidLoop("note output requires an endpoint")
        }
        if case .send(let endpoint) = clockMode, output != endpoint {
            throw MIDIError.invalidLoop("clock and note output must select the same endpoint")
        }
    }
}
