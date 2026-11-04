// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class ApplicationShutdownTests: XCTestCase {
    func testImmediateStopReceiptRequiresFreshAbsenceAndSavedIntent() throws {
        let runtime=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kb-absent-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime);defer { try? FileManager.default.removeItem(at:runtime) }
        try Data().write(to:runtime.appendingPathComponent("agent.lock"))
        let intent=try IntentStore(runtime:runtime);try intent.stop()
        XCTAssertTrue(ApplicationShutdown.observeWithoutAgent(runtime:runtime,completion:["ok":true]).confirmed)
        try String(getpid()).write(to:runtime.appendingPathComponent("agent.pid"),atomically:true,encoding:.utf8)
        XCTAssertFalse(ApplicationShutdown.observeWithoutAgent(runtime:runtime,completion:["ok":true]).confirmed)
        try FileManager.default.removeItem(at:runtime.appendingPathComponent("agent.pid"))
        try intent.start()
        XCTAssertFalse(ApplicationShutdown.observeWithoutAgent(runtime:runtime,completion:["ok":true]).confirmed)
    }
    private let absent: [String: Any] = ["ownership": "absent", "running": false]
    private let saved: [String: Any] = ["want": false, "autoInhibit": true]

    func testShutdownRequiresAcknowledgementExitedAgentAndFreshStopEvidence() {
        let confirmed = ApplicationShutdown.evidence(completion: ["ok": true], agentExited: true,
                                                      ownership: absent, intent: saved)
        XCTAssertTrue(confirmed.confirmed)
        XCTAssertFalse(ApplicationShutdown.evidence(completion: [:], agentExited: true,
                                                    ownership: absent, intent: saved).confirmed)
        XCTAssertFalse(ApplicationShutdown.evidence(completion: ["ok": false], agentExited: true,
                                                    ownership: absent, intent: saved).confirmed)
        XCTAssertFalse(ApplicationShutdown.evidence(completion: ["ok": true], agentExited: false,
                                                    ownership: absent, intent: saved).confirmed)
    }

    func testPersistedSuccessCannotHideOwnedOrUnknownVM() {
        for observation: [String: Any] in [[:], ["ownership": "owned", "running": true],
                                           ["ownership": "unknown", "running": false],
                                           ["ownership": "absent", "running": true]] {
            let evidence = ApplicationShutdown.evidence(completion: ["ok": true, "status": "stopped"],
                                                        agentExited: true, ownership: observation, intent: saved)
            XCTAssertFalse(evidence.confirmed)
            XCTAssertFalse(evidence.stopped)
        }
    }

    func testMissingOrChangedIntentBlocksQuitEvenWhenAgentAndVMHaveExited() {
        for intent: [String: Any] in [[:], ["want": false], ["want": true, "autoInhibit": true],
                                      ["want": false, "autoInhibit": false]] {
            let evidence = ApplicationShutdown.evidence(completion: ["ok": true], agentExited: true,
                                                        ownership: absent, intent: intent)
            XCTAssertFalse(evidence.confirmed)
            XCTAssertFalse(evidence.stopSaved)
        }
    }

    func testLiveOrInvalidPIDIsNeverTreatedAsExited() {
        XCTAssertFalse(ApplicationShutdown.hasExited(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(ApplicationShutdown.hasExited(0))
        XCTAssertFalse(ApplicationShutdown.hasExited(1))
        XCTAssertFalse(ApplicationShutdown.hasExited(-1))
    }

    func testSessionTerminationDoesNotRequireOrInventSavedUserStop() {
        let intent: [String: Any] = ["want":true,"autoInhibit":false,"autostart":true]
        let evidence=ApplicationShutdown.evidence(completion:["ok":true],agentExited:true,
                                                  ownership:absent,intent:intent)
        XCTAssertTrue(evidence.sessionEnded)
        XCTAssertFalse(evidence.confirmed)
        XCTAssertFalse(evidence.stopSaved)
        XCTAssertFalse(ApplicationShutdown.evidence(completion:["ok":true],agentExited:false,
                                                    ownership:absent,intent:intent).sessionEnded)
        XCTAssertFalse(ApplicationShutdown.evidence(completion:["ok":false],agentExited:true,
                                                    ownership:absent,intent:intent).sessionEnded)
    }

    func testOnlyExplicitUserStopsPersistTheInhibitAndOnlyShutdownsExit() {
        XCTAssertTrue(AgentStopAction.stop.savesStopIntent)
        XCTAssertTrue(AgentStopAction.shutdown.savesStopIntent)
        XCTAssertFalse(AgentStopAction.sessionStop.savesStopIntent)
        XCTAssertFalse(AgentStopAction.sessionShutdown.savesStopIntent)
        XCTAssertFalse(AgentStopAction.stop.exitsAgent)
        XCTAssertFalse(AgentStopAction.sessionStop.exitsAgent)
        XCTAssertTrue(AgentStopAction.shutdown.exitsAgent)
        XCTAssertTrue(AgentStopAction.sessionShutdown.exitsAgent)
    }
}
