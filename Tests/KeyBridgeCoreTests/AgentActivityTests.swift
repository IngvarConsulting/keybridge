// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class AgentActivityTests: XCTestCase {
    func withJournal(_ body: (URL,OperationJournal,AgentActivity) throws -> Void) throws {
        let runtime=FileManager.default.temporaryDirectory.appendingPathComponent("kb-activity-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer { try? FileManager.default.removeItem(at:runtime) }
        try body(runtime,OperationJournal(runtime:runtime),AgentActivity())
    }

    func testLicenseEvidenceCannotPublishIdleOrReplaceProbeActivity() throws {
        try withJournal { _,journal,activity in
            let token=try journal.begin(id:UUID().uuidString,action:"probe")
            activity.begin(token)
            let observation=activity.applying(to:["busy":false,"operation":"health","running":true,"ownership":"owned"])
            XCTAssertEqual(observation["busy"] as? Bool,true)
            XCTAssertEqual(observation["operation"] as? String,"probe")
            XCTAssertEqual(observation["running"] as? Bool,true)
            XCTAssertEqual(observation["ownership"] as? String,"owned")
            // Revocation asks the worker to stop; it does not mean it has ended.
            journal.invalidate()
            XCTAssertEqual(activity.applying(to:["busy":false])["busy"] as? Bool,true)
        }
    }

    func testAdmissionSlotIsReleasedBeforeDurableResultAndPendingStopOwnsNextStatus() throws {
        try withJournal { runtime,journal,activity in
            let token=try journal.begin(id:UUID().uuidString,action:"probe")
            activity.begin(token)
            let record=runtime.appendingPathComponent("operations/"+token.id+".json")
            var released=false
            journal.finish(token,response:["ok":true],beforePublishing:{
                XCTAssertNil(readObject(record)["response"],"No terminal result may precede the admission handoff")
                activity.finish(token)
                XCTAssertNil(activity.current)
                released=true
            })
            XCTAssertTrue(released)
            XCTAssertEqual((readObject(record)["response"] as? [String:Any])?["ok"] as? Bool,true)
            let stop=try journal.begin(id:UUID().uuidString,action:"stop",safety:true)
            activity.begin(stop)
            let observation=activity.applying(to:["busy":false,"operation":""])
            XCTAssertEqual(observation["busy"] as? Bool,true)
            XCTAssertEqual(observation["operation"] as? String,"stop")
            activity.finish(token)
            XCTAssertEqual(activity.current,stop,"A late prior completion cannot release the safety operation")
        }
    }

    func testActualCompletionClearsActivityEvenWhenEngineStillReportsBusy() throws {
        try withJournal { _,journal,activity in
            let token=try journal.begin(id:UUID().uuidString,action:"reconcile")
            activity.begin(token)
            journal.finish(token,response:["ok":true],beforePublishing:{ activity.finish(token) })
            let observation=activity.applying(to:["busy":true,"operation":"starting","running":true])
            XCTAssertEqual(observation["busy"] as? Bool,false)
            XCTAssertEqual(observation["operation"] as? String,"")
            XCTAssertEqual(observation["running"] as? Bool,true)
        }
    }

    func testEngineSinkOwnsDiskPublicationWithoutIntermediateFalseIdle() throws {
        try withJournal { runtime,journal,activity in
            let token=try journal.begin(id:UUID().uuidString,action:"probe")
            activity.begin(token)
            let path=runtime.appendingPathComponent("status.json")
            let current=activity.applying(to:["lastProbe":["result":"unknown"]])
            try writeObject(current,to:path)
            let engine=VMEngine(runtime:runtime,resources:runtime)
            var called=false
            engine.stateSink={ patch in
                called=true
                XCTAssertEqual(readObject(path)["busy"] as? Bool,true,"Engine must not write raw idle before calling its controller")
                XCTAssertEqual(readObject(path)["operation"] as? String,"probe")
                XCTAssertNil(patch["lastProbe"],"A historical proof read from disk is not a new observation")
                XCTAssertEqual(patch["prepared"] as? Bool,false)
                XCTAssertEqual(patch["memoryMiB"] as? Int,128)
                XCTAssertNotNil(patch["endpoint"])
                do { try writeObject(activity.applying(to:patch),to:path) }
                catch { XCTFail(error.localizedDescription) }
            }
            engine.update(["busy":false,"operation":"health","running":true])
            XCTAssertTrue(called)
            XCTAssertEqual(readObject(path)["busy"] as? Bool,true)
            XCTAssertEqual(readObject(path)["operation"] as? String,"probe")
        }
    }

    func testRejectedEngineObservationDoesNotBypassControllerPublicationBarrier() throws {
        try withJournal { runtime,journal,activity in
            let token=try journal.begin(id:UUID().uuidString,action:"probe")
            activity.begin(token)
            let path=runtime.appendingPathComponent("status.json")
            try writeObject(activity.applying(to:["message":"stopping"]),to:path)
            let before=try Data(contentsOf:path)
            let engine=VMEngine(runtime:runtime,resources:runtime)
            engine.stateSink={ _ in } // A revoked token's controller rejects it.
            engine.update(["busy":false,"message":"old probe completed"])
            XCTAssertEqual(try Data(contentsOf:path),before)
        }
    }

    func testStandaloneEngineStillPersistsItsStatus() throws {
        try withJournal { runtime,_,_ in
            let engine=VMEngine(runtime:runtime,resources:runtime)
            engine.update(["busy":false,"status":"stopped","message":"standalone"])
            let state=readObject(runtime.appendingPathComponent("status.json"))
            XCTAssertEqual(state["busy"] as? Bool,false)
            XCTAssertEqual(state["status"] as? String,"stopped")
            XCTAssertEqual(state["message"] as? String,"standalone")
            XCTAssertEqual(state["memoryMiB"] as? Int,128)
        }
    }
}
