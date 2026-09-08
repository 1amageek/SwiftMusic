import MusicPlaygourndCore
import SwiftUI

struct ControlKnob: View {
    let label: String
    let value: Double?
    let presentation: LiveControlPresentation
    let selected: Bool
    let onChange: (Double) -> Void
    let onRelease: () -> Void
    let onFailure: (Error) -> Void
    @State private var dragStart: Double?

    static func position(_ value: Double, in range: LiveControlPresentation) -> Double {
        guard value.isFinite else { return 0.5 }
        let fraction = range.scale == .logarithmic
            ? (log(max(range.minimum, value)) - log(range.minimum)) / (log(range.maximum) - log(range.minimum))
            : (value - range.minimum) / (range.maximum - range.minimum)
        return min(1, max(0, fraction))
    }

    private var position: Double { value.map { Self.position($0, in: presentation) } ?? 0.5 }
    private var text: String {
        guard let value else { return "Score" }
        if presentation.unit == .ratio { return String(format: "%.0f BPM", value * 120) }
        return String(format: "%.2g", value)
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().trim(from: 0.12, to: 0.88).stroke(.white.opacity(0.12), lineWidth: 4).rotationEffect(.degrees(90))
                Circle().trim(from: 0.12, to: 0.12 + 0.76 * position).stroke(.mint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(90))
                Circle().fill(.white.opacity(selected ? 0.12 : 0.05)).padding(6)
                Capsule().fill(.mint).frame(width: 2, height: 12).offset(y: -15)
                    .rotationEffect(.degrees(-137 + position * 274))
            }.frame(width: 48, height: 48)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    if dragStart == nil { dragStart = position }
                    change(min(1, max(0, (dragStart ?? position) - event.translation.height / 160)))
                }.onEnded { _ in dragStart = nil })
                .accessibilityElement().accessibilityLabel(label).accessibilityValue(text)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: change(min(1, position + 0.025))
                    case .decrement: change(max(0, position - 0.025))
                    @unknown default: break
                    }
                }
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.mint)
            Text(label).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center)
            Button("Release", action: onRelease).font(.system(size: 9)).buttonStyle(.plain)
                .accessibilityLabel("Release \(label) to score")
        }.frame(width: 64)
    }

    private func change(_ position: Double) {
        // Position is clamped above and the catalog validates the mapping before UI adoption.
        do { onChange(try presentation.value(at: position)) }
        catch { onFailure(error) }
    }
}
