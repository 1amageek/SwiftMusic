import SwiftUI

struct ContentView: View {
    @Bindable var model: SessionModel

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
                        .onSubmit { model.scheduleEvaluation(immediate: true) }
                        .accessibilityIdentifier("tempo-field")
                    Stepper("Tempo", value: $model.bpm, in: 40...240, step: 1).labelsHidden()
                        .onChange(of: model.bpm) { _, _ in model.scheduleEvaluation() }
                }
                Picker("Meter", selection: $model.beatsPerBar) {
                    ForEach(2...7, id: \.self) { Text("\($0)/4").tag($0) }
                }.frame(width: 88)
                    .onChange(of: model.beatsPerBar) { _, _ in model.scheduleEvaluation() }
                Button { model.togglePlayback() } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 66)
                }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityIdentifier("play-toggle")
            }.padding(.horizontal, 22).padding(.vertical, 15)
            Divider()
            if model.bottomLayout {
                VSplitView { editor; rhythm }
            } else {
                HSplitView { editor; rhythm }
            }
            Divider()
            HStack(spacing: 10) {
                if model.isPreparing { ProgressView().controlSize(.mini) }
                else { Circle().fill(model.diagnostic.isEmpty ? Color.mint : .orange).frame(width: 6, height: 6) }
                Text(model.status).font(.system(size: 11))
                Spacer()
                if let revision = model.currentRevision {
                    Text("PLAYING r\(revision) / EDIT r\(model.revision)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button { model.bottomLayout.toggle() } label: {
                    Image(systemName: model.bottomLayout ? "rectangle.split.2x1" : "rectangle.split.1x2")
                }.buttonStyle(.plain).help("Switch rhythm view position")
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
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            CodeEditor(text: $model.source, selectionLine: model.selectionLine, selectionToken: model.selectionToken, onEdit: model.sourceChanged)
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
