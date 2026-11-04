// SPDX-License-Identifier: MIT
import XCTest
import Foundation
import Darwin
@testable import KeyBridgeCore

final class OperationJournalTests:XCTestCase {
    func testAcceptedQueuedCommandIsNotReplayedAfterAgentRestart() throws {
        let runtime=FileManager.default.temporaryDirectory.appendingPathComponent("kb-queued-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime);defer { try?FileManager.default.removeItem(at:runtime) }
        let journal=OperationJournal(runtime:runtime),id=UUID().uuidString
        try journal.receive(id:id,action:"probe")
        XCTAssertEqual(readObject(runtime.appendingPathComponent("operations/"+id+".json"))["state"] as? String,"accepted")
        let recovered=OperationJournal(runtime:runtime).recover()
        XCTAssertEqual(recovered[id]?["resultState"] as? String,"unknown")
        XCTAssertEqual(recovered[id]?["ok"] as? Bool,false)
    }
    var runtime:URL!
    override func setUpWithError() throws {
        runtime=URL(fileURLWithPath:"/tmp").appendingPathComponent("kb-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:runtime) }
    func testCancelledOperationCannotPublishAndDoesNotBlockSafetyStop() throws {
        let journal=OperationJournal(runtime:runtime)
        let first=try journal.begin(id:UUID().uuidString,action:"prepare")
        journal.invalidate()
        XCTAssertThrowsError(try journal.publish(first) { XCTFail("Cancelled generation must not commit") })
        journal.finish(first,response:["ok":false])
        let stop=try journal.begin(id:UUID().uuidString,action:"stop",safety:true)
        XCTAssertTrue(journal.isCurrent(stop))
    }
    func testPublicationAndStopHaveOneLinearOrder() throws {
        let journal=OperationJournal(runtime:runtime)
        let token=try journal.begin(id:UUID().uuidString,action:"prepare")
        let committed=try journal.publish(token) { "published" }
        journal.invalidate()
        XCTAssertEqual(committed,"published")
        XCTAssertFalse(journal.isCurrent(token))
        XCTAssertThrowsError(try journal.publish(token) { "late" })
    }
    func testOrdinaryAdmissionRequiresDurabilityButStopStillExecutes() throws {
        try FileManager.default.createDirectory(at:runtime.appendingPathComponent("operations"),withIntermediateDirectories:false)
        let id=UUID().uuidString
        try FileManager.default.createDirectory(at:runtime.appendingPathComponent("operations/"+id+".json"),withIntermediateDirectories:false)
        let journal=OperationJournal(runtime:runtime)
        XCTAssertThrowsError(try journal.begin(id:id,action:"start"))
        let stop=try journal.begin(id:id,action:"stop",safety:true)
        XCTAssertTrue(journal.isCurrent(stop));XCTAssertNotNil(journal.persistenceError)
    }
    func testTakenRequestSurvivesCrashAsUnknownRatherThanReplaying() throws {
        let id=try CommandQueue.enqueue(["action":"start"],runtime:runtime)
        XCTAssertEqual(try CommandQueue.take(runtime:runtime).count,1)
        let recovered=OperationJournal(runtime:runtime).recover()
        XCTAssertEqual(recovered[id]?["resultState"] as? String,"unknown")
        XCTAssertTrue(try CommandQueue.take(runtime:runtime).isEmpty)
    }
    func testDurableStopSurvivesMigrationAndAutostartDoesNotOverrideIt() throws {
        try writeObject(["running":false],to:runtime.appendingPathComponent("desired.json"))
        try writeObject(["autostart":true],to:runtime.appendingPathComponent("preferences.json"))
        let intent=try IntentStore(runtime:runtime)
        XCTAssertFalse(intent.value.want);XCTAssertTrue(intent.value.autoInhibit);XCTAssertTrue(intent.value.autostart)
        try intent.start();try intent.stop()
        let restored=try IntentStore(runtime:runtime)
        XCTAssertFalse(restored.value.want);XCTAssertTrue(restored.value.autoInhibit)
        try restored.setAutostart(true,supported:true)
        XCTAssertFalse(restored.value.autoInhibit);XCTAssertFalse(restored.value.want)
    }
    func testFailedIntentWriteCannotPretendToBeDurable() throws {
        let store=try IntentStore(runtime:runtime);try store.start()
        store.writeData={_,_ in throw BridgeError("disk full")}
        XCTAssertThrowsError(try store.stop())
        XCTAssertTrue(store.value.want)
        XCTAssertTrue(try IntentStore(runtime:runtime).value.want)
    }
    func testUnsupportedAutostartCannotPersistOrClearDurableStop() throws {
        let store=try IntentStore(runtime:runtime)
        try store.stop()
        let path=runtime.appendingPathComponent("intent.json"),before=try Data(contentsOf:path)
        XCTAssertThrowsError(try store.setAutostart(true,supported:false))
        XCTAssertEqual(try Data(contentsOf:path),before)
        XCTAssertFalse(store.value.autostart)
        XCTAssertTrue(store.value.autoInhibit)
    }
    func testUnsupportedBuildCanDisablePreviouslySavedAutostart() throws {
        let store=try IntentStore(runtime:runtime)
        try store.setAutostart(true,supported:true)
        try store.hold()
        try store.setAutostart(false,supported:false)
        let reloaded=try IntentStore(runtime:runtime)
        XCTAssertFalse(reloaded.value.autostart)
        XCTAssertTrue(reloaded.value.inhibited)
    }
    func testBudgetIsConsumedAndFailureDoesNotReplenishIt() throws {
        let store=try IntentStore(runtime:runtime);try store.start()
        for _ in 0..<3 { try store.consumeAttempt() }
        XCTAssertEqual(store.value.remaining,0)
        try store.hold();XCTAssertEqual(try IntentStore(runtime:runtime).value.remaining,0)
    }
    func testIPCStatusAndResultDoNotNeedStatusFiles() throws {
        let cache=RuntimeSnapshot();cache.patch(["status":"error","persistenceError":"disk full"])
        let id=UUID().uuidString;cache.complete(id,["ok":false,"error":"stop not saved"])
        let server=try AgentIPC.Server(runtime:runtime) { message in
            message["requestID"] as? String == id ? cache.result(id):cache.status()
        };defer{server.stop()}
        let status=try AgentIPC.exchange(runtime:runtime,message:["ipc":"status"])
        XCTAssertEqual(status["persistenceError"] as? String,"disk full")
        let result=try AgentIPC.exchange(runtime:runtime,message:["ipc":"result","requestID":id])
        XCTAssertEqual(result["ok"] as? Bool,false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:runtime.appendingPathComponent("status.json").path))
    }
    func testLatePrivilegedHelperLosesPermissionWithoutAnyDiskWrite() throws {
        let fifo=runtime.appendingPathComponent("permit.fifo")
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        let reader=open(fifo.path,O_RDONLY|O_NONBLOCK);defer{close(reader)}
        let journal=OperationJournal(runtime:runtime)
        let token=try journal.begin(id:UUID().uuidString,action:"configure")
        try journal.grantConfiguration(token,fifo:fifo)
        var byte:UInt8=0
        XCTAssertEqual(read(reader,&byte,1),-1);XCTAssertEqual(errno,EAGAIN)
        journal.invalidate()
        XCTAssertEqual(read(reader,&byte,1),0,"Late root helper must see EOF, including disk-full cancellation")
        XCTAssertThrowsError(try journal.grantConfiguration(token,fifo:fifo))
    }
    func testPrivilegedCommitAndCancellationHaveOneKernelLockOrder() throws {
        let fifo=runtime.appendingPathComponent("permit.fifo")
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        let reader=open(fifo.path,O_RDONLY|O_NONBLOCK);defer{close(reader)}
        let journal=OperationJournal(runtime:runtime)
        let token=try journal.begin(id:UUID().uuidString,action:"configure")
        try journal.grantConfiguration(token,fifo:fifo)
        let helper=open(runtime.appendingPathComponent("commit.lock").path,O_RDWR);defer{close(helper)}
        XCTAssertEqual(flock(helper,LOCK_EX),0)
        let cancelled=DispatchSemaphore(value:0)
        DispatchQueue.global().async { journal.invalidate();cancelled.signal() }
        XCTAssertEqual(cancelled.wait(timeout:.now()+0.05),.timedOut)
        var byte:UInt8=0
        XCTAssertEqual(read(reader,&byte,1),-1);XCTAssertEqual(errno,EAGAIN)
        flock(helper,LOCK_UN)
        XCTAssertEqual(cancelled.wait(timeout:.now()+2),.success)
        XCTAssertEqual(read(reader,&byte,1),0)
    }

    func testFallbackTransportKeepsTheOriginalRequestIdentity() throws {
        let id=UUID().uuidString
        XCTAssertEqual(try CommandQueue.enqueue(["action":"start","requestID":id],runtime:runtime),id)
        XCTAssertEqual(try CommandQueue.take(runtime:runtime).first?.0,id)
    }
    func testEventReconciliationRetainsOneRecordWithUniqueOperationTokens() throws {
        let journal=OperationJournal(runtime:runtime)
        var ids=Set<String>()
        for _ in 0..<10 {
            let token=try journal.begin(id:UUID().uuidString,action:"reconcile")
            ids.insert(token.id);journal.finish(token,response:["ok":true])
        }
        XCTAssertEqual(ids.count,10)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:runtime.appendingPathComponent("operations").path).isEmpty)
        XCTAssertNotNil(readObject(runtime.appendingPathComponent("reconciliation.json"))["requestID"])
    }

