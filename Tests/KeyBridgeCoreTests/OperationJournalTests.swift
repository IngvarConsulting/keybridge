// SPDX-License-Identifier: MIT
import XCTest
import Foundation
import Darwin
@testable import KeyBridgeCore

final class OperationJournalTests:XCTestCase {
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
        try restored.setAutostart(true)
        XCTAssertFalse(restored.value.autoInhibit);XCTAssertFalse(restored.value.want)
    }
    func testFailedIntentWriteCannotPretendToBeDurable() throws {
        let store=try IntentStore(runtime:runtime);try store.start()
        store.writeData={_,_ in throw BridgeError("disk full")}
        XCTAssertThrowsError(try store.stop())
        XCTAssertTrue(store.value.want)
        XCTAssertTrue(try IntentStore(runtime:runtime).value.want)
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
    func testPeriodicReconciliationRetainsOneRecordWithUniqueOperationTokens() throws {
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

}
