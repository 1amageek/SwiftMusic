import SwiftUI
import MusicPlaygourndCore

struct SpectrumView: View {
    let bands: [Float]
    let samples: [Float]
    let isPlaying: Bool
    var performance: PlaybackPerformanceSnapshot? = nil
    var resetDiagnostics: () -> Void = {}

    @State private var diagnosticsPresented = false

    var body: some View {
        Button { diagnosticsPresented = true } label: {
        VStack(spacing: 5) {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
            Canvas { context, size in
                for channel in 0..<2 {
                    let center = size.height * 0.5
                    var wave = Path()
                    let frames = samples.count / 2
                    for point in 0..<256 {
                        let x = Double(point) / 255 * size.width
                        var sample = 0.0
                        if isPlaying, frames > 0 {
                            let index = min(frames - 1, point * frames / 256)
                            sample = Double(samples[index * 2 + channel])
                        }
                        let position = CGPoint(x: x, y: center - sample * size.height * 0.45)
                        if point == 0 { wave.move(to: position) } else { wave.addLine(to: position) }
                    }
                    context.stroke(wave, with: .color(channel == 0 ? .mint : .cyan.opacity(0.65)), lineWidth: 1)
                }
            }.frame(height: 30).accessibilityLabel("Stereo master output waveform")
            Text("MASTER OUTPUT").font(.system(size: 7, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: 5) {
            Canvas { context, size in
                let plotHeight = size.height
                for db in [-18, -48, -78] {
                    let y = Double(-db) / 90 * plotHeight
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(.white.opacity(0.055)))
                }
                let width = size.width / Double(max(1, bands.count))
                for (index, db) in bands.enumerated() {
                    let height = max(0, Double(db + 90) / 90 * plotHeight)
                    let rect = CGRect(x: Double(index) * width, y: plotHeight - height, width: max(1, width - 2), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .linearGradient(
                        Gradient(colors: [.cyan.opacity(0.25), .mint]), startPoint: CGPoint(x: 0, y: plotHeight), endPoint: .zero))
                }

            }
            .frame(height: 30)
            .accessibilityLabel("Master output spectrum, 20 hertz to 20 kilohertz, \(isPlaying ? "playing" : "paused")")
            Text(performance?.clipped == true ? "SPECTRUM · CLIP" : "SPECTRUM")
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(performance?.clipped == true ? Color.orange : .secondary)
            }.frame(maxWidth: .infinity)
        }.frame(height: 44)
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
            }.padding(16).frame(width: 420)
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
        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(height: 18)
    }

}