    func testCompletedSafetyAliasDoesNotBecomeUnknownAfterRestart() throws {
        let journal=OperationJournal(runtime:runtime),id=UUID().uuidString
        try journal.receiveSafety(id:id,action:"stop")
        try journal.recordResponse(id:id,action:"stop",response:["ok":true,"resultState":"finished"])
        let recovered=OperationJournal(runtime:runtime).recover()
        XCTAssertEqual(recovered[id]?["ok"] as? Bool,true)
        XCTAssertEqual(recovered[id]?["resultState"] as? String,"finished")
    }

    func testSafetyCauseSurvivesStopAutostartAndRestartUntilVerification() throws {
        let store=try IntentStore(runtime:runtime)
        try store.start();try store.hold("firmware-unknown");try store.stop()
        try store.setAutostart(true,supported:true)
        let restored=try IntentStore(runtime:runtime)
        XCTAssertEqual(restored.value.safetyReason,"firmware-unknown")
        XCTAssertTrue(restored.value.inhibited)
        try restored.start()
        XCTAssertTrue(restored.value.inhibited,"The start request is not proof of safety")
        try restored.clearSafetyAfterVerification()
        XCTAssertFalse(try IntentStore(runtime:runtime).value.inhibited)
    }
    func testSavedIntentModificationIsNotSilentlyTrusted() throws {
        let store=try IntentStore(runtime:runtime);try store.start()
        try store.validateSaved()
        try Data("broken".utf8).write(to:runtime.appendingPathComponent("intent.json"),options:.atomic)
        XCTAssertThrowsError(try store.validateSaved())
        XCTAssertTrue(store.value.want)
    }
    func testOldCombinedInhibitDoesNotLoseUnknownSafetyCause() throws {
        try writeObject(["schema":1,"want":false,"autoInhibit":true,"autostart":true,"remaining":2,"sessionID":"old","revision":0],to:runtime.appendingPathComponent("intent.json"))
        let store=try IntentStore(runtime:runtime)
        try store.setAutostart(true,supported:true)
        XCTAssertTrue(store.value.inhibited)
        XCTAssertNotNil(store.value.safetyReason)
    }
    func testTerminalWriteFailureIsReturnedWithoutHoldingAdmission() throws {
        let journal=OperationJournal(runtime:runtime)
        let token=try journal.begin(id:UUID().uuidString,action:"start")
        let path=runtime.appendingPathComponent("operations/"+token.id+".json")
        try FileManager.default.removeItem(at:path)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
        XCTAssertNotNil(journal.finish(token,response:["ok":true]))
        XCTAssertNoThrow(try journal.begin(id:UUID().uuidString,action:"stop",safety:true))
    }
    func testOnlyOneDiagnosticMayWaitAndNeverBehindStop() {
        XCTAssertFalse(AgentAdmission.canWait(action:"start",active:"reconcile",pending:false,stopping:false))
        XCTAssertTrue(AgentAdmission.canWait(action:"probe",active:"start",pending:false,stopping:false))
        XCTAssertFalse(AgentAdmission.canWait(action:"probe",active:"start",pending:true,stopping:false))
        XCTAssertFalse(AgentAdmission.canWait(action:"probe",active:"stop",pending:false,stopping:false))
        XCTAssertFalse(AgentAdmission.canWait(action:"inspect",active:"prepare",pending:false,stopping:true))
    }

    func testFailedSafetySaveSurvivesPreferenceChangeOnceStorageRecovers() throws {
        let store=try IntentStore(runtime:runtime);try store.start()
        store.writeData={_,_ in throw BridgeError("disk full")}
        XCTAssertThrowsError(try store.hold("multiple-keys"))
        XCTAssertTrue(store.value.inhibited)
        XCTAssertEqual(store.value.safetyReason,"multiple-keys")
        store.writeData={try $0.write(to:$1,options:.atomic)}
        try store.setAutostart(true,supported:true)
        let restored=try IntentStore(runtime:runtime)
        XCTAssertTrue(restored.value.inhibited)
        XCTAssertEqual(restored.value.safetyReason,"multiple-keys")
    }

}
