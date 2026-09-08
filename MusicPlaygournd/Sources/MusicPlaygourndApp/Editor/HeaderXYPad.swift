import SwiftUI

/// Controls the global filter and reverb without editing the score.
struct HeaderXYPad: View {
    @Bindable var model: SessionModel

    private var cutoff: Double {
        guard let descriptor = model.controlCatalog?.descriptors.first(where: { $0.address.target == .master && $0.address.parameter == .lowPassCutoff }) else { return model.lowPass }
        return model.controlValue(descriptor) ?? 20_000
    }
    private var space: Double {
        guard let descriptor = model.controlCatalog?.descriptors.first(where: { $0.address.target == .master && $0.address.parameter == .reverbMix }) else { return model.reverbMix }
        return model.controlValue(descriptor) ?? 0
    }
    private var x: Double { min(1, max(0, log(cutoff / 20) / log(1_000))) }
    private var y: Double { min(1, max(0, space)) }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.025))
                    Path { path in
                        for index in 1..<8 {
                            let fraction = Double(index) / 8
                            path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                            path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                        }
                        for fraction in [0.25, 0.5, 0.75] {
                            path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                        }
                    }.stroke(.white.opacity(0.05), lineWidth: 1)
                    Path { path in
                        path.move(to: CGPoint(x: x * geometry.size.width, y: 0))
                        path.addLine(to: CGPoint(x: x * geometry.size.width, y: geometry.size.height))
                        path.move(to: CGPoint(x: 0, y: (1 - y) * geometry.size.height))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: (1 - y) * geometry.size.height))
                    }.stroke(.mint.opacity(0.35), lineWidth: 0.5)
                    Circle().fill(.mint).frame(width: 7, height: 7)
                        .position(x: x * geometry.size.width, y: (1 - y) * geometry.size.height)
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.12)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    model.lowPass = 20 * Foundation.pow(1_000, min(1, max(0, event.location.x / max(1, geometry.size.width))))
                    model.reverbMix = min(1, max(0, 1 - event.location.y / max(1, geometry.size.height)))
                })
                .accessibilityRepresentation {
                    VStack {
                        Slider(value: Binding(get: { x }, set: { model.lowPass = 20 * Foundation.pow(1_000, $0) }), in: 0...1).accessibilityLabel("Master filter")
                        Slider(value: Binding(get: { y }, set: { model.reverbMix = $0 }), in: 0...1).accessibilityLabel("Master space")
                    }
                }
                .accessibilityIdentifier("master-xy-pad")
                .help("X: master low-pass filter, 20 Hz–20 kHz. Y: master reverb, 0–100%.")
            }
            HStack {
                Text("FILTER →")
                Spacer()
                Text("SPACE ↑")
            }.font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
