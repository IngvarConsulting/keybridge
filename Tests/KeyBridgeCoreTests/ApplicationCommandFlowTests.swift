import XCTest
@testable import KeyBridgeCore

final class ApplicationCommandFlowTests: XCTestCase {
    func testStopRejectsLatePrepareAndProbeReplies() throws {
        for action in ["prepare", "probe", "start", "configure"] {
            var flow = ApplicationCommandFlow()
            let old = try XCTUnwrap(flow.begin(id: "old", action: action))
            let stop = try XCTUnwrap(flow.begin(id: "stop", action: "stop"))
            XCTAssertFalse(flow.isCurrent(old))
            XCTAssertFalse(flow.finish(old, succeeded: true, stopped: true, stopSaved: true))
            XCTAssertEqual(flow.active, stop)
        }
    }
    func testQuitSurvivesFailedSaveAndFinishesOnlyAfterConfirmedStop() throws {
        var flow = ApplicationCommandFlow()
        flow.requestQuit()
        let first = try XCTUnwrap(flow.begin(id: "first", action: "stop"))
        XCTAssertFalse(flow.finish(first, succeeded: false, stopped: true, stopSaved: false))
        XCTAssertTrue(flow.quitRequested)
        let unknown = try XCTUnwrap(flow.begin(id: "unknown", action: "stop"))
        XCTAssertFalse(flow.finish(unknown, succeeded: true, stopped: false, stopSaved: true))
        let final = try XCTUnwrap(flow.begin(id: "final", action: "stop"))
        XCTAssertTrue(flow.finish(final, succeeded: true, stopped: true, stopSaved: true, agentExited: true))
    }
    func testQuitDuringStopDoesNotStartAnotherOperation() throws {
        var flow = ApplicationCommandFlow()
        let stop = try XCTUnwrap(flow.begin(id: "stop", action: "stop"))
        flow.requestQuit()
        XCTAssertNil(flow.begin(id: "repeat", action: "stop"))
        XCTAssertNil(flow.begin(id: "start", action: "start"))
        XCTAssertTrue(flow.finish(stop, succeeded: true, stopped: true, stopSaved: true, agentExited: true))
    }
    func testSuccessfulStopAloneCannotCompleteQuitWhileAgentLives() throws {
        var flow = ApplicationCommandFlow()
        flow.requestQuit()
        let stop = try XCTUnwrap(flow.begin(id: "stop", action: "stop"))
        XCTAssertFalse(flow.finish(stop, succeeded: true, stopped: true, stopSaved: true))
        XCTAssertTrue(flow.quitRequested)
        let retry = try XCTUnwrap(flow.begin(id: "retry", action: "stop"))
        XCTAssertTrue(flow.finish(retry, succeeded: true, stopped: true, stopSaved: true, agentExited: true))
    }
    func testBusyOperationKeepsIdentityWhileOneDiagnosticAndPreferenceAreAccepted() throws {
        var flow=ApplicationCommandFlow()
        let prepare=try XCTUnwrap(flow.begin(id:"prepare",action:"prepare"))
        let probe=try XCTUnwrap(flow.begin(id:"probe",action:"probe"))
        let preference=try XCTUnwrap(flow.begin(id:"auto",action:"autostart"))
        XCTAssertEqual(flow.active,prepare)
        XCTAssertTrue(flow.isCurrent(prepare))
        XCTAssertTrue(flow.isCurrent(probe))
        XCTAssertTrue(flow.isCurrent(preference))
        XCTAssertNil(flow.begin(id:"second",action:"measure"))
        XCTAssertNil(flow.begin(id:"start",action:"start"))
        XCTAssertFalse(flow.finish(preference,succeeded:true,stopped:false,stopSaved:false))
        XCTAssertEqual(flow.active,prepare)
        XCTAssertFalse(flow.finish(prepare,succeeded:true,stopped:true,stopSaved:true))
        XCTAssertEqual(flow.active,probe)
        XCTAssertNil(flow.diagnostic)
        XCTAssertFalse(flow.finish(probe,succeeded:true,stopped:false,stopSaved:false))
        XCTAssertNil(flow.active)
    }
    func testStopInvalidatesPrimaryDiagnosticAndPreferenceAndRejectsNewDiagnostic() throws {
        var flow=ApplicationCommandFlow()
        let old=[try XCTUnwrap(flow.begin(id:"start",action:"start")),
                 try XCTUnwrap(flow.begin(id:"probe",action:"probe")),
                 try XCTUnwrap(flow.begin(id:"auto",action:"autostart"))]
        let stop=try XCTUnwrap(flow.begin(id:"stop",action:"stop"))
        for ticket in old {
            XCTAssertFalse(flow.isCurrent(ticket))
            XCTAssertFalse(flow.finish(ticket,succeeded:true,stopped:true,stopSaved:true))
        }
        XCTAssertEqual(flow.active,stop)
        XCTAssertNil(flow.begin(id:"inspect",action:"recheck"))
        XCTAssertNil(flow.begin(id:"start-again",action:"start"))
    }
    func testRunningDiagnosticCanHaveOneWaitingDiagnosticAndRejectedWaitDoesNotFinishActive() throws {
        var flow=ApplicationCommandFlow()
        let probe=try XCTUnwrap(flow.begin(id:"probe",action:"probe"))
        let resources=try XCTUnwrap(flow.begin(id:"resources",action:"measure"))
        XCTAssertFalse(flow.finish(resources,succeeded:false,stopped:false,stopSaved:false))
        XCTAssertEqual(flow.active,probe)
        XCTAssertNotNil(flow.begin(id:"inspect",action:"recheck"))
        XCTAssertNil(flow.begin(id:"extra",action:"measure"))
    }

}
