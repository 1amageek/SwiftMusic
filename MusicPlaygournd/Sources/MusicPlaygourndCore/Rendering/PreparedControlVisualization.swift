import Foundation

public enum ControlVisualizationError: Error, Sendable, Equatable {
    case unsupported(LiveControlAddress)
    case invalidData
    case pointLimit
}

/// Revision-scoped, bounded control trajectories; no audio ownership is transferred.
public struct PreparedControlVisualization: Codable, Sendable, Equatable {
    public static let maximumPoints = 16_384
    public let address: LiveControlAddress
    public let unit: LiveControlUnit
    public let beatCount: Double
    public let traces: [PreparedControlTrace]

    public init(address: LiveControlAddress, unit: LiveControlUnit, beatCount: Double,
                traces: [PreparedControlTrace]) throws {
        self.address = address
        self.unit = unit
        self.beatCount = beatCount
        self.traces = traces
        try validate()
    }

    public func validate() throws {
        guard beatCount.isFinite, beatCount > 0, beatCount <= PreparedLoop.maximumBeatCount,
              traces.count <= PreparedLoop.maximumEvents else { throw ControlVisualizationError.invalidData }
        guard unit == (try LiveControlPresentation.suggested(for: address.parameter)).unit else {
            throw ControlVisualizationError.invalidData
        }
        var total = 0
        var events = Set<Int>()
        for trace in traces {
            switch address.target {
            case .source(let id):
                guard trace.sourceID == id, trace.eventIndex != nil else { throw ControlVisualizationError.invalidData }
            case .renderNode, .track:
                guard trace.sourceID == nil, trace.eventIndex == nil, trace.startBeat == 0,
                      trace.durationBeats == beatCount else { throw ControlVisualizationError.invalidData }
            case .master: throw ControlVisualizationError.unsupported(address)
            }
            if let index = trace.eventIndex {
                guard (0..<PreparedLoop.maximumEvents).contains(index), events.insert(index).inserted, let source = trace.sourceID, source >= 0 else {
                    throw ControlVisualizationError.invalidData
                }
            }
            guard trace.startBeat.isFinite, trace.durationBeats.isFinite, trace.startBeat >= 0,
                  trace.startBeat < beatCount, trace.durationBeats > 0, trace.durationBeats <= beatCount,
                  trace.wrapsLoopBoundary == (trace.startBeat + trace.durationBeats > beatCount),
                  !trace.channels.isEmpty, trace.channels.count <= 4 else { throw ControlVisualizationError.invalidData }
            guard trace.channels.filter({ $0.kind == .selectedValue }).count == 1 else {
                throw ControlVisualizationError.invalidData
            }
            if trace.eventIndex == nil, trace.channels.count != 1 {
                throw ControlVisualizationError.invalidData
            }
            var kinds = Set<PreparedControlTrace.Channel.Kind>()
            for channel in trace.channels {
                guard kinds.insert(channel.kind).inserted, (2...512).contains(channel.points.count) else {
                    throw ControlVisualizationError.invalidData
                }
                guard let first = channel.points.first, let last = channel.points.last,
                      abs(first.beat - trace.startBeat) <= 1e-9,
                      abs(last.beat - trace.startBeat - trace.durationBeats) <= 1e-9 else {
                    throw ControlVisualizationError.invalidData
                }
                total += channel.points.count
                guard total <= Self.maximumPoints else { throw ControlVisualizationError.pointLimit }
                var previous = -Double.infinity
                for point in channel.points {
                    guard point.beat.isFinite, point.value.isFinite, point.beat > previous,
                          point.beat >= trace.startBeat - 1e-9,
                          point.beat <= trace.startBeat + trace.durationBeats + 1e-9 else {
                        throw ControlVisualizationError.invalidData
                    }
                    previous = point.beat
                }
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(address: values.decode(LiveControlAddress.self, forKey: .address),
                      unit: values.decode(LiveControlUnit.self, forKey: .unit),
                      beatCount: values.decode(Double.self, forKey: .beatCount),
                      traces: values.decode([PreparedControlTrace].self, forKey: .traces))
    }
}
