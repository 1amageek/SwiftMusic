import MusicPlaygourndCore
import SwiftUI

struct RhythmView: View {
    let loop: PreparedLoop?
    let beatPosition: Double
    let isPlaying: Bool
    let revealTrack: (String) -> Void
    var mutedTracks: [Int: Bool] = [:]
    var onToggleTrackMute: (Int) -> Void = { _ in }
    private let colors: [Color] = [.mint, .orange, .purple, .cyan, .pink, .yellow]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text("RHYTHM").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2)
                Spacer()
                if let loop {
                    Text("\(loop.beatsPerBar)/4  ·  \(loop.bpm, specifier: "%.0f") BPM")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if let loop {
                let ids = Array(Set(loop.events.map(\.sourceID))).sorted()
                HStack(spacing: 0) {
                    Color.clear.frame(width: 122)
                    ForEach(0..<Int(ceil(loop.beatCount)), id: \.self) { beat in
                        Text(beat % loop.beatsPerBar == 0 ? "\(beat / loop.beatsPerBar + 1).1" : "\(beat % loop.beatsPerBar + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(beat % loop.beatsPerBar == 0 ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(spacing: 18) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        let events = loop.events.filter { $0.sourceID == id }
                        let name = events.first?.label ?? "Source \(id + 1)"
                        HStack(spacing: 12) {
                            if let track = loop.rows.first(where: { $0.sourceID == id })?.trackID {
                                TrackMuteButton(name: name, muted: mutedTracks[track]) { onToggleTrackMute(track) }
                            } else {
                                Color.clear.frame(width: 26, height: 22)
                            }
                            Button { revealTrack(name) } label: {
                                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    .foregroundStyle(colors[index % colors.count])
                                    .frame(width: 72, alignment: .leading)
                            }.buttonStyle(.plain).help("Reveal a matching Track declaration")
                            Canvas { context, size in
                                let scale = size.width / loop.beatCount
                                for beat in 0...Int(ceil(loop.beatCount)) {
                                    let x = Double(beat) * scale
                                    var path = Path()
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: size.height))
                                    context.stroke(path, with: .color(.white.opacity(beat % loop.beatsPerBar == 0 ? 0.16 : 0.06)))
                                }
                                for event in events {
                                    event.forEachBeatRange(in: loop.beatCount) { range in
                                        let rect = CGRect(x: range.lowerBound * scale + 1, y: 8,
                                            width: max(3, (range.upperBound - range.lowerBound) * scale - 3), height: size.height - 16)
                                        let active = isPlaying && event.gain > 0 && event.isActive(at: beatPosition, in: loop.beatCount)
                                        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(colors[index % colors.count].opacity(active ? 1 : 0.5)))
                                        if let note = event.displayedMIDINote, rect.width > 23 {
                                            let pitchNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
                                            let label = Text("\(pitchNames[note % 12])\(note / 12 - 1)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.black.opacity(0.8))
                                            context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
                                        }
                                    }
                                }
                                var cursor = Path()
                                cursor.move(to: CGPoint(x: beatPosition * scale, y: 0))
                                cursor.addLine(to: CGPoint(x: beatPosition * scale, y: size.height))
                                context.stroke(cursor, with: .color(.white.opacity(isPlaying ? 0.9 : 0.3)), lineWidth: 1.5)
                            }.frame(height: 58)
                                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("\(name), \(events.count) notes in \(Int(loop.beatCount)) beats")
                                .help(events.map(\.eventDescription).joined(separator: "\n"))
                        }
                    }
                }
                if ids.isEmpty {
                    Text("A silent loop · the transport keeps moving").foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack {
                    Circle().fill(isPlaying ? Color.mint : .gray).frame(width: 6, height: 6)
                    Text(isPlaying ? "PLAYING" : "PAUSED")
                    Spacer()
                    Text("\(loop.events.count) EVENTS  /  \(loop.beatCount, specifier: "%.0f") BEATS")
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "waveform.path").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.mint)
                    Text("Your rhythm, in view").font(.title3)
                    Text("Press Play. Then change the code.\nYour last valid loop keeps playing while you edit.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
                Spacer()
            }
        }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.075, green: 0.09, blue: 0.105))
    }
}

// Presentation consumes the renderer's final pitch capability, never source-note guesses.
extension LoopEvent {
    var displayedMIDINote: Int? {
        if case .note(let value) = midiProjection { return value }
        return nil
    }

    var pitchDescription: String {
        switch midiProjection {
        case .none: "unpitched"
        case .note(let value): "MIDI \(value)"
        case .unsupported(.fractionalPitch): "fractional pitch"
        case .unsupported(.timeVaryingPitch): "time-varying pitch"
        case .unsupported(.legacyMetadataMissing): "pitch metadata unavailable"
        case .unsupported(.outOfRange): "pitch outside MIDI range"
        }
    }

    var eventDescription: String {
        "onset \(startBeat), duration \(durationBeats), \(pitchDescription)"
    }
}
