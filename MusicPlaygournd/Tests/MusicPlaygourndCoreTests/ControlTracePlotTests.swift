import AppKit
import Testing
@testable import MusicPlaygourndApp
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @MainActor
    struct ControlTracePlotTests {
        @Test(.timeLimit(.minutes(3)))
        func bitmapDrawsMultipleVoicesAcrossLoopWrapWithoutEditingSource() throws {
            let address = LiveControlAddress(
                revision: 1, target: .source(0), parameter: .gain)
            let selectedValues = PreparedControlTrace.Channel(
                kind: .selectedValue,
                points: [
                    .init(beat: 0.25, value: 0.2),
                    .init(beat: 1.0, value: 0.8),
                    .init(beat: 1.75, value: 0.4)
                ])
            let firstEnvelope = PreparedControlTrace.Channel(
                kind: .amplitudeEnvelope,
                points: [
                    .init(beat: 0.25, value: 0.1),
                    .init(beat: 1.0, value: 0.6),
                    .init(beat: 1.75, value: 0.2)
                ])
            let wrappedValues = PreparedControlTrace.Channel(
                kind: .selectedValue,
                points: [
                    .init(beat: 3.25, value: 0.3),
                    .init(beat: 4.0, value: 0.9),
                    .init(beat: 4.75, value: 0.5)
                ])
            let wrappedEnvelope = PreparedControlTrace.Channel(
                kind: .amplitudeEnvelope,
                points: [
                    .init(beat: 3.25, value: 0.15),
                    .init(beat: 4.0, value: 0.7),
                    .init(beat: 4.75, value: 0.25)
                ])
            let visualization = try PreparedControlVisualization(
                address: address,
                unit: .amplitude,
                beatCount: 4,
                traces: [
                    .init(eventIndex: 0, sourceID: 0, startBeat: 0.25, durationBeats: 1.5,
                          wrapsLoopBoundary: false, channels: [selectedValues, firstEnvelope]),
                    .init(eventIndex: 1, sourceID: 0, startBeat: 3.25, durationBeats: 1.5,
                          wrapsLoopBoundary: true, channels: [wrappedValues, wrappedEnvelope])
                ])

            let editor = CompletionTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
            editor.isRichText = false
            editor.allowsUndo = true
            editor.string = "Synthesizer(.sine).notes(\"C4\")"
            editor.setSelectedRange((editor.string as NSString).range(of: "C4"))
            let source = editor.string
            let selection = editor.selectedRange()
            let undoState = editor.undoManager?.canUndo

            let plot = ControlTracePlot(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
            plot.visualization = visualization
            plot.layoutSubtreeIfNeeded()
            let bitmap = try #require(plot.bitmapImageRepForCachingDisplay(in: plot.bounds))
            plot.cacheDisplay(in: plot.bounds, to: bitmap)

            func coloredPixels(in xRange: ClosedRange<Int>) -> Int {
                var count = 0
                for x in xRange {
                    for y in 0..<bitmap.pixelsHigh {
                        guard let color = bitmap.colorAt(x: x, y: y),
                              let rgb = color.usingColorSpace(.deviceRGB) else { continue }
                        let high = max(rgb.redComponent, max(rgb.greenComponent, rgb.blueComponent))
                        let low = min(rgb.redComponent, min(rgb.greenComponent, rgb.blueComponent))
                        if rgb.alphaComponent > 0.05 && high - low > 0.05 { count += 1 }
                    }
                }
                return count
            }

            #expect(visualization.traces.count == 2)
            #expect(visualization.traces.contains { $0.wrapsLoopBoundary })
            #expect(coloredPixels(in: 20...120) > 0)
            #expect(coloredPixels(in: 300...380) > 0)
            #expect(editor.string == source)
            #expect(editor.selectedRange() == selection)
            #expect(editor.undoManager?.canUndo == undoState)
        }
    }
}
