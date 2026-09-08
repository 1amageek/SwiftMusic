import AppKit
import MusicPlaygourndCore
import SwiftUI
import UniformTypeIdentifiers

struct LiveControlsView: View {
    @Bindable var model: SessionModel
    @State private var expanded = true
    @State private var maximumTakeMinutes = 10

    private var descriptors: [LiveControlDescriptor] { model.controlCatalog?.descriptors ?? [] }
    private var targets: [LiveControlTarget] {
        var seen = Set<LiveControlTarget>()
        return descriptors.compactMap { seen.insert($0.address.target).inserted ? $0.address.target : nil }
    }

    var body: some View {
        DisclosureGroup("Live Controls", isExpanded: $expanded) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    if !targets.isEmpty { Picker("Controls", selection: Binding(get: { model.selectedControl?.target ?? .master }, set: { target in
                        model.selectedControl = descriptors.first { $0.address.target == target }?.address
                    })) {
                        ForEach(targets, id: \.self) { Text(label($0)).tag($0) }
                    }.accessibilityIdentifier("control-group") }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(descriptors.filter { $0.address.target == model.selectedControl?.target }, id: \.address) { descriptor in
                            if let presentation = descriptor.presentation {
                                ControlKnob(label: descriptor.label, value: model.controlValue(descriptor), presentation: presentation,
                                    selected: model.selectedControl == descriptor.address, onChange: { value in
                                        model.selectedControl = descriptor.address
                                        perform { try model.setControl(descriptor.address, value: .number(value)) }
                                    }, onRelease: { perform { try model.setControl(descriptor.address, value: nil) } },
                                    onFailure: { model.hostDiagnostic = $0.localizedDescription })
                                .disabled(descriptor.address.target != .master && !model.controlsAvailable)
                                .contextMenu {
                                    Button("MIDI Learn") { perform { try model.beginMIDILearn(descriptor.address) } }
                                        .disabled(model.midiRoute.input == nil)
                                    Button("Remove MIDI Binding") { model.clearMIDILearn(descriptor.address) }
                                }
                            }
                        }
                    }
                    if descriptors.isEmpty { Text("Play a score to expose its controls.").foregroundStyle(.secondary) }
                    if let address = model.selectedControl {
                        HStack {
                            Button(model.learnAddress == address ? "Cancel Learn" : "MIDI Learn") {
                                if model.learnAddress == address { model.clearMIDILearn(address) }
                                else { perform { try model.beginMIDILearn(address) } }
                            }.disabled(model.midiRoute.input == nil)
                            if let binding = model.learnedBindings.first(where: { $0.address == address }) {
                                Text("CH \(binding.channel) · CC \(binding.controller)").font(.caption.monospaced())
                            }
                        }
                    }
                }.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                xyPad.frame(width: 190)
                hostControls.frame(width: 250).disabled(model.isRestoringHostState)
            }.padding(.top, 10)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .font(.system(size: 11))
        .task {
            do { try await model.refreshHostDevices() }
            catch is CancellationError { }
            catch { model.hostDiagnostic = error.localizedDescription }
        }
    }

    private var xyPad: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("X", selection: $model.xyX) {
                    Text("Choose X").tag(Optional<LiveControlAddress>.none)
                    ForEach(model.xyControls, id: \.address) { Text($0.label).tag(Optional($0.address)) }
                }
                Picker("Y", selection: $model.xyY) {
                    Text("Choose Y").tag(Optional<LiveControlAddress>.none)
                    ForEach(model.xyControls, id: \.address) { Text($0.label).tag(Optional($0.address)) }
                }
            }.labelsHidden()
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.mint.opacity(0.06))
                    Path { path in
                        for fraction in [0.25, 0.5, 0.75] {
                            path.move(to: .init(x: geometry.size.width * fraction, y: 0))
                            path.addLine(to: .init(x: geometry.size.width * fraction, y: geometry.size.height))
                            path.move(to: .init(x: 0, y: geometry.size.height * fraction))
                            path.addLine(to: .init(x: geometry.size.width, y: geometry.size.height * fraction))
                        }
                    }.stroke(.mint.opacity(0.15), lineWidth: 1)
                    Circle().fill(.mint).frame(width: 12, height: 12)
                        .shadow(color: .mint.opacity(0.6), radius: 6)
                        .position(x: position(model.xyX) * geometry.size.width,
                                  y: (1 - position(model.xyY)) * geometry.size.height)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let x = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                    let y = min(1, max(0, 1 - value.location.y / max(1, geometry.size.height)))
                    perform { try model.setXY(x: x, y: y) }
                })
                .accessibilityLabel("XY score control pad")
                .accessibilityIdentifier("xy-pad")
            }.frame(height: 105)
            Slider(value: Binding(get: { position(model.xyX) }, set: { x in
                perform { try model.setXY(x: x, y: position(model.xyY)) }
            }), in: 0...1).accessibilityLabel("X axis")
            Slider(value: Binding(get: { position(model.xyY) }, set: { y in
                perform { try model.setXY(x: position(model.xyX), y: y) }
            }), in: 0...1).accessibilityLabel("Y axis")
        }.disabled(!model.controlsAvailable || model.xyX == nil || model.xyY == nil || model.xyX == model.xyY)
    }

    private var hostControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("MIDI Input", selection: Binding(get: { model.midiRoute.input }, set: { input in
                    var route = model.midiRoute; route.input = input
                    if case .receive = route.clockMode { route.clockMode = input.map { .receive(input: $0) } ?? .off }
                    perform { try await model.configureMIDI(route) }
                })) {
                    Text("No MIDI input").tag(Optional<MIDIEndpointID>.none)
                    ForEach(model.midiEndpoints.filter { $0.direction == .input }, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
                }.labelsHidden().accessibilityIdentifier("midi-input")
                Button { perform { try await model.refreshHostDevices() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh MIDI and Audio Units")
            }
            Picker("MIDI Output", selection: Binding(get: { model.midiRoute.output }, set: { output in
                var route = model.midiRoute; route.output = output
                if output == nil { route.sendsLoopNotes = false }
                if case .send = route.clockMode { route.clockMode = output.map { .send(output: $0) } ?? .off }
                perform { try await model.configureMIDI(route) }
            })) {
                Text("No MIDI output").tag(Optional<MIDIEndpointID>.none)
                ForEach(model.midiEndpoints.filter { $0.direction == .output }, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
            }.labelsHidden()
            HStack {
                Toggle("Notes", isOn: Binding(get: { model.midiRoute.sendsLoopNotes }, set: { enabled in
                    var route = model.midiRoute; route.sendsLoopNotes = enabled
                    perform { try await model.configureMIDI(route) }
                })).toggleStyle(.checkbox).disabled(model.midiRoute.output == nil)
                Picker("Clock", selection: Binding(get: { model.midiRoute.clockMode }, set: { mode in
                    var route = model.midiRoute; route.clockMode = mode
                    perform { try await model.configureMIDI(route) }
                })) {
                    Text("Clock Off").tag(MIDIClockMode.off)
                    if let output = model.midiRoute.output { Text("Send Clock").tag(MIDIClockMode.send(output: output)) }
                    if let input = model.midiRoute.input { Text("Receive Clock").tag(MIDIClockMode.receive(input: input)) }
                }.labelsHidden()
            }
            Picker("Audio Unit", selection: Binding(get: {
                if case .loaded(let descriptor, _) = model.hostedEffect { return Optional(descriptor.id) }
                return nil
            }, set: { id in perform { try await model.selectHostedEffect(id) } })) {
                Text("No Audio Unit").tag(Optional<HostedAudioUnitID>.none)
                ForEach(model.audioEffects, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().disabled(model.isLoadingEffect || model.isRecording)
                .accessibilityIdentifier("audio-unit-picker")
            if case .loaded(let descriptor, let bypassed) = model.hostedEffect {
                Toggle("Bypass \(descriptor.name)", isOn: Binding(get: { bypassed }, set: { value in
                    perform { try model.bypassHostedEffect(value) }
                })).toggleStyle(.checkbox)
            }
            HStack {
                Picker("Maximum take", selection: $maximumTakeMinutes) {
                    ForEach([1, 5, 10, 30, 60, 120, 180], id: \.self) { Text("\($0) min").tag($0) }
                }.labelsHidden().disabled(model.isRecording)
                if model.isRecording {
                    Button("Stop & Save") { perform { _ = try await model.stopRecording() } }
                    Button("Discard") { perform { try await model.cancelRecording() } }
                } else {
                    Button("Record") { record() }.disabled(!model.isPlaying)
                }
            }
            HStack {
                Button(model.isExportingStems ? "Cancel Export" : "Export Stems") {
                    if model.isExportingStems { perform { try await model.cancelStemExport() } }
                    else { exportStems() }
                }.disabled(!model.controlsAvailable && !model.isExportingStems)
                Button("Save Settings") {
                    guard let document = model.fileURL else { return }
                    perform { try model.saveHostSettings(for: document) }
                }.disabled(model.fileURL == nil)
            }
        }
    }

    private func position(_ address: LiveControlAddress?) -> Double {
        guard let address, let descriptor = model.controlCatalog?.descriptor(for: address),
              let presentation = descriptor.presentation, let value = model.controlValue(descriptor) else { return 0.5 }
        return ControlKnob.position(value, in: presentation)
    }

    private func label(_ target: LiveControlTarget) -> String {
        switch target {
        case .source(let id): "Source \(id)"
        case .renderNode(let id): "Group \(id)"
        case .track(let id): "Track \(id)"
        case .master: "Master"
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() }
            catch is CancellationError { }
            catch { model.hostDiagnostic = error.localizedDescription }
        }
    }

    private func record() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Take.wav"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform { try model.startRecording(to: destination, maximumDuration: .seconds(maximumTakeMinutes * 60)) }
    }

    private func exportStems() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Stems"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform { _ = try await model.exportStems(to: destination) }
    }
}
