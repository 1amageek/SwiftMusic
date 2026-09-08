import SwiftUI
import MusicPlaygourndCore

struct SpectrumView: View {
    let bands: [Float]
    let samples: [Float]
    let isPlaying: Bool
    var loop: PreparedLoop? = nil
    var beatPosition: Double = 0
    var performance: PlaybackPerformanceSnapshot? = nil
    var resetDiagnostics: () -> Void = {}

    @State private var diagnosticsPresented = false

    var body: some View {
        Button { diagnosticsPresented = true } label: {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(isPlaying ? Color.mint : .gray).frame(width: 4, height: 4)
                Text("OUTPUT").tracking(1.5)
                Spacer()
                Text(performance?.clipped == true ? "CLIP" : "20 Hz — 20 kHz")
                    .foregroundStyle(performance?.clipped == true ? Color.orange : .secondary)
            }.font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
        HStack(spacing: 12) {
            Canvas { context, size in
                for channel in 0..<2 {
                    let center = size.height * (channel == 0 ? 0.3 : 0.7)
                    var wave = Path()
                    let frames = samples.count / 2
                    for point in 0..<256 {
                        let x = Double(point) / 255 * size.width
                        var sample = 0.0
                        if isPlaying, frames > 0 {
                            let index = min(frames - 1, point * frames / 256)
                            sample = Double(samples[index * 2 + channel])
                        }
                        let position = CGPoint(x: x, y: center - sample * size.height * 0.24)
                        if point == 0 { wave.move(to: position) } else { wave.addLine(to: position) }
                    }
                    context.stroke(wave, with: .color(channel == 0 ? .mint : .cyan.opacity(0.65)), lineWidth: 1)
                }
            }.frame(width: 80).accessibilityLabel("Stereo master output waveform")
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            Canvas { context, size in
                let plotHeight = size.height
                for db in [-18, -48, -78] {
                    let y = Double(-db) / 90 * plotHeight
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width - 28, y: y))
                    context.stroke(grid, with: .color(.white.opacity(0.055)))
                }
                let width = (size.width - 34) / Double(max(1, bands.count))
                for (index, db) in bands.enumerated() {
                    let height = max(0, Double(db + 90) / 90 * plotHeight)
                    let rect = CGRect(x: Double(index) * width, y: plotHeight - height, width: max(1, width - 2), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .linearGradient(
                        Gradient(colors: [.cyan.opacity(0.25), .mint]), startPoint: CGPoint(x: 0, y: plotHeight), endPoint: .zero))
                }

            }
            .accessibilityLabel("Master output spectrum, 20 hertz to 20 kilohertz, \(isPlaying ? "playing" : "paused")")
        }.frame(height: 30)
        }
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Output diagnostics")
        .accessibilityIdentifier("output-diagnostics")
        .popover(isPresented: $diagnosticsPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("OUTPUT DIAGNOSTICS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                meters
            }.padding(16).frame(width: 740)
        }
    }
    private var meters: some View {
        HStack(spacing: 14) {
            if let performance {
                Text(performance.callbackLoad.map { String(format: "SOURCE CPU %.1f%%", $0 * 100) } ?? "SOURCE CPU —")
                    .help("Source callback time divided by its audio duration; excludes Audio Unit and system CPU.")
                Text("DROPOUTS \(performance.dropoutCount)")
                Text(performance.peak.map { String(format: "MASTER %.2f", $0) } ?? "MASTER —")
                Text(performance.clipped ? "CLIP" : "OK").foregroundStyle(performance.clipped ? .red : .mint)
                Button("Reset", action: resetDiagnostics).buttonStyle(.plain)
            } else { Text("Master telemetry unavailable") }
            Divider().frame(height: 12)
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(loop?.meters ?? [], id: \.target) { meter in
                        let index = min(meter.peaks.count - 1, max(0, Int(beatPosition / (loop?.beatCount ?? 1) * Double(meter.peaks.count))))
                        let peak = isPlaying ? meter.peaks[index] : 0
                        HStack(spacing: 4) {
                            Text(meter.label).help("Rendered Track/Bus signal before native master processing.")
                            ProgressView(value: Double(min(1, peak))).frame(width: 48).tint(peak >= 1 ? .red : .mint)
                            Text(peak >= 1 ? "CLIP" : String(format: "%.2f", peak))
                        }.accessibilityLabel("\(meter.label) rendered peak \(peak)")
                    }
                    if loop?.meters == nil { Text("Track/Bus meters unavailable") }
                }
            }.scrollIndicators(.hidden)
        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(height: 18)
    }

}
