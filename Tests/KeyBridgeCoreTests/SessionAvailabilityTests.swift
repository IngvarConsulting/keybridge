// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class SessionAvailabilityTests: XCTestCase {
    let available=SessionAvailability.Observation(onConsole:true,loginDone:true)
    let switchedOut=SessionAvailability.Observation(onConsole:false,loginDone:true)
    func testFreshObservationRecoversMissedActivationAfterInactiveLaunch() {
        let state=SessionAvailability(observation:switchedOut)
        XCTAssertFalse(state.state.active)
        let change=state.observe(.poll,observation:available)
        XCTAssertFalse(change.before.active);XCTAssertTrue(change.after.active)
        XCTAssertEqual(change.after.availability,.active)
    }
    func testUnavailableObservationIsNotMisreportedAsSleep() {
        let state=SessionAvailability(observation:.init(onConsole:nil,loginDone:nil))
        XCTAssertEqual(state.state.availability,.unavailable)
        XCTAssertEqual(state.state.reason,"observation-unavailable")
        state.observe(.poll,observation:available)
        XCTAssertTrue(state.state.active)
        state.observe(.poll,observation:.init(onConsole:true,loginDone:nil))
        XCTAssertFalse(state.state.active)
    }
    func testConsolePollingAndSessionActivationCannotOverrideSystemSleep() {
        let state=SessionAvailability(observation:available)
        state.observe(.willSleep,observation:available)
        state.observe(.poll,observation:available)
        state.observe(.didBecomeActive,observation:available)
        XCTAssertEqual(state.state.availability,.sleeping)
        XCTAssertEqual(state.state.reason,"system-sleep")
        state.observe(.didWake,observation:available)
        XCTAssertTrue(state.state.active)
    }
    func testWakeDoesNotAuthorizeSwitchedOutOrIncompleteLogin() {
        let state=SessionAvailability(observation:available)
        state.observe(.willSleep,observation:available)
        state.observe(.didWake,observation:switchedOut)
        XCTAssertFalse(state.state.active);XCTAssertEqual(state.state.reason,"session-off-console")
        state.observe(.didBecomeActive,observation:.init(onConsole:true,loginDone:false))
        XCTAssertFalse(state.state.active);XCTAssertEqual(state.state.reason,"login-incomplete")
    }
    func testPreSwitchNotificationCannotBeUndoneByOldConsoleSample() {
        let state=SessionAvailability(observation:available)
        state.observe(.willResignActive,observation:available)
        state.observe(.poll,observation:available)
        XCTAssertFalse(state.state.active)
        state.observe(.poll,observation:switchedOut)
        state.observe(.poll,observation:available)
        XCTAssertTrue(state.state.active,"Fresh console observation recovers a missed switch-in event")
    }
    func testActivationObservationDoesNotModifySavedStopOrAuthorizeRunning() throws {
        let runtime=FileManager.default.temporaryDirectory.appendingPathComponent("kb-session-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer { try? FileManager.default.removeItem(at:runtime) }
        let intent=try IntentStore(runtime:runtime);try intent.stop()
        let before=try Data(contentsOf:runtime.appendingPathComponent("intent.json"))
        let state=SessionAvailability(observation:switchedOut)
        state.observe(.poll,observation:available)
        XCTAssertTrue(state.state.active)
        XCTAssertFalse(intent.value.want);XCTAssertTrue(intent.value.autoInhibit)
        XCTAssertFalse(state.state.permitsAutomaticResume(authorized:true,wantsRunning:intent.value.want,inhibited:intent.value.autoInhibit))
        XCTAssertFalse(state.state.permitsAutomaticResume(authorized:false,wantsRunning:true,inhibited:false))
        XCTAssertFalse(state.state.permitsAutomaticResume(authorized:true,wantsRunning:true,inhibited:true))
        XCTAssertTrue(state.state.permitsAutomaticResume(authorized:true,wantsRunning:true,inhibited:false))
        XCTAssertEqual(try Data(contentsOf:runtime.appendingPathComponent("intent.json")),before)
    }
}
