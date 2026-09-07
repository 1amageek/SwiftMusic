import SwiftUI
import MusicPlaygourndCore

struct SpectrumView: View {
    let bands: [Float]
    let samples: [Float]
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 21) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(isPlaying ? Color.mint : .gray).frame(width: 5, height: 5)
                    Text("SPECTRUM").tracking(2)
                }.font(.system(size: 10, weight: .semibold, design: .monospaced))
                Text("MASTER OUTPUT").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Text("20 Hz — 20 kHz").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(width: 145, alignment: .leading)
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
            }.frame(width: 170).accessibilityLabel("Stereo master output waveform")
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            Canvas { context, size in
                let plotHeight = size.height - 18
                for db in [-12, -36, -60, -84] {
                    let y = Double(-db) / 90 * plotHeight
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width - 28, y: y))
                    context.stroke(grid, with: .color(.white.opacity(0.055)))
                    context.draw(Text("\(db)").font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: size.width - 10, y: y))
                }
                let width = (size.width - 34) / Double(max(1, bands.count))
                for (index, db) in bands.enumerated() {
                    let height = max(0, Double(db + 90) / 90 * plotHeight)
                    let rect = CGRect(x: Double(index) * width, y: plotHeight - height, width: max(1, width - 2), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .linearGradient(
                        Gradient(colors: [.cyan.opacity(0.25), .mint]), startPoint: CGPoint(x: 0, y: plotHeight), endPoint: .zero))
                }
                for frequency in [20, 100, 1000, 10000, 20000] {
                    let x = log(Double(frequency) / 20) / log(1000) * (size.width - 34)
                    context.draw(Text(frequency >= 1000 ? "\(frequency / 1000)k" : "\(frequency)")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                        at: CGPoint(x: max(8, x), y: size.height - 5))
                }
            }
            .accessibilityLabel("Master output spectrum, 20 hertz to 20 kilohertz, \(isPlaying ? "playing" : "paused")")
        }.padding(.horizontal, 21).padding(.vertical, 13).frame(height: 130)
            .background(Color(red: 0.035, green: 0.045, blue: 0.055))
    }
}
