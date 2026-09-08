import SwiftUI

struct ContentView: View {
    @Bindable var model: SessionModel
    @State private var lineRects: [Int: CGRect] = [:]
    @State private var timelineScroll: CGFloat = 0
    @State private var logsExpanded = false

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
                    TextField("BPM", value: Binding(get: { model.displayedBPM }, set: { model.bpm = $0 }), format: .number.precision(.fractionLength(0)))
                        .frame(width: 44).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("tempo-field")
                    Stepper("Tempo", value: Binding(get: { model.displayedBPM }, set: { model.bpm = $0 }), in: 40...240, step: 1).labelsHidden()
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
            LiveControlsView(model: model)
            Divider()
            VSplitView {
                HSplitView {
                    editor
                    if !model.inlineLayout && !model.bottomLayout {
                        VStack(spacing: 0) {
                        TimelineView(loop: model.loop, rowLines: model.rowLines, lineRects: lineRects, beatPosition: model.beatPosition, isPlaying: model.isPlaying, onScroll: { timelineScroll += $0 })
                            .frame(minWidth: 340)
                        selectedResult
                        }
                    }
                }
                if !model.inlineLayout && model.bottomLayout { rhythm }
            }
            Divider()
            SpectrumView(bands: model.spectrum, samples: model.outputSamples, isPlaying: model.isPlaying,
                loop: model.loop, beatPosition: model.beatPosition, performance: model.performance,
                resetDiagnostics: model.resetPerformanceDiagnostics)
            Divider()
            logs
            Divider()
            HStack(spacing: 10) {
                if model.isPreparing { ProgressView().controlSize(.mini) }
                else { Circle().fill(diagnosticCount == 0 ? Color.mint : .orange).frame(width: 6, height: 6) }
                Text(model.status).font(.system(size: 11))
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
                onCompletionStatus: { model.completionStatus = $0 }, selectionRange: model.selectionRange, visualization: model.controlVisualization)
        }.frame(minWidth: 350, minHeight: 220)
    }

    @ViewBuilder
    private var logs: some View {
        DisclosureGroup(isExpanded: $logsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.diagnostic.isEmpty {
                    Button { model.revealDiagnostic() } label: {
                        Label("Edit needs attention", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.diagnosticRange == nil)
                    ScrollView {
                        Text(model.diagnostic)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }
                if !model.hostDiagnostic.isEmpty {
                    Text(model.hostDiagnostic).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
                if diagnosticCount == 0 {
                    Text("No diagnostics")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !model.completionStatus.isEmpty {
                    Divider()
                    Text(model.completionStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .help(model.completionStatus)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: diagnosticCount == 0 ? "doc.text" : "exclamationmark.circle.fill")
                    .foregroundStyle(diagnosticCount == 0 ? Color.secondary : Color.orange)
                Text("Logs")
                Spacer()
                Text(diagnosticCountLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(diagnosticCount == 0 ? Color.secondary : Color.orange)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(diagnosticCount == 0 ? Color.white.opacity(0.025) : Color.orange.opacity(0.07))
    }

    private var diagnosticCount: Int { (model.diagnostic.isEmpty ? 0 : 1) + (model.hostDiagnostic.isEmpty ? 0 : 1) }

    private var diagnosticCountLabel: String {
        let count = diagnosticCount
        return "\(count) error\(count == 1 ? "" : "s")"
    }

    private var rhythm: some View {
        VStack(spacing: 0) {
        RhythmView(loop: model.loop, beatPosition: model.beatPosition, isPlaying: model.isPlaying, revealTrack: model.revealTrack)
            .frame(minWidth: 340, minHeight: 230)
        selectedResult
        }
    }
    @ViewBuilder private var selectedResult: some View {
        if let visualization = model.controlVisualization {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.visualizationStatus).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                ControlTraceResult(visualization: visualization).frame(height: 88)
            }.padding(8)
        }
    }

}
