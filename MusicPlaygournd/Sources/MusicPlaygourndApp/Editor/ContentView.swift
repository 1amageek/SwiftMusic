import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: SessionModel
    @State private var lineRects: [Int: CGRect] = [:]
    @State private var timelineScroll: CGFloat = 0
    @State private var logsExpanded = false
    @State private var controlsPresented = false
    @State private var maximumTakeMinutes = 10
    @State private var sidebarVisible = true
    @State private var fileBrowser = SessionFileBrowser()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                if sidebarVisible {
                    FileSidebarView(model: model, browser: fileBrowser)
                        .frame(minWidth: 160, idealWidth: 190, maxWidth: 260)
                }
            VStack(spacing: 0) {
                FileTabsView(model: model)
                Divider()
            VSplitView {
                HSplitView {
                    editor
                    if !model.inlineLayout && !model.bottomLayout {
                        TimelineView(loop: model.editorLoop, rowLines: model.rowLines, lineRects: lineRects, beatPosition: model.beatPosition, isPlaying: model.isPlaying, onScroll: { timelineScroll += $0 }, mutedTracks: model.rowMuteStates, onToggleTrackMute: model.toggleTrackMute)
                            .frame(minWidth: 340)
                    }
                }
                if !model.inlineLayout && model.bottomLayout { rhythm }
            }
            }
            }
            Divider()
            logs
            Divider()
            HStack(spacing: 10) {
                if model.isPreparing { ProgressView().controlSize(.mini) }
                else { Circle().fill(diagnosticCount == 0 ? Color.mint : .orange).frame(width: 6, height: 6) }
                Text(model.status).font(.system(size: 11))
                Spacer()
                if let revision = model.currentRevision {
                    Text("\(model.audibleDocumentID == model.activeDocumentID ? "LOOP" : "OTHER TAB") r\(revision) / EDIT r\(model.revision)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
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

    private var header: some View {
        HStack(spacing: 16) {
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 15))
                    .frame(width: 24, height: 38)
            }.buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(sidebarVisible ? "Hide files" : "Show files")
                .accessibilityIdentifier("toggle-file-sidebar")
            HStack(spacing: 14) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(.primary)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("play-toggle")
                Button(action: record) {
                    Image(systemName: model.isRecording ? "stop.circle" : "record.circle")
                        .font(.system(size: 18)).foregroundStyle(model.isRecording ? Color.red : .secondary)
                }.buttonStyle(.plain).disabled(!model.isPlaying && !model.isRecording)
                    .accessibilityLabel(model.isRecording ? "Stop and save recording" : "Record")
                    .accessibilityIdentifier("record-toggle")
                VStack(alignment: .leading, spacing: 2) {
                    Text("BPM").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1)
                        .foregroundStyle(.secondary)
                    TextField("BPM", value: Binding(get: { model.displayedBPM }, set: { model.bpm = $0 }), format: .number.precision(.fractionLength(0)))
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .textFieldStyle(.plain).frame(width: 60)
                        .accessibilityLabel("Tempo in BPM").accessibilityIdentifier("tempo-field")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("TIME").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1)
                        .foregroundStyle(.secondary)
                    Picker("Meter", selection: $model.beatsPerBar) {
                        ForEach(2...7, id: \.self) { Text("\($0)/4").tag($0) }
                    }.labelsHidden().controlSize(.small).frame(width: 62)
                        .onChange(of: model.beatsPerBar) { _, _ in model.scheduleEvaluation() }
                }
            }
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 32)
            SpectrumView(bands: model.spectrum, samples: model.outputSamples, isPlaying: model.isPlaying,
                performance: model.performance,
                resetDiagnostics: model.resetPerformanceDiagnostics)
                .frame(minWidth: 190, maxWidth: .infinity)
            HeaderXYPad(model: model).frame(width: 160, height: 52)
            Button { controlsPresented = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17))
                    .frame(width: 32, height: 38)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).accessibilityLabel("Controls")
                .accessibilityIdentifier("editor-controls")
                .popover(isPresented: $controlsPresented, arrowEdge: .bottom) {
                    LiveControlsView(model: model, maximumTakeMinutes: $maximumTakeMinutes)
                        .frame(width: 780, height: 420)
                }
        }.padding(.horizontal, 20).frame(height: 76)
            .background(Color(red: 0.045, green: 0.055, blue: 0.065))
    }

    private func record() {
        if model.isRecording {
            Task { @MainActor in
                do { _ = try await model.stopRecording() }
                catch { model.hostDiagnostic = error.localizedDescription }
            }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Take.wav"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try model.startRecording(to: destination, maximumDuration: .seconds(maximumTakeMinutes * 60)) }
        catch { model.hostDiagnostic = error.localizedDescription }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            CodeEditor(text: $model.source, inlineLoop: model.editorLoop, inlineEnabled: model.inlineLayout, resultLines: model.resultLines,
                beatPosition: model.beatPosition, isPlaying: model.isPlaying, selectionLine: model.selectionLine, selectionToken: model.selectionToken,
                rhythmLines: Array(Set(model.rowLines.values)).sorted(), rowLines: model.rowLines,
                patternTexts: Dictionary(uniqueKeysWithValues: (model.editorLoop?.rows ?? []).compactMap { row in row.patternText.map { (row.sourceID, $0) } }),
                activeTokens: model.activeTokens,
                scrollDelta: timelineScroll, onLayout: { lineRects = $0 },
                beforeEdit: model.beforeEdit, onEdit: model.sourceChanged,
                completions: { source, offset in try await model.completions(source: source, utf16Offset: offset) },
                onCompletionStatus: { model.completionStatus = $0 },
                mutedTracks: model.rowMuteStates, onToggleTrackMute: model.toggleTrackMute, selectionRange: model.selectionRange, visualization: model.editorLoop == nil ? nil : model.controlVisualization,
                documentID: model.activeDocumentID, editorState: model.activeDocument.editorState, openDocumentIDs: Set(model.documents.map(\.id)),
                onEditorStateChange: { id, state in model.documents.first { $0.id == id }?.editorState = state })
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
        RhythmView(loop: model.editorLoop, beatPosition: model.beatPosition, isPlaying: model.isPlaying, revealTrack: model.revealTrack, mutedTracks: model.rowMuteStates, onToggleTrackMute: model.toggleTrackMute)
            .frame(minWidth: 340, minHeight: 230)
        selectedResult
        }
    }
    @ViewBuilder private var selectedResult: some View {
        if model.editorLoop != nil, let visualization = model.controlVisualization {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.visualizationStatus).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                ControlTraceResult(visualization: visualization).frame(height: 88)
            }.padding(8)
        }
    }

}
