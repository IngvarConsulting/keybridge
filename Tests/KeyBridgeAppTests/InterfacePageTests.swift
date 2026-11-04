// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeApp

@MainActor
final class InterfacePageTests: XCTestCase {
    private func store(_ state: [String: Any] = [:]) -> KeyBridgeInterfaceState {
        let ui = KeyBridgeInterfaceState()
        ui.update(["state": ["phase": "stopped", "prepared": true, "client": "managed", "key": false,
                             "want": false, "saved": true, "autoAvailable": true, "permission": "allowed"]
            .merging(state) { _, new in new }])
        return ui
    }

    func testEveryRuntimePhaseSelectsItsIntendedNativeScreen() async throws {
        let phases = ["agent-update", "loading", "unknown", "data-error", "paused", "reconciling", "rollback-error", "restore-error",
                      "preparing", "starting", "stopping", "recovering", "configuring", "restoring", "restoring-version",
                      "install-error", "start-error", "unsafe", "multiple", "exhausted", "waiting", "update-error", "stopped", "ready"]
        for phase in phases {
            let ui = store(["phase": phase])
            XCTAssertEqual(ui.screen, phase, phase)
            XCTAssertNotEqual(ui.pageCopy.title, "KeyBridge", phase)
            XCTAssertFalse(ui.pageCopy.body.isEmpty, phase)
            XCTAssertEqual(Set(ui.footerActions.map(\.id)).count, ui.footerActions.count, phase)
            XCTAssertLessThanOrEqual(ui.footerActions.filter(\.primary).count, 1, phase)
        }
        XCTAssertEqual(store(["phase": "first", "prepared": false, "client": "missing"]).screen, "setup")
        XCTAssertEqual(store(["phase": "probing", "key": true]).screen, "diagnosis")
        XCTAssertEqual(store(["saved": false]).screen, "stop-unsaved")
        XCTAssertEqual(store(["phase": "unexpected-new-phase"]).screen, "unknown")
    }

    func testMissingClientAndConfigurationErrorsHaveTheirOwnActionableScreens() async throws {
        for (client, action) in [("missing", "check-client"), ("unknown", "check-client"),
                                 ("unconfigured", "configure"), ("external", "review-settings")] {
            let ui = store(["client": client])
            XCTAssertEqual(ui.screen, "client-" + client)
            XCTAssertFalse(ui.pageCopy.remedy.isEmpty)
            XCTAssertTrue(ui.footerActions.contains { $0.id == action && !$0.disabled }, client)
            XCTAssertFalse(ui.footerActions.contains { $0.id == "start" && !$0.disabled }, client)
        }
        let denied = store(["client": "unconfigured", "accessError": "configuring",
                            "errorMessage": "Недостаточно места для копии настроек"])
        XCTAssertEqual(denied.screen, "access-error")
        XCTAssertEqual(denied.pageCopy.body, "Недостаточно места для копии настроек")
        XCTAssertEqual(denied.backAction?.id, "dismiss-access")
        denied.perform("dismiss-access")
        XCTAssertEqual(denied.screen, "client-unconfigured")
        XCTAssertFalse(denied.pageCopy.body.contains("Недостаточно места"))
    }

    func testProbeLivesOnlyInDiagnosticsAndRetainsOneIdentityAndLabel() async throws {
        let ui = store(["phase": "ready", "key": true])
        XCTAssertFalse(ui.footerActions.contains { $0.id == "probe" })
        XCTAssertTrue(ui.footerActions.contains { $0.id == "monitor" && $0.primary })
        ui.perform("diagnose")
        for outcome in ["none", "success", "unconfirmed", "failure", "timeout", "stale"] {
            ui.update(["state": ["proof": outcome]])
            let probe = try XCTUnwrap(ui.footerActions.first { $0.id == "probe" })
            XCTAssertEqual(probe.title, "Проверить в 1С", outcome)
            XCTAssertEqual(ui.footerActions.last?.id, "probe", outcome)
            XCTAssertFalse(probe.disabled, outcome)
        }
        ui.update(["state": ["phase": "probing"]])
        XCTAssertEqual(ui.screen, "diagnosis")
        XCTAssertTrue(try XCTUnwrap(ui.footerActions.last).disabled)
        ui.update(["state": ["phase": "unknown", "key": false]])
        XCTAssertEqual(ui.screen, "unknown")
        XCTAssertFalse(ui.footerActions.contains { $0.id == "probe" })
    }

    func testOrdinaryPendingCommandsKeepTheirScreenAndSafetyStopAvailable() async throws {
        for phase in ["ready", "waiting", "stopped"] {
            let ui = store(["phase": phase, "operationPending": true])
            XCTAssertEqual(ui.screen, phase)
            XCTAssertFalse(ui.pageCopy.title.isEmpty)
            XCTAssertFalse(ui.stopDisabled)
        }
        for phase in ["preparing", "starting", "recovering", "probing", "unknown", "paused", "reconciling"] {
            XCTAssertFalse(store(["phase": phase]).stopDisabled, phase)
        }
    }

