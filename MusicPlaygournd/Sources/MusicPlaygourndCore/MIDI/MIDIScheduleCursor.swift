import Foundation

/// Value state is committed by the service only after the complete native send succeeds.
internal struct MIDIScheduleCursor {
    private var noteThrough: Double?
    private var clockThrough: Double?

    mutating func resetClock() { clockThrough = nil }

    // Each entry represents one accepted occurrence, even when pitches coincide.
    private struct PendingOff {
        let beat: Double
        let channel: Int
        let note: Int
    }
    private var pendingOffs: [PendingOff] = []

    mutating func notes(loop: PreparedLoop, from: Double, through: Double, channel: Int,
                        anchor: PlaybackClockAnchor) throws -> [MIDIScheduledMessage] {
        try validateWindow(from: from, through: through, anchor: anchor)
        guard (1...16).contains(channel), loop.beatCount.isFinite, loop.beatCount > 0 else {
            throw MIDIError.invalidLoop("channel or loop length is invalid")
        }
        let lower = max(from, noteThrough ?? from)
        guard through > lower else { return [] }
        var messages: [MIDIScheduledMessage] = []
        var pending = pendingOffs
        for event in loop.events {
            guard event.startBeat.isFinite, event.startBeat >= 0, event.startBeat < loop.beatCount,
                  event.durationBeats.isFinite, event.durationBeats > 0,
                  event.durationBeats <= loop.beatCount, (0...127).contains(event.velocity) else {
                throw MIDIError.invalidLoop("event timing or velocity is invalid")
            }
            guard event.midiProjection != .none else { continue }
            var cycle = max(0, ceil((lower - event.startBeat) / loop.beatCount))
            var beat = cycle * loop.beatCount + event.startBeat
            guard cycle.isFinite, beat.isFinite else { throw MIDIError.invalidLoop("event time overflow") }
            while beat < through {
                if beat >= lower {
                    switch event.midiProjection {
                    case .none: break
                    case .unsupported(let limitation): throw MIDIError.unsupportedProjection(limitation)
                    case .note(let note):
                        guard (0...127).contains(note) else { throw MIDIError.invalidLoop("MIDI note is out of range") }
                        guard messages.count < 256 else { throw MIDIError.tooManyMessages(limit: 256) }
                        guard pending.count < 2_048 else { throw MIDIError.tooManyActiveNotes(limit: 2_048) }
                        let end = beat + event.durationBeats
                        guard end.isFinite, end > beat else { throw MIDIError.invalidLoop("note end precision exhausted") }
                        messages.append(MIDIScheduledMessage(hostTime: try anchor.hostTime(atBeat: beat),
                            message: .noteOn(channel: channel, note: note, velocity: event.velocity)))
                        pending.append(PendingOff(beat: end, channel: channel, note: note))
                    }
                }
                let next = cycle + 1
                guard next > cycle else { throw MIDIError.invalidLoop("loop occurrence precision exhausted") }
                cycle = next
                beat = cycle * loop.beatCount + event.startBeat
            }
        }
        for off in pending where off.beat < through {
            guard off.beat >= lower else { throw MIDIError.clockDiscontinuity }
            guard messages.count < 256 else { throw MIDIError.tooManyMessages(limit: 256) }
            messages.append(MIDIScheduledMessage(hostTime: try anchor.hostTime(atBeat: off.beat),
                message: .noteOff(channel: off.channel, note: off.note, velocity: 0)))
        }
        pending.removeAll { $0.beat < through }
        messages.sort {
            if $0.hostTime != $1.hostTime { return $0.hostTime < $1.hostTime }
            if case .noteOff = $0.message, case .noteOn = $1.message { return true }
            return false
        }
        pendingOffs = pending
        noteThrough = through
        return messages
    }

    mutating func clock(from: Double, through: Double, anchor: PlaybackClockAnchor) throws -> [MIDIScheduledMessage] {
        try validateWindow(from: from, through: through, anchor: anchor)
        let lower = max(from, clockThrough ?? from)
        guard through > lower else { return [] }
        var ordinal = ceil(lower * 24)
        let end = through * 24
        guard ordinal.isFinite, end.isFinite else { throw MIDIError.invalidClock("pulse ordinal overflow") }
        var messages: [MIDIScheduledMessage] = []
        while ordinal < end {
            guard messages.count < 256 else { throw MIDIError.tooManyMessages(limit: 256) }
            messages.append(MIDIScheduledMessage(hostTime: try anchor.hostTime(atBeat: ordinal / 24), message: .clock))
            let next = ordinal + 1
            guard next > ordinal else { throw MIDIError.invalidClock("pulse ordinal precision exhausted") }
            ordinal = next
        }
        clockThrough = through
        return messages
    }

    private func validateWindow(from: Double, through: Double, anchor: PlaybackClockAnchor) throws {
        guard anchor.isPlaying else { throw MIDIError.clockUnavailable }
        guard from.isFinite, through.isFinite, from >= 0, through > from else {
            throw MIDIError.invalidLoop("schedule window is invalid")
        }
        guard (through - from) / anchor.beatsPerMinute * 60 <= 0.100000001 else {
            throw MIDIError.timestampTooFar
        }
    }
}
