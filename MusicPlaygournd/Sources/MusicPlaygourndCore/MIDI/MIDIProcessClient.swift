import CoreMIDI
import Foundation

/// Keeps CoreMIDI available across service lifetimes in this process.
@MainActor
internal enum MIDIProcessClient {
    private static var client = MIDIClientRef()

    static func ensureAvailable() throws {
        guard client == 0 else { return }
        var candidate = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("MusicPlaygournd Process" as CFString, &candidate) { @Sendable _ in }
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
        // CoreMIDI documents that disposing the last client can prevent later creation.
        // The process owns this one client; CoreMIDI reclaims it at process exit.
        client = candidate
    }
}
