import Foundation
import Synchronization

/// Foundation delivers completion on its own queue; no run-loop blocking crosses actor suspension.
final class ProcessCompletion: Sendable {
    private let state = Mutex<(status: Int32, exited: Bool)?>(nil)
    var result: (status: Int32, exited: Bool)? { state.withLock { $0 } }
    func finish(status: Int32, exited: Bool) {
        state.withLock { $0 = (status, exited) }
    }
}
