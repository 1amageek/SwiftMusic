import Foundation
import MusicPlaygourndCore
import Testing

extension NativeHostTests {
    struct VisualizationWorkerTests {
        @Test(.timeLimit(.minutes(6)))
        func retainedVisualizationIsIndependentAndFailureSafe() async throws {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let workspace = package.appending(path: ".build/visualization-worker-\(UUID().uuidString)")
            let evaluator = SourceEvaluator(
                packageURL: package,
                workspace: workspace,
                swiftExecutable: "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )
            let source = """
            struct Session: Music {
                var body: some Sound {
                    Synthesizer(.sine).notes("A4 A4").gain(0.4)
                }
            }
            """
            let revision: UInt64 = 73_100

            do {
                let retained = try await evaluator.evaluateRetained(
                    source: source, bpm: 120, beatsPerBar: 4, revision: revision)
                #expect(await evaluator.adopt(revision: revision))

                let gainAddress = try #require(retained.catalog.descriptors.first {
                    $0.address.target == .source(0) && $0.address.parameter == .gain
                }?.address)
                let panAddress = try #require(retained.catalog.descriptors.first {
                    $0.address.target == .source(0) && $0.address.parameter == .pan
                }?.address)
                let completeOverrides = retained.catalog.descriptors.map { descriptor in
                    LiveControlOverride(address: descriptor.address,
                        value: Self.completeValue(for: descriptor.address.parameter))
                }
                #expect(Set(completeOverrides.map(\.address)).count == retained.catalog.descriptors.count)

                let visualization = try await evaluator.visualization(
                    address: gainAddress,
                    overrides: completeOverrides,
                    revision: revision,
                    selectionGeneration: 1
                )
                #expect(visualization.address == gainAddress)
                #expect(visualization.beatCount == retained.loop.beatCount)
                #expect(!visualization.traces.isEmpty)
                #expect(visualization.traces.count <= 1_024)
                let visualizationPoints = visualization.traces.flatMap { trace in
                    trace.channels.flatMap(\.points)
                }
                #expect(!visualizationPoints.isEmpty)
                #expect(visualizationPoints.count <= 16_384)
                #expect(visualizationPoints.allSatisfy { $0.beat.isFinite && $0.value.isFinite })

                let controlled = try await evaluator.render(
                    overrides: completeOverrides, revision: revision, generation: 1)
                var controlledDifference: Float = 0
                for (lhs, rhs) in zip(controlled.samples, retained.loop.samples) {
                    controlledDifference = max(controlledDifference, abs(lhs - rhs))
                }
                #expect(controlledDifference > 0.0001)

                // Visualization does not consume the audio render generation or mutate PCM.
                let released = try await evaluator.render(overrides: [], revision: revision, generation: 2)
                let releasedBaseline = released == retained.loop
                #expect(releasedBaseline)

                do {
                    _ = try await evaluator.visualization(
                        address: .init(revision: revision + 1,
                                       target: gainAddress.target,
                                       parameter: gainAddress.parameter),
                        revision: revision,
                        selectionGeneration: 2
                    )
                    Issue.record("A visualization with a stale address unexpectedly succeeded")
                } catch let error as LiveControlError {
                    #expect(error == .staleRevision(expected: revision, actual: revision + 1))
                }

                do {
                    _ = try await evaluator.visualization(
                        address: panAddress,
                        revision: revision,
                        selectionGeneration: 3
                    )
                    Issue.record("An unsupported source pan visualization unexpectedly succeeded")
                } catch let error as ControlVisualizationError {
                    #expect(error == .unsupported(panAddress))
                }

                let cancelled = Task {
                    try Task.checkCancellation()
                    return try await evaluator.visualization(
                        address: gainAddress,
                        overrides: completeOverrides,
                        revision: revision,
                        selectionGeneration: 4
                    )
                }
                cancelled.cancel()
                do {
                    _ = try await cancelled.value
                    Issue.record("A cancelled visualization unexpectedly succeeded")
                } catch is CancellationError {
                }

                let afterCancellation = try await evaluator.visualization(
                    address: gainAddress,
                    revision: revision,
                    selectionGeneration: 5
                )
                #expect(afterCancellation.address == gainAddress)
                #expect(await evaluator.controlsAvailable(revision: revision))
                let retainedAfterFailure = try await evaluator.render(
                    overrides: [], revision: revision, generation: 3)
                let retainedPCM = retainedAfterFailure == retained.loop
                #expect(retainedPCM)
                try await evaluator.shutdown()
            } catch {
                try await evaluator.shutdown()
                throw error
            }
        }

        @Test
        func visualizationResponsesRoundTripAndRespectFrameBound() throws {
            let address = LiveControlAddress(
                revision: 73_100, target: .source(0), parameter: .gain)
            let response = RenderWorkerResponse.visualizationFailed(
                revision: address.revision,
                selectionGeneration: 9,
                operationID: 11,
                failure: .unsupported(address)
            )
            let frame = try RenderWorkerFraming.encode(response)
            let payload = Data(frame.dropFirst(RenderWorkerFraming.headerByteCount))
            let decoded = try RenderWorkerFraming.decode(RenderWorkerResponse.self, payload: payload)
            #expect(decoded == response)

            struct OversizedPayload: Codable {
                let bytes: Data
            }
            do {
                _ = try RenderWorkerFraming.encode(OversizedPayload(
                    bytes: Data(repeating: 0, count: RenderWorkerFraming.maximumPayloadBytes + 1)))
                Issue.record("An oversized visualization payload unexpectedly encoded")
            } catch let error as EvaluationError {
                #expect(error.errorDescription?.contains("1 MiB") == true)
            }
        }

        private static func completeValue(for parameter: LiveControlParameter) -> LiveControlValue {
            switch parameter {
            case .trackMute: .number(1)
            case .gain, .trackLevel: .number(0.5)
            case .pan, .trackPan: .number(0.25)
            case .pitchOffsetSemitones: .number(1)
            case .cutoffHz: .number(1_000)
            case .playbackRate: .number(1)
            case .lowPassCutoff: .number(1_000)
            case .delayMix, .reverbMix: .number(0.25)
            }
        }
    }
}
