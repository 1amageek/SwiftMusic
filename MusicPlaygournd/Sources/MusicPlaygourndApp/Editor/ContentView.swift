import SwiftUI

struct ContentView: View {
    @Bindable var model: SessionModel
    @State private var lineRects: [Int: CGRect] = [:]
    @State private var timelineScroll: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.mint)
                    Text("MusicPlaygournd").font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                HStack(spacing: 7) {
                    Text("BPM").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("BPM", value: $model.bpm, format: .number.precision(.fractionLength(0)))
                        .frame(width: 44).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("tempo-field")
                    Stepper("Tempo", value: $model.bpm, in: 40...240, step: 1).labelsHidden()
                }
                Picker("Meter", selection: $model.beatsPerBar) {
                    ForEach(2...7, id: \.self) { Text("\($0)/4").tag($0) }
                }.labelsHidden().frame(width: 64).help("Time signature")
                    .onChange(of: model.beatsPerBar) { _, _ in model.scheduleEvaluation() }
                Button { model.togglePlayback() } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 66)
                }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityIdentifier("play-toggle")
            }.padding(.horizontal, 22).padding(.vertical, 15)
            Divider()
            liveControls
            Divider()
            VSplitView {
                HSplitView {
                    editor
                    if !model.inlineLayout && !model.bottomLayout {
                        TimelineView(loop: model.loop, rowLines: model.rowLines, lineRects: lineRects, beatPosition: model.beatPosition, isPlaying: model.isPlaying, onScroll: { timelineScroll += $0 })
                            .frame(minWidth: 340)
                    }
                }
                if !model.inlineLayout && model.bottomLayout { rhythm }
            }
            Divider()
            SpectrumView(bands: model.spectrum, samples: model.outputSamples, isPlaying: model.isPlaying)
            Divider()
            HStack(spacing: 10) {
                if model.isPreparing { ProgressView().controlSize(.mini) }
                else { Circle().fill(model.diagnostic.isEmpty ? Color.mint : .orange).frame(width: 6, height: 6) }
                Text(model.status).font(.system(size: 11))
                if !model.completionStatus.isEmpty {
                    Text(model.completionStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).help(model.completionStatus)
                }
                Spacer()
                if let revision = model.currentRevision {
                    Text("LOOP r\(revision) / EDIT r\(model.revision)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Menu {
                    Button("Inline Results") { model.inlineLayout = true }
                    Button("Side Timeline") { model.inlineLayout = false; model.bottomLayout = false }
                    Button("Bottom Overview") { model.inlineLayout = false; model.bottomLayout = true }
                } label: {
                    Label(model.inlineLayout ? "Inline Results" : (model.bottomLayout ? "Bottom Overview" : "Side Timeline"), systemImage: "rectangle.3.group")
                }.menuStyle(.borderlessButton).fixedSize().help("Rhythm display layout")
            }.padding(.horizontal, 18).padding(.vertical, 10)
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.08))
        .preferredColorScheme(.dark)
        .frame(minWidth: 850, minHeight: 540)
        .task {
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .milliseconds(33)) }
                catch { break }
            }
        }
    }

    private var liveControls: some View {
        HStack(spacing: 21) {
            VStack(alignment: .leading, spacing: 5) {
                Text("LIVE MASTER").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                Text("\(Int(model.bpm.rounded())) BPM").font(.system(size: 10, design: .monospaced)).foregroundStyle(.mint)
            }.frame(width: 100, alignment: .leading)
            control("TEMPO", value: $model.bpm, in: 40...240, label: "\(Int(model.bpm.rounded())) BPM")
            control("FILTER", value: Binding(
                get: { log10(model.lowPass) }, set: { model.lowPass = pow(10, $0) }),
                in: log10(20)...log10(20_000),
                label: model.lowPass >= 19_999 ? "OPEN" : "\(Int(model.lowPass)) Hz")
            control("DELAY", value: $model.delayMix, in: 0...1, label: "\(Int(model.delayMix * 100))%")
            control("REVERB", value: $model.reverbMix, in: 0...1, label: "\(Int(model.reverbMix * 100))%")
        }.padding(.horizontal, 21).padding(.vertical, 10)
            .background(.white.opacity(0.025))
    }

    private func control(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, label: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(label).foregroundStyle(.mint)
            }.font(.system(size: 9, weight: .medium, design: .monospaced))
            Slider(value: value, in: range).tint(.mint)
                .accessibilityLabel(title).accessibilityValue(label)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "swift").foregroundStyle(.orange)
                Text(model.fileURL?.lastPathComponent ?? "Session.swift")
                if model.hasUnsavedChanges { Circle().fill(.secondary).frame(width: 5, height: 5) }
                Spacer()
                Text("SWIFT MUSIC").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 21).frame(height: 40)
            Divider()
            CodeEditor(text: $model.source, inlineLoop: model.loop, inlineEnabled: model.inlineLayout, resultLines: model.resultLines,
                beatPosition: model.beatPosition, isPlaying: model.isPlaying, selectionLine: model.selectionLine, selectionToken: model.selectionToken,
                rhythmLines: Array(Set(model.rowLines.values)).sorted(), rowLines: model.rowLines,
                patternTexts: Dictionary(uniqueKeysWithValues: (model.loop?.rows ?? []).compactMap { row in row.patternText.map { (row.sourceID, $0) } }),
                activeTokens: model.activeTokens,
                scrollDelta: timelineScroll, onLayout: { lineRects = $0 },
                beforeEdit: model.beforeEdit, onEdit: model.sourceChanged,
                completions: { source, offset in try await model.completions(source: source, utf16Offset: offset) },
                onCompletionStatus: { model.completionStatus = $0 })
            if !model.diagnostic.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button { model.revealDiagnostic() } label: {
                        Label("Edit needs attention", systemImage: "exclamationmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    }.buttonStyle(.plain).disabled(!model.diagnostic.contains("Session.swift:"))
                    ScrollView {
                        Text(model.diagnostic).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 130)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.07))
            }
        }.frame(minWidth: 350, minHeight: 220)
    }

    private var rhythm: some View {
        RhythmView(loop: model.loop, beatPosition: model.beatPosition, isPlaying: model.isPlaying, revealTrack: model.revealTrack)
            .frame(minWidth: 340, minHeight: 230)
    }
}
