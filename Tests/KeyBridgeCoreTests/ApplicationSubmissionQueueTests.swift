import XCTest
@testable import KeyBridgeCore

@MainActor
final class ApplicationSubmissionQueueTests: XCTestCase {
    func testStopCannotOvertakeDelayedStartSubmissionWhenUIWaiterIsCancelled() async throws {
        let queue = ApplicationSubmissionQueue()
        let gate = SubmissionGate()
        var accepted = [String]()
        let start = queue.enqueue {
            await gate.wait()
            accepted.append("start")
            return "start-receipt"
        }
        let uiWaiter = Task { try await start.value }
        uiWaiter.cancel()
        let stop = queue.enqueue { accepted.append("stop"); return "stop-receipt" }
        await gate.open()
        let receipt = try await stop.value
        XCTAssertEqual(receipt, "stop-receipt")
        XCTAssertEqual(accepted, ["start", "stop"])
    }

    func testFailedSubmissionDoesNotPreventStopAndQueueDoesNotWaitForOperation() async throws {
        let queue = ApplicationSubmissionQueue()
        var accepted = [String]()
        _ = queue.enqueue { () throws -> String in throw BridgeError("agent unavailable") }
        _ = queue.enqueue { accepted.append("prepare receipt; operation still running"); return "receipt" }
        let stop = queue.enqueue { accepted.append("stop"); return true }
        let stopped = try await stop.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(accepted, ["prepare receipt; operation still running", "stop"])
    }
}

private actor SubmissionGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}