    func testPausedCopyNamesSleepOnlyWhenSystemSleepWasObserved() async throws {
        let ui = store(["phase": "paused", "sessionActive": false, "hold": true])
        let unconfirmed: [[String: Any]] = [[:],
            ["sessionAvailability": "unavailable", "sessionReason": "session-off-console"],
            ["sessionAvailability": "unavailable", "sessionReason": "login-incomplete"],
            ["sessionAvailability": "unavailable", "sessionReason": "observation-unavailable"],
            ["sessionAvailability": "sleeping", "sessionReason": ""]]
        for observation in unconfirmed {
            let reset: [String: Any] = ["sessionAvailability": "", "sessionReason": ""]
            ui.update(["state": reset.merging(observation) { _, new in new }])
            XCTAssertFalse(ui.pageCopy.body.contains("сон"))
            XCTAssertFalse(ui.footnote.contains("пробуждения"))
            XCTAssertTrue(ui.pageCopy.remedy.contains("разблокируйте Mac"))
            XCTAssertTrue(ui.pageCopy.remedy.contains("автоматической проверки"))
            XCTAssertFalse(ui.stopDisabled)
            XCTAssertFalse(ui.footerActions.contains { $0.id == "start" })
        }
        ui.update(["state": ["sessionAvailability": "sleeping", "sessionReason": "system-sleep"]])
        XCTAssertTrue(ui.pageCopy.body.contains("Mac перешёл в сон"))
        XCTAssertEqual(ui.footnote, "Ожидаем пробуждения.")
        ui.update(["state": ["sessionAvailability": "unavailable", "sessionReason": "observation-unavailable"]])
        XCTAssertTrue(ui.pageCopy.body.contains("пока не подтвердил"))
        XCTAssertFalse(ui.pageCopy.body.contains("сон"))
        XCTAssertFalse(ui.footnote.contains("пробуждения"))
    }

    func testReconciliationWithoutObservedCauseDoesNotClaimWakeFromSleep() async throws {
        let ui = store(["phase": "reconciling"])
        XCTAssertFalse(ui.pageCopy.body.contains("сна"))
        XCTAssertTrue(ui.pageCopy.body.contains("сохранённый выбор"))
        XCTAssertFalse(ui.stopDisabled)
        XCTAssertFalse(ui.footerActions.contains { $0.id == "start" })
    }

    func testInvalidRuntimeOffersRecheckAndStopWithoutMaintenanceWorkflow() async throws {
        let ui = store(["phase": "data-error", "dataError": "Данные повреждены. Восстановите их из резервной копии."])
        XCTAssertEqual(ui.screen, "data-error")
        XCTAssertTrue(ui.pageCopy.body.contains("Восстановите"))
        XCTAssertEqual(ui.footerActions.map(\.id), ["recheck"])
        XCTAssertFalse(ui.stopDisabled)
        ui.update(["state": ["phase": "first", "prepared": false, "dataError": ""]])
        XCTAssertEqual(ui.screen, "setup")
        XCTAssertFalse(ui.pageCopy.body.contains("повреждены"))
        ui.perform("additional-actions")
        XCTAssertEqual(ui.screen, "additional")
        ui.perform("application")
        XCTAssertEqual(ui.screen, "additional", "Removed application maintenance navigation must not open a dead page")
    }

    func testSettingsExposeAdditionalActionsDuringPreferenceAndPermissionFailures() async throws {
        let states: [[String: Any]] = [["autoAvailable": false], ["permission": "denied"],
                                      ["permission": "unknown"], ["auto": true, "permission": "unregistered"],
                                      ["auto": true, "hold": true], ["client": "external"]]
        for state in states {
            let ui = store(state)
            ui.navigate("settings")
            XCTAssertEqual(ui.footerActions.first?.id, "additional-actions")
            XCTAssertFalse(try XCTUnwrap(ui.footerActions.first).disabled)
            ui.perform("additional-actions")
            XCTAssertEqual(ui.screen, "additional")
            XCTAssertEqual(ui.backAction?.id, "back")
            XCTAssertEqual(Set(ui.footerActions.map(\.id)), ["replace", "restore"])
            ui.perform("resources")
            XCTAssertEqual(ui.screen, "resources")
            ui.back()
            XCTAssertEqual(ui.screen, "additional")
            ui.back()
            XCTAssertEqual(ui.screen, "settings")
        }
    }

    func testRecoveryActionsAreSpecificAndNeverPretendUnsavedStopSucceeded() async throws {
        let stop = store(["saved": false, "pendingQuit": true])
        XCTAssertEqual(stop.screen, "stop-unsaved")
        XCTAssertEqual(stop.footerActions.last?.id, "save-stop")
        XCTAssertTrue(stop.pageCopy.body.contains("может снова включиться"))
        let update = store(["updateProblem": true, "previousAvailable": true])
        XCTAssertEqual(update.screen, "update-error")
        XCTAssertTrue(update.footerActions.contains { $0.id == "rollback" })
        let restore = store(["phase": "restore-error", "backupAvailable": false])
        XCTAssertTrue(restore.pageCopy.body.contains("не найдена"))
        XCTAssertNotNil(restore.backAction)
        let multiple = store(["phase": "multiple"])
        XCTAssertEqual(multiple.footerActions.last?.id, "recheck")
        XCTAssertFalse(multiple.footerActions.contains { $0.id == "start" })
    }
}
