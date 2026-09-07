import SwiftMusic

/// Bounded offline allocation; no per-frame storage grows beyond the compiled event count.
internal enum VoiceScheduler {
    private struct ActiveVoice {
        var voice: RenderedVoice
        let onset: Int
        var terminationOffset: Int?
        var terminationFrames: Int {
            terminationOffset.map { min(128, voice.eventFrames - $0) } ?? 0
        }
        var finished: Bool {
            voice.state.offset >= voice.eventFrames || terminationOffset.map {
                voice.state.offset >= $0 + terminationFrames
            } == true
        }
        mutating func terminate() { terminationOffset = voice.state.offset }
        func magnitude() throws -> Float {
            let magnitude: Float
            if voice.state.offset == 0 {
                var preview = voice
                let value = try preview.next()
                magnitude = max(abs(value.left), abs(value.right))
            } else {
                magnitude = max(abs(voice.state.lastLeft), abs(voice.state.lastRight))
            }
            guard magnitude.isFinite else {
                throw LoopRenderingError.invalidEvent(index: voice.eventIndex, reason: "non-finite allocation magnitude")
            }
            return magnitude
        }
    }
    private struct Boundary: Equatable {
        let eventIndex: Int
        let state: RenderedVoice.State
        let terminationOffset: Int?
    }
    private struct Occurrence {
        let template: Int
        let frame: Int
    }

    static func render(templates: [RenderedVoice], sourceCount: Int,
                       frameCount: Int, seamless: Bool) throws -> [StereoBuffer] {
        let sorted = templates.indices.sorted {
            templates[$0].startFrame == templates[$1].startFrame
                ? templates[$0].eventIndex < templates[$1].eventIndex
                : templates[$0].startFrame < templates[$1].startFrame
        }
        var occurrences: [Occurrence] = []
        occurrences.reserveCapacity(templates.count * (seamless ? 2 : 1))
        if seamless {
            for index in sorted { occurrences.append(Occurrence(template: index, frame: templates[index].startFrame - frameCount)) }
        }
        for index in sorted { occurrences.append(Occurrence(template: index, frame: templates[index].startFrame)) }
        var output = (0..<sourceCount).map { _ in StereoBuffer(frameCount: frameCount) }
        var active: [ActiveVoice] = []
        active.reserveCapacity(templates.count)
        var cursor = 0
        var boundary: [Boundary] = []
        for frame in (seamless ? -frameCount : 0)...frameCount {
            active.removeAll { $0.finished }
            if seamless, frame == 0 || frame == frameCount {
                let snapshot = active.map { Boundary(eventIndex: $0.voice.eventIndex,
                    state: $0.voice.state, terminationOffset: $0.terminationOffset) }
                if frame == 0 { boundary = snapshot }
                else if boundary != snapshot { throw LoopRenderingError.nonPeriodicVoiceAllocation }
            }
            if frame == frameCount { break }
            while cursor < occurrences.count, occurrences[cursor].frame == frame {
                let incoming = templates[occurrences[cursor].template]
                if let group = incoming.source.chokeGroup {
                    for index in active.indices where active[index].terminationOffset == nil
                        && active[index].voice.source.chokeGroup == group {
                        active[index].terminate()
                    }
                }
                let limit: Int
                let stealing: VoiceStealing
                switch incoming.source.voicePolicy {
                case .none: limit = templates.count; stealing = .oldest
                case .monophonic: limit = 1; stealing = .oldest
                case .polyphonic(let count, let rule): limit = count; stealing = rule
                }
                var count = 0
                var victim: Int?
                var quietest = Float.infinity
                for index in active.indices where active[index].terminationOffset == nil
                    && active[index].voice.source.id == incoming.source.id {
                    count += 1
                    let magnitude = stealing == .quietest ? try active[index].magnitude() : 0
                    let earlier = victim.map {
                        active[index].onset < active[$0].onset || (active[index].onset == active[$0].onset
                            && active[index].voice.eventIndex < active[$0].voice.eventIndex)
                    } ?? true
                    if victim == nil || magnitude < quietest || (magnitude == quietest && earlier) {
                        victim = index; quietest = magnitude
                    }
                }
                if count >= limit, let victim { active[victim].terminate() }
                guard active.count < templates.count else {
                    throw LoopRenderingError.invalidSound("active voice bound exceeded")
                }
                active.append(ActiveVoice(voice: incoming, onset: frame))
                cursor += 1
            }
            for index in active.indices {
                let offset = active[index].voice.state.offset
                var value = try active[index].voice.next()
                if let start = active[index].terminationOffset {
                    let length = active[index].terminationFrames
                    let gain = length <= 1 ? 0 : Float(length - 1 - (offset - start)) / Float(length - 1)
                    value.left *= gain; value.right *= gain
                }
                if frame >= 0 {
                    let source = active[index].voice.source.id
                    output[source].left[frame] += value.left
                    output[source].right[frame] += value.right
                }
            }
        }
        return output
    }
}
