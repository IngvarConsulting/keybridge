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
        XCTAssertTrue(flow.finish(final, succeeded: true, stopped: true, stopSaved: true))
    }
    func testQuitDuringStopDoesNotStartAnotherOperation() throws {
        var flow = ApplicationCommandFlow()
        let stop = try XCTUnwrap(flow.begin(id: "stop", action: "stop"))
        flow.requestQuit()
        XCTAssertNil(flow.begin(id: "repeat", action: "stop"))
        XCTAssertNil(flow.begin(id: "start", action: "start"))
        XCTAssertTrue(flow.finish(stop, succeeded: true, stopped: true, stopSaved: true))
    }
}
