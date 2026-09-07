import XCTest
@testable import MusicPlaygourndApp

final class SessionControlTests: XCTestCase {
    @MainActor
    func testLiveControlsDoNotPrepareOrAllocateRevisions() async throws {
        let model = SessionModel()
        XCTAssertTrue(model.audioError.isEmpty)
        model.revision = 7
        let source = model.source
        model.bpm = 137
        model.lowPass = 800
        model.delayMix = 0.4
        model.reverbMix = 0.3
        XCTAssertEqual(model.revision, 7)
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(model.source, source)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertTrue(model.diagnostic.isEmpty)
        model.bpm = .nan
        XCTAssertEqual(model.bpm, 137)
        XCTAssertFalse(model.diagnostic.isEmpty)
        XCTAssertEqual(model.revision, 7)
        try await model.shutdown()
    }
}
