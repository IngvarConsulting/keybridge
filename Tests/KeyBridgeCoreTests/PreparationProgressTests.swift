// SPDX-License-Identifier: MIT
import XCTest
import Foundation
@testable import KeyBridgeCore

final class PreparationProgressTests: XCTestCase {
    private var runtime: URL!
    private var logs: URL { runtime.appendingPathComponent("logs") }
    private var progress: [String: Any] { readObject(runtime.appendingPathComponent("preparation.json")) }
    private var engine: VMEngine { VMEngine(runtime: runtime, resources: runtime.appendingPathComponent("no-resources")) }

    override func setUpWithError() throws {
        runtime = FileManager.default.temporaryDirectory.appendingPathComponent("KeyBridgeProgressTests-" + UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        try BridgePaths.preparePrivateDirectory(logs)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: runtime) }

    func testFirstOutputIsPersistedBeforeChildCanExitAndNeverDuplicated() throws {
        let gate = runtime.appendingPathComponent("continue")
        let exited = runtime.appendingPathComponent("exited")
        let first = "KEYBRIDGE_PHASE=dependencies\nfirst stdout\nfirst stderr\n"
        let second = "KEYBRIDGE_PHASE=driver\nsecond stdout\n"
        let fixture = """
        printf 'KEYBRIDGE_PHASE=dependencies\nfirst stdout\n'
        printf 'first stderr\n' >&2
        while ! test -f "$1"; do /bin/sleep 0.05; done
        printf 'KEYBRIDGE_PHASE=driver\nsecond stdout\n'
        : > "$2"
        """
        let session = try PreparationSession(runtime: runtime)
        var observedLive = false
        let result = try StreamingCommand.run("/bin/sh", ["-c", fixture, "fixture", gate.path, exited.path], directory: logs, timeout: 5,
            output: { bytes in
                try appendPrivateLog(bytes, to: self.logs.appendingPathComponent("engine.log"))
                try session.record(bytes)
                let text = try self.log("preparation.log")
                if text.contains("first stderr\n") && !observedLive {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: exited.path), "The child is blocked until live output has been persisted.")
                    XCTAssertEqual(self.progress["phase"] as? String, "dependencies")
                    XCTAssertEqual(try self.log("engine.log"), first)
                    observedLive = true
                    try Data().write(to: gate)
                }
            }, heartbeat: { try session.heartbeat() })
        XCTAssertTrue(observedLive)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, first + second)
        XCTAssertEqual(try log("preparation.log"), first + second)
        XCTAssertEqual(try log("engine.log"), first + second)
        XCTAssertEqual(progress["phase"] as? String, "driver")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exited.path))
    }

    func testMarkersSplitAtEveryByteBoundaryRemainOrderedWithoutRegression() throws {
        for split in 1..<"KEYBRIDGE_PHASE=dependencies\n".utf8.count {
            var parser = PreparationMarkerParser()
            let bytes = Data("KEYBRIDGE_PHASE=dependencies\n".utf8)
            XCTAssertTrue(parser.consume(bytes.prefix(split)).isEmpty)
            XCTAssertEqual(parser.consume(bytes.suffix(bytes.count - split)), ["dependencies"])
        }
        let session = try PreparationSession(runtime: runtime)
        try session.advance(to: "boot")
        for part in ["KEYBRIDGE_", "PHASE=imports\nKEYBRIDGE_PHASE=depend", "encies\nKEYBRIDGE_PHASE=driver\n", "KEYBRIDGE_PHASE=imports\n", "KEYBRIDGE_PHASE=manager_start\nKEYBRIDGE_PHASE=manager_ready\n"] {
            try session.record(Data(part.utf8))
        }
        XCTAssertEqual(progress["phase"] as? String, "manager_ready")
        try session.record(Data("KEYBRIDGE_PHASE=verify\nKEYBRIDGE_PHASE=unknown\n".utf8))
        XCTAssertEqual(progress["phase"] as? String, "manager_ready")
    }

    func testHugeLinesDoNotGrowMarkerBufferOrCreateFalsePhases() {
        var parser = PreparationMarkerParser()
        XCTAssertTrue(parser.consume(Data((String(repeating: "x", count: 3 * 1024 * 1024) + "KEYBRIDGE_PHASE=finalize\n").utf8)).isEmpty)
        XCTAssertEqual(parser.consume(Data("KEYBRIDGE_PHASE=firmware_guard\r\n".utf8)), ["firmware_guard"])
        XCTAssertTrue(parser.consume(Data("KEYBRIDGE_PHASE=manager_configure".utf8)).isEmpty)
        XCTAssertEqual(parser.finish(), ["manager_configure"])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testHeartbeatDoesNotInventOutputOrResetPhaseTimeAndFinalStateIsStable() throws {
        var time: TimeInterval = 100
        let session = try PreparationSession(runtime: runtime, now: { time })
        XCTAssertNil(progress["lastOutputAt"])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(progress["id"] as? String)))
        time = 102
        try session.record(Data("real output\n".utf8))
        time = 104
        try session.advance(to: "linux")
        time = 106
        try session.heartbeat()
        XCTAssertEqual(progress["updatedAt"] as? Double, 106)
        XCTAssertEqual(progress["lastOutputAt"] as? Double, 102)
        XCTAssertEqual(progress["phaseStartedAt"] as? Double, 104)
        XCTAssertEqual(progress["startedAt"] as? Double, 100)
        time = 108
        try session.finish("failed")
        let terminal = try Data(contentsOf: runtime.appendingPathComponent("preparation.json"))
        time = 120
        try session.heartbeat()
        try session.advance(to: "finalize")
        try session.record(Data("late output".utf8))
        try session.finish("succeeded")
        XCTAssertEqual(try Data(contentsOf: runtime.appendingPathComponent("preparation.json")), terminal)
        XCTAssertEqual(progress["finishedAt"] as? Double, 108)
        XCTAssertEqual(progress["phase"] as? String, "linux")
        XCTAssertEqual(try log("preparation.log"), "real output\n")
    }

    func testEngineFailureRetainsOutputAndTerminalPhaseAndNextAttemptResetsOnlyAttemptLog() throws {
        let controller = engine
        XCTAssertThrowsError(try controller.withPreparation {
            try controller.run("/bin/sh", ["-c", "printf 'KEYBRIDGE_PHASE=manager_install\\ninstaller diagnostic\\n'; printf 'KEYBRIDGE_ERROR=stage_manager_install code=7\\n' >&2; exit 7"])
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Установщик менеджера лицензий"))
        }
        let failedID = progress["id"] as? String
        XCTAssertEqual(progress["state"] as? String, "failed")
        XCTAssertEqual(progress["phase"] as? String, "manager_install")
        XCTAssertNotNil(progress["finishedAt"] as? Double)
        let failureLog = try log("preparation.log")
        XCTAssertTrue(failureLog.contains("installer diagnostic\n"))
        XCTAssertEqual(try log("engine.log"), failureLog)

        try controller.withPreparation {
            try controller.run("/bin/sh", ["-c", "printf 'KEYBRIDGE_PHASE=finalize\\nnew attempt complete\\n'"])
        }
        XCTAssertNotEqual(progress["id"] as? String, failedID)
        XCTAssertEqual(progress["state"] as? String, "succeeded")
        XCTAssertEqual(progress["phase"] as? String, "finalize")
        XCTAssertFalse(try log("preparation.log").contains("installer diagnostic"))
        XCTAssertEqual(try log("engine.log"), try failureLog + log("preparation.log"))
    }

    func testTerminalProgressCanRetryAfterAnAtomicWriteFailure() throws {
        let session = try PreparationSession(runtime: runtime)
        let progressURL = runtime.appendingPathComponent("preparation.json")
        try FileManager.default.removeItem(at: progressURL)
        try FileManager.default.createDirectory(at: progressURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try session.finish("succeeded"))
        XCTAssertEqual(session.values["state"] as? String, "running")
        try FileManager.default.removeItem(at: progressURL)
        try session.finish("succeeded")
        XCTAssertEqual(progress["state"] as? String, "succeeded")
        XCTAssertNotNil(progress["finishedAt"])
    }

    func testCommittedSuccessIsNotReclassifiedWhenProgressDiskWriteFails() throws {
        let manifest = runtime.appendingPathComponent("current.json")
        let committed = Data("{\"generation\":\"accepted-fixture\"}".utf8)
        XCTAssertNoThrow(try engine.withPreparation {
            try committed.write(to: manifest, options: .atomic)
            // Make terminal progress persistence fail independently of the
            // accepted generation, without touching any real runtime.
            let path = runtime.appendingPathComponent("preparation.json")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        })
        XCTAssertEqual(try Data(contentsOf: manifest), committed)
        XCTAssertFalse(try log("preparation.log").contains("failed"))
    }

    func testEngineCancellationDrainsOutputAndRetainsCancelledProgress() throws {
        let controller = engine
        let cancellation = runtime.appendingPathComponent("cancel.request")
        XCTAssertThrowsError(try controller.withPreparation {
            try controller.run("/bin/sh", ["-c", "printf 'KEYBRIDGE_PHASE=driver\\nlast diagnostic before cancellation\\n'; : > \"$1\"; exec /bin/sleep 10", "fixture", cancellation.path], timeout: 5)
        }) { error in
            guard case VMEngineError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        XCTAssertEqual(progress["state"] as? String, "cancelled")
        XCTAssertEqual(progress["phase"] as? String, "driver")
        XCTAssertNotNil(progress["finishedAt"] as? Double)
        XCTAssertTrue(try log("preparation.log").contains("last diagnostic before cancellation\n"))
        XCTAssertEqual(try log("engine.log"), try log("preparation.log"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: logs.path).contains { $0.hasPrefix("command-") || $0.hasPrefix("input-") })
    }

    func testEngineTimeoutRetainsOutputAndMarksFailedRatherThanCancelled() throws {
        let controller = engine
        XCTAssertThrowsError(try controller.withPreparation {
            try controller.run("/bin/sh", ["-c", "printf 'KEYBRIDGE_PHASE=dependencies\\nwaiting diagnostic\\n'; exec /bin/sleep 10"], timeout: 0.2)
        }) { error in XCTAssertTrue(error.localizedDescription.contains("Время ожидания")) }
        XCTAssertEqual(progress["state"] as? String, "failed")
        XCTAssertEqual(progress["phase"] as? String, "dependencies")
        XCTAssertTrue(try log("preparation.log").contains("waiting diagnostic\n"))
        XCTAssertEqual(try log("engine.log"), try log("preparation.log"))
    }

    func testSilentLiveChildOnlyUpdatesEngineHeartbeat() throws {
        let session = try PreparationSession(runtime: runtime)
        let started = try XCTUnwrap(progress["updatedAt"] as? Double)
        var pollingCount = 0
        _ = try StreamingCommand.run("/bin/sleep", ["1.2"], directory: logs,
            output: { bytes in try session.record(bytes) },
            heartbeat: { pollingCount += 1; try session.heartbeat() })
        XCTAssertGreaterThan(pollingCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(progress["updatedAt"] as? Double), started)
        XCTAssertNil(progress["lastOutputAt"])
        XCTAssertEqual(try log("preparation.log"), "")
    }

    func testCancellationAlreadyRequestedNeverLaunchesAnotherChild() throws {
        let sentinel = runtime.appendingPathComponent("must-not-exist")
        XCTAssertThrowsError(try StreamingCommand.run("/bin/sh", ["-c", ": > \"$1\"", "fixture", sentinel.path], directory: logs,
            cancellation: { true }, output: { _ in XCTFail("A cancelled command must not produce output") })) { error in
            guard case VMEngineError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testProgressCallbackFailureStillDrainsUnreadDiagnosticsWithoutDuplicates() throws {
        enum FixtureFailure: Error { case heartbeat, output }
        let ready = runtime.appendingPathComponent("fixture-output-ready")
        let logURL = logs.appendingPathComponent("engine.log")
        var chunks = 0
        XCTAssertThrowsError(try StreamingCommand.run("/bin/sh", ["-c", "/usr/bin/head -c 196608 /dev/zero | /usr/bin/tr '\\000' x; : > \"$1\"; exec /bin/sleep 10", "fixture", ready.path], directory: logs,
            output: { bytes in
                chunks += 1
                try appendPrivateLog(bytes, to: logURL)
                // Match engine.log succeeding followed by preparation.json
                // failing; subsequent chunks must still reach engine.log.
                throw FixtureFailure.output
            }, heartbeat: {
                let deadline = Date().addingTimeInterval(2)
                while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
                throw FixtureFailure.heartbeat
            })) { error in
            guard case FixtureFailure.heartbeat = error else { return XCTFail("The original error must survive: \(error)") }
        }
        XCTAssertGreaterThan(chunks, 1)
        XCTAssertEqual(try Data(contentsOf: logURL), Data(repeating: 120, count: 196608))
    }

    func testLongOutputRetainsOnlyBoundedResultButAllLogBytesAndDoesNotLogStdin() throws {
        let secret = "PRIVATE SCRIPT BODY MUST NEVER BE LOGGED"
        let controller = engine
        var result = ""
        try controller.withPreparation {
            result = try controller.run("/bin/sh", ["-c", "cat >/dev/null; /usr/bin/head -c 3145728 /dev/zero | /usr/bin/tr '\\000' x; printf '\\ncomplete\\n'"], input: Data(secret.utf8))
        }
        XCTAssertLessThanOrEqual(result.utf8.count, StreamingCommand.maximumResultBytes)
        XCTAssertTrue(result.hasSuffix("\ncomplete\n"))
        let bytes = try Data(contentsOf: logs.appendingPathComponent("preparation.log"))
        XCTAssertGreaterThan(bytes.count, 3 * 1024 * 1024)
        XCTAssertEqual(try Data(contentsOf: logs.appendingPathComponent("engine.log")), bytes)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret))
        XCTAssertEqual(progress["state"] as? String, "succeeded")
    }

    func testRejectedPreparationStillLeavesTerminalProgressAndPreservesExistingManifest() throws {
        let original = Data("{\"generation\":\"retained\"}".utf8)
        try original.write(to: runtime.appendingPathComponent("current.json"))
        XCTAssertThrowsError(try engine.perform(["action": "prepare", "installer": runtime.appendingPathComponent("missing.run").path, "driver": runtime.appendingPathComponent("missing.deb").path]))
        XCTAssertEqual(progress["state"] as? String, "failed")
        XCTAssertEqual(progress["phase"] as? String, "verify")
        XCTAssertNotNil(progress["lastOutputAt"] as? Double)
        XCTAssertNotNil(progress["finishedAt"] as? Double)
        XCTAssertEqual(try Data(contentsOf: runtime.appendingPathComponent("current.json")), original)
    }

    func testNewEngineOwnerRecoversInterruptedAttemptWithoutChangingItsOutputOrPhaseTimes() throws {
        var time: TimeInterval = 100
        let session = try PreparationSession(runtime: runtime, now: { time })
        time = 105
        try session.record(Data("KEYBRIDGE_PHASE=driver\nlast real diagnostic\n".utf8))
        time = 110
        try session.heartbeat()
        let id = progress["id"] as? String
        let originalLog = try Data(contentsOf: logs.appendingPathComponent("preparation.log"))
        let manifest = Data("{\"generation\":\"previous-accepted-generation\"}".utf8)
        try manifest.write(to: runtime.appendingPathComponent("current.json"))

        let freshOwner = engine
        XCTAssertEqual(progress["state"] as? String, "failed")
        XCTAssertEqual(progress["recoveryReason"] as? String, "agent_restarted")
        XCTAssertEqual(progress["id"] as? String, id)
        XCTAssertEqual(progress["phase"] as? String, "driver")
        XCTAssertEqual(progress["startedAt"] as? Double, 100)
        XCTAssertEqual(progress["phaseStartedAt"] as? Double, 105)
        XCTAssertEqual(progress["lastOutputAt"] as? Double, 105)
        XCTAssertGreaterThan(try XCTUnwrap(progress["finishedAt"] as? Double), 110)
        XCTAssertEqual(try Data(contentsOf: logs.appendingPathComponent("preparation.log")), originalLog)
        XCTAssertEqual(try Data(contentsOf: runtime.appendingPathComponent("current.json")), manifest)
        XCTAssertEqual(freshOwner.status()["busy"] as? Bool, false)
        XCTAssertEqual(freshOwner.status()["status"] as? String, "error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("qemu.pid").path))
    }

    func testNewEngineOwnerRecognizesManifestCommittedBySameAttempt() throws {
        let session = try PreparationSession(runtime: runtime)
        try session.record(Data("KEYBRIDGE_PHASE=finalize\nready for commit\n".utf8))
        var manifest = try generationFixture(runtime)
        manifest["preparationID"] = try XCTUnwrap(progress["id"])
        try writeObject(manifest, to: runtime.appendingPathComponent("current.json"))
        let originalLog = try Data(contentsOf: logs.appendingPathComponent("preparation.log"))

        let freshOwner = engine
        XCTAssertEqual(progress["state"] as? String, "succeeded")
        XCTAssertEqual(progress["phase"] as? String, "finalize")
        XCTAssertEqual(progress["recoveryReason"] as? String, "commit_recovered")
        XCTAssertEqual(freshOwner.status()["prepared"] as? Bool, true)
        XCTAssertEqual(freshOwner.status()["status"] as? String, "stopped")
        XCTAssertEqual(try Data(contentsOf: logs.appendingPathComponent("preparation.log")), originalLog)
    }

    func testNewEngineOwnerLeavesAlreadyTerminalAttemptUntouched() throws {
        let session = try PreparationSession(runtime: runtime)
        try session.record(Data("previous output\n".utf8))
        try session.finish("cancelled")
        let original = try Data(contentsOf: runtime.appendingPathComponent("preparation.json"))
        _ = engine
        XCTAssertEqual(try Data(contentsOf: runtime.appendingPathComponent("preparation.json")), original)
        XCTAssertEqual(try log("preparation.log"), "previous output\n")
    }

    private func log(_ name: String) throws -> String { try String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8) }
}
