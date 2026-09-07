import Testing
@testable import MusicPlaygourndApp

extension NativeHostTests {
    struct SessionControlTests {
        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func testLiveControlsDoNotPrepareOrAllocateRevisions() async throws {
            let model = SessionModel()
            #expect(model.audioError.isEmpty)
            model.revision = 7
            let source = model.source
            model.bpm = 137
            model.lowPass = 800
            model.delayMix = 0.4
            model.reverbMix = 0.3
            #expect(model.revision == 7)
            #expect(!(model.isPreparing))
            #expect(model.source == source)
            #expect(!(model.hasUnsavedChanges))
            #expect(model.diagnostic.isEmpty)
            model.bpm = .nan
            #expect(model.bpm == 137)
            #expect(!(model.diagnostic.isEmpty))
            #expect(model.revision == 7)
            try await model.shutdown()
        }
    }
}
