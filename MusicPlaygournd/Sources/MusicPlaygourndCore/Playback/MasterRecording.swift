import Foundation

@MainActor
public protocol MasterRecording: AnyObject {
    func startRecording(_ request: MasterRecordingRequest) throws
    func stopRecording() async throws -> MasterRecordingResult
    func cancelRecording() async throws
}
