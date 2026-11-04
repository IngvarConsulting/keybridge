// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeApp

@MainActor
final class InterfaceStateTests: XCTestCase {
    func testRejectedProbeExplainsFailureAndClearsOnRetryOrContextChange() throws {
        let ui = store(["phase": "ready", "key": true, "proof": "stale"])
        let first = try XCTUnwrap(ui.request("probe"))
        complete(ui, first, ok: false, message: "Контроллер занят; повторите после завершения операции")
        XCTAssertTrue(ui.result("probe").contains("Контроллер занят"))
        XCTAssertFalse(ui.pendingAction("probe"))
        let retry = try XCTUnwrap(ui.request("probe"))
        XCTAssertFalse(ui.result("probe").contains("Контроллер занят"))
        complete(ui, retry, ok: true, state: ["proof": "unconfirmed"])
        XCTAssertEqual(ui.result("probe"), "")
        let old = try XCTUnwrap(ui.request("probe"))
        complete(ui, old, ok: false, message: "Old failure", state: ["contextVersion": "B"])
        XCTAssertEqual(ui.result("probe"), "")
    }

    func testBusyProbeWaitsExplicitlyAndStopDropsEveryOldReply() throws {
        let ui=store(["phase":"ready","key":true,"operationPending":true])
        ui.perform("diagnose")
        XCTAssertFalse(try XCTUnwrap(ui.footerActions.first {$0.id=="probe"}).disabled)
        let probe=try XCTUnwrap(ui.request("probe"))
        XCTAssertNil(ui.request("measure"))
        XCTAssertNil(ui.request("start"))
        let preference=try XCTUnwrap(ui.request("autostart",value:true))
        ui.update(["state":["phase":"starting","pendingDiagnostic":"probe"]])
        XCTAssertEqual(ui.footnote,"Проверка ожидает завершения текущего действия")
        XCTAssertEqual(ui.screen,"starting")
        XCTAssertNil(ui.request("recheck"))
        let stop=try XCTUnwrap(ui.request("stop"))
        XCTAssertFalse(ui.diagnosticWaiting)
        let revision=ui.feedbackRevision
        complete(ui,probe,ok:true)
        complete(ui,preference,ok:true)
        XCTAssertEqual(ui.feedbackRevision,revision)
        XCTAssertTrue(ui.pendingAction("stop"))
        complete(ui,stop,ok:true,state:["phase":"stopped","operationPending":false])
        XCTAssertFalse(ui.autoSaved)
    }
    func testActiveProbeAllowsOneResourceWaitAndIndependentAutostartCompletion() throws {
        let ui=store(["phase":"ready","key":true])
        let probe=try XCTUnwrap(ui.request("probe"))
        ui.update(["state":["phase":"probing","activeDiagnostic":"probe","operationPending":true]])
        let measurement=try XCTUnwrap(ui.request("measure"))
        ui.update(["state":["pendingDiagnostic":"resources"]])
        XCTAssertNil(ui.request("recheck"))
        let preference=try XCTUnwrap(ui.request("autostart",value:true))
        complete(ui,preference,ok:true,state:["auto":true])
        XCTAssertTrue(ui.autoSaved)
        XCTAssertTrue(ui.pendingAction("probe"))
        XCTAssertTrue(ui.pendingAction("measure"))
        complete(ui,probe,ok:true,state:["phase":"ready","proof":"success","pendingDiagnostic":NSNull(),"activeDiagnostic":"resources"])
        XCTAssertFalse(ui.diagnosticWaiting)
        complete(ui,measurement,ok:true,state:["operationPending":false,"activeDiagnostic":""])
        XCTAssertFalse(ui.busy)
        XCTAssertEqual(ui.text("proof"),"success")
    }
    func testSafetyAndStoppingBlockProbeButReadOnlyInspectionCanCheckSafety() throws {
        for phase in ["unsafe","multiple","unknown","data-error","paused","reconciling","stopping"] {
            let ui=store(["phase":phase,"key":true,"operationPending":true])
            XCTAssertNil(ui.request("probe"),phase)
            if ["unsafe","multiple","unknown","data-error"].contains(phase) {XCTAssertNotNil(ui.request("recheck"),phase)}
        }
    }
    func testUnsavedProofRemainsVisibleAndPreferenceDoesNotEraseIt() throws {
        let ui=store(["phase":"ready","key":true,"proof":"success","proofSaveError":"Нет места"])
        ui.perform("diagnose")
        let preference=try XCTUnwrap(ui.request("autostart",value:true))
        complete(ui,preference,ok:true,state:["auto":true])
        XCTAssertEqual(ui.text("proof"),"success")
        XCTAssertTrue(ui.proofSaveNote.contains("не сохранён"))
        XCTAssertTrue(ui.proofSaveNote.contains("Нет места"))
        ui.update(["state":["proofSaveError":""]])
        XCTAssertEqual(ui.proofSaveNote,"")
    }

    private func store(_ overrides: [String: Any] = [:], send: @escaping ([String: Any]) -> Void = { _ in }) -> KeyBridgeInterfaceState {
        let value = KeyBridgeInterfaceState(send: send)
        value.update(["state": ["phase": "stopped", "prepared": true, "client": "managed", "contextVersion": "A",
                                "want": false, "hold": true, "saved": true, "auto": false,
                                "autoAvailable": true, "permission": "allowed", "operationPending": false]
            .merging(overrides) { _, new in new }])
        return value
    }

    private func complete(_ store: KeyBridgeInterfaceState, _ request: [String: Any], ok: Bool,
                          message: String = "", state: [String: Any] = [:]) {
        store.update(["state": state, "feedback": ["id": request["id"]!, "action": request["action"]!,
                                                   "ok": ok, "message": message]])
    }

    func testFirstObservationAndActionReceiptNeverInventRuntimeSuccess() async throws {
        var sent: [[String: Any]] = []
        let initial = KeyBridgeInterfaceState(send: { sent.append($0) })
        XCTAssertEqual(initial.screen, "loading")
        XCTAssertFalse(initial.flag("prepared"))
        XCTAssertFalse(initial.flag("key"))
        XCTAssertEqual(initial.text("proof"), "")
        let ui = store(send: { sent.append($0) })
        let request = try XCTUnwrap(ui.request("start"))
        XCTAssertEqual(ui.screen, "stopped")
        XCTAssertFalse(ui.flag("want"))
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(ui.busy)
        ui.update(["state": ["phase": "starting", "operationPending": true]])
        XCTAssertEqual(ui.pending.count, 1)
        XCTAssertEqual(ui.screen, "starting")
        complete(ui, request, ok: true, state: ["phase": "ready", "want": true, "hold": false,
                                               "key": true, "operationPending": false])
        XCTAssertEqual(ui.screen, "ready")
        XCTAssertTrue(ui.flag("want"))
        XCTAssertFalse(ui.busy)
    }

    func testStopInvalidatesPreparationAndPreferenceRepliesWithoutInventingSavedIntent() async throws {
        let ui = store()
        let prepare = try XCTUnwrap(ui.request("prepare"))
        let preference = try XCTUnwrap(ui.request("autostart", value: true))
        let stop = try XCTUnwrap(ui.request("stop"))
        XCTAssertEqual(ui.pending.count, 1)
        XCTAssertNil(ui.pendingAuto)
        XCTAssertFalse(ui.autoWorking)
        XCTAssertFalse(ui.flag("auto"))
        let revision = ui.feedbackRevision
        complete(ui, prepare, ok: true, message: "Old installation completed")
        complete(ui, preference, ok: true, message: "Old choice saved")
        XCTAssertEqual(ui.feedbackRevision, revision)
        XCTAssertEqual(ui.result("install"), "")
        XCTAssertFalse(ui.autoSaved)
        XCTAssertTrue(ui.pendingAction("stop"))
        complete(ui, stop, ok: false, message: "Не удалось сохранить выключение", state: ["saved": false])
        XCTAssertEqual(ui.screen, "stop-unsaved")
        XCTAssertFalse(ui.flag("saved"))
        XCTAssertEqual(ui.result("stop"), "Не удалось сохранить выключение")
    }

    func testUnsupportedAutostartCannotBeEnabledButSavedChoiceCanBeDisabled() async throws {
        var sent: [[String: Any]] = []
        let ui = store(["autoAvailable": false, "auto": true], send: { sent.append($0) })
        XCTAssertNil(ui.request("autostart", value: true))
        XCTAssertNil(ui.request("check-permission"))
        XCTAssertTrue(sent.isEmpty)
        ui.navigate("settings")
        XCTAssertFalse(ui.footerActions.contains { ["permission", "check-permission", "resume-auto"].contains($0.id) })
        let off = try XCTUnwrap(ui.request("autostart", value: false))
        complete(ui, off, ok: false, message: "Не удалось удалить регистрацию")
        XCTAssertEqual(ui.pendingAuto, false)
        XCTAssertTrue(ui.flag("auto"))
        XCTAssertEqual(ui.autoError, "Не удалось удалить регистрацию")
        XCTAssertEqual(ui.footerActions.last?.id, "retry-auto")
        XCTAssertFalse(try XCTUnwrap(ui.footerActions.last).disabled)
    }

    func testAutostartDisableFailureRetryAndCancelKeepSavedChoiceSeparate() async throws {
        let ui = store(["auto": true, "hold": false])
        ui.navigate("settings")
        let off = try XCTUnwrap(ui.request("autostart", value: false))
        XCTAssertEqual(ui.pendingAuto, false)
        XCTAssertTrue(ui.autoWorking)
        XCTAssertTrue(ui.flag("auto"))
        ui.cancelAuto()
        XCTAssertEqual(ui.pendingAuto, false)
        XCTAssertTrue(try XCTUnwrap(ui.footerActions.first { $0.id == "cancel-auto" }).disabled)
        complete(ui, off, ok: false, message: "Запись не завершена")
        XCTAssertFalse(ui.autoWorking)
        XCTAssertFalse(ui.autoSaved)
        XCTAssertTrue(ui.flag("auto"))
        ui.cancelAuto()
        XCTAssertNil(ui.pendingAuto)
        XCTAssertEqual(ui.autoError, "")
        XCTAssertTrue(ui.flag("auto"))
        let retry = try XCTUnwrap(ui.request("autostart", value: false))
        complete(ui, retry, ok: true, state: ["auto": false, "permission": "unregistered"])
        XCTAssertNil(ui.pendingAuto)
        XCTAssertTrue(ui.autoSaved)
        XCTAssertFalse(ui.flag("auto"))
        XCTAssertFalse(ui.flag("hold"))
    }

    func testMissingRegistrationOffersRepairWithoutClearingSavedChoice() async throws {
        var sent: [[String: Any]] = []
        let ui = store(["auto": true, "permission": "unregistered"], send: { sent.append($0) })
        ui.navigate("settings")
        XCTAssertTrue(ui.autoExplanation.contains("нет записи"))
        XCTAssertFalse(ui.autoExplanation.contains("сможет включиться"))
        XCTAssertEqual(ui.footerActions.last?.title, "Восстановить автозапуск")
        ui.perform("resume-auto")
        XCTAssertEqual(sent.last?["action"] as? String, "autostart")
        XCTAssertEqual(sent.last?["value"] as? Bool, true)
        XCTAssertTrue(ui.flag("auto"))
        XCTAssertEqual(ui.text("permission"), "unregistered")
    }

    func testCapabilityLossInvalidatesEnableCompletionAndPermissionNavigation() async throws {
        let ui = store()
        ui.navigate("settings")
        ui.perform("permission")
        ui.perform("manual-license")
        let enable = try XCTUnwrap(ui.request("autostart", value: true))
        ui.update(["state": ["autoAvailable": false]])
        XCTAssertNil(ui.pendingAuto)
        XCTAssertFalse(ui.autoWorking)
        XCTAssertFalse(ui.navigation.contains { $0.page == "permission" })
        complete(ui, enable, ok: true)
        XCTAssertFalse(ui.autoSaved)
        XCTAssertFalse(ui.flag("auto"))
        ui.back()
        XCTAssertEqual(ui.screen, "settings")
    }

    func testWizardRequiresValidatedFilesAndKeepsOtherComponentDuringReplacement() async throws {
        let ui = store(["phase": "first", "prepared": false, "client": "missing"])
        XCTAssertEqual(ui.screen, "setup")
        XCTAssertTrue(try XCTUnwrap(ui.footerActions.last).disabled)
        ui.perform("setup-next")
        XCTAssertEqual(ui.setupStep, "installer")
        ui.update(["files": ["installer": ["name": "server.zip", "valid": true, "validation": "preflight"]]])
        ui.perform("setup-next")
        XCTAssertEqual(ui.setupStep, "driver")
        ui.update(["files": ["driver": ["name": "wrong-architecture.deb", "valid": false, "error": "Нужен пакет amd64"]]])
        ui.perform("setup-next")
        XCTAssertEqual(ui.setupStep, "driver")
        XCTAssertEqual(ui.files["installer"]?.name, "server.zip")
        ui.update(["files": ["driver": ["name": "Sentinel.tar.gz", "valid": true, "validation": "complete"]]])
        ui.perform("setup-next")
        XCTAssertEqual(ui.setupStep, "review")
        XCTAssertEqual(ui.footerActions.last?.id, "prepare")
        XCTAssertFalse(try XCTUnwrap(ui.footerActions.last).disabled)
        ui.update(["files": ["installer": ["name": "new-server.zip", "valid": false, "checking": true]]])
        XCTAssertTrue(try XCTUnwrap(ui.footerActions.last).disabled)
        XCTAssertEqual(ui.files["driver"]?.name, "Sentinel.tar.gz")
    }

    func testCancelledFileCheckCannotApplyLateFeedbackOrDiscardOtherFile() async throws {
        let ui = store(["phase": "first", "prepared": false])
        ui.update(["files": ["installer": ["name": "server.zip", "valid": false, "checking": true],
                              "driver": ["name": "Sentinel.tar.gz", "valid": true]]])
        let check = try XCTUnwrap(ui.request("installer"))
        let cancel = try XCTUnwrap(ui.request("cancel-installer"))
        XCTAssertFalse(ui.pendingAction("installer"))
        complete(ui, cancel, ok: true)
        ui.update(["files": ["installer": ["name": "server.zip", "valid": false, "checking": false, "message": "Проверка отменена"]]])
        let revision = ui.feedbackRevision
        complete(ui, check, ok: true, message: "Late success")
        XCTAssertEqual(ui.feedbackRevision, revision)
        XCTAssertEqual(ui.files["installer"]?.valid, false)
        XCTAssertEqual(ui.files["driver"]?.valid, true)
        XCTAssertEqual(ui.files["driver"]?.name, "Sentinel.tar.gz")
    }

    func testCompositionFailuresRequireDifferentInstallerAndPreserveDriver() async throws {
        for issue in ["missing-license-manager", "ambiguous-license-manager"] {
            let ui = store(["phase": "install-error", "installerIssue": issue, "prepared": false])
            ui.update(["files": ["installer": ["name": "old.run", "valid": false, "error": "Нужен другой установщик"],
                                  "driver": ["name": "driver.deb", "valid": true]]])
            XCTAssertEqual(ui.footerActions.map(\.id), ["replace"])
            XCTAssertNil(ui.request("prepare"))
            XCTAssertFalse(ui.pageCopy.remedy.contains("Повторите установку"))
            ui.perform("replace")
            XCTAssertEqual(ui.screen, "setup")
            ui.update(["files": ["installer": ["name": "replacement.run", "valid": true, "validation": "preflight"]]])
            XCTAssertEqual(ui.files["driver"]?.name, "driver.deb")
            XCTAssertEqual(ui.files["driver"]?.valid, true)
            XCTAssertNotNil(ui.request("prepare"))
        }
    }

    func testPollingPreservesNestedNavigationAndWizardPosition() async throws {
        let ui = store()
        ui.navigate("settings")
        ui.perform("additional-actions")
        ui.perform("resources")
        ui.update(["state": ["phase": "stopped", "tab": "main", "help": "", "auto": true]])
        XCTAssertEqual(ui.screen, "resources")
        ui.back()
        XCTAssertEqual(ui.screen, "additional")
        XCTAssertEqual(ui.requestedFocus, "resources")
        ui.perform("replace")
        ui.setupStep = "driver"
        ui.update(["state": ["setupStep": "installer", "editing": false]])
        XCTAssertTrue(ui.editing)
        XCTAssertEqual(ui.setupStep, "driver")
        ui.back()
        XCTAssertEqual(ui.screen, "additional")
        XCTAssertEqual(ui.tab, "settings")
    }

    func testScopedErrorsClearAfterChangedObservationWithoutLosingHelpRoute() async throws {
        let ui = store()
        ui.perform("manual-license")
        let key = try XCTUnwrap(ui.request("check-key"))
        complete(ui, key, ok: false, message: "USB-ключ не найден")
        XCTAssertEqual(ui.result("key"), "USB-ключ не найден")
        ui.update(["state": ["contextVersion": "B", "key": true, "phase": "ready"]])
        XCTAssertEqual(ui.result("key"), "")
        XCTAssertEqual(ui.screen, "manual")
        let late = try XCTUnwrap(ui.request("check-key"))
        complete(ui, late, ok: false, message: "Old key disconnected", state: ["contextVersion": "C"])
        XCTAssertEqual(ui.result("key"), "")
        ui.navigate("settings")
        let permission = try XCTUnwrap(ui.request("check-permission"))
        complete(ui, permission, ok: false, message: "Нет разрешения")
        XCTAssertEqual(ui.result("permission"), "Нет разрешения")
        ui.update(["state": ["permission": "unregistered"]])
        XCTAssertEqual(ui.result("permission"), "")
    }

    func testMonitorHelpBackCannotResurrectFailureFromPreviousContext() async throws {
        let ui = store(["phase": "ready", "key": true])
        let monitor = try XCTUnwrap(ui.request("monitor"))
        complete(ui, monitor, ok: false, message: "Монитор не открыт")
        XCTAssertEqual(ui.screen, "monitor-error")
        ui.perform("manual-license")
        ui.update(["state": ["phase": "waiting", "key": false, "contextVersion": "B"]])
        XCTAssertEqual(ui.screen, "manual")
        XCTAssertEqual(ui.result("monitor"), "")
        ui.back()
        XCTAssertEqual(ui.screen, "waiting")
        XCTAssertFalse(ui.navigation.contains { $0.page == "monitor-error" })
    }

    func testDuplicateForeignAndRepeatedFeedbackHaveDistinctOutcomes() async throws {
        let ui = store()
        XCTAssertNil(ui.request("exec", value: "anything"))
        ui.update(["feedback": ["id": "foreign", "action": "monitor", "ok": false, "message": "Foreign failure"]])
        XCTAssertEqual(ui.screen, "stopped")
        let first = try XCTUnwrap(ui.request("check-client"))
        XCTAssertNil(ui.request("check-client"))
        complete(ui, first, ok: false, message: "Не найдено")
        let revision = ui.feedbackRevision
        complete(ui, first, ok: false, message: "Не найдено")
        XCTAssertEqual(ui.feedbackRevision, revision)
        let repeatRequest = try XCTUnwrap(ui.request("check-client"))
        complete(ui, repeatRequest, ok: false, message: "Не найдено")
        XCTAssertEqual(ui.feedbackRevision, revision + 1)
        XCTAssertNotNil(ui.request("open-url", value: "https://releases.1c.ru/project/Platform85"))
        XCTAssertTrue(ui.pending.isEmpty)
        XCTAssertNil(ui.request("hide"))
    }

    func testSafetyInterruptionLeavesWizardAndLateProbeCannotUndoStop() async throws {
        for phase in ["paused", "unknown", "unsafe", "multiple", "reconciling", "stopping"] {
            let ui = store()
            ui.perform("replace")
            ui.setupStep = "review"
            ui.perform("manual-license")
            ui.update(["state": ["phase": phase]])
            XCTAssertFalse(ui.editing, phase)
            XCTAssertEqual(ui.tab, "main", phase)
            XCTAssertEqual(ui.screen, phase, phase)
        }
        let ui = store(["phase": "ready", "key": true])
        let probe = try XCTUnwrap(ui.request("probe"))
        let quit = try XCTUnwrap(ui.request("quit"))
        complete(ui, probe, ok: true, message: "Old probe")
        XCTAssertTrue(ui.pendingAction("quit"))
        complete(ui, quit, ok: false, state: ["phase": "stopped", "saved": false, "pendingQuit": true])
        var next = ""
        let continuation = store(["phase": "stopped", "saved": false, "pendingQuit": true], send: { next = $0["action"] as? String ?? "" })
        continuation.perform("save-stop")
        XCTAssertEqual(next, "quit")
    }

    func testObservedResourcesDoNotReplaceMissingMeasurementWithZero() async throws {
        let ui = store()
        XCTAssertTrue(ui.resourceRows.isEmpty)
        ui.update(["resourceRows": [["label": "Память процесса", "value": "Нет измерения"],
                                    ["label": "Предыдущая установка", "value": "0 МиБ"]],
                   "resourcesNote": "Предыдущий замер"])
        XCTAssertEqual(ui.resourceRows.map(\.value), ["Нет измерения", "0 МиБ"])
        XCTAssertEqual(ui.resourcesNote, "Предыдущий замер")
    }

    func testReturningCheckboxToSavedValueCancelsOnlyFailedChoice() async throws {
        var sent: [[String: Any]] = []
        let ui = store(send: { sent.append($0) })
        ui.chooseAuto(true)
        let request = try XCTUnwrap(sent.last)
        complete(ui, request, ok: false, message: "Не сохранено")
        ui.chooseAuto(false)
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(ui.pendingAuto)
        XCTAssertEqual(ui.autoError, "")
        XCTAssertFalse(ui.flag("auto"))
        XCTAssertTrue(ui.flag("hold"))
    }

    func testConfigurationReviewReturnsToSettingsAndRestoreRetryKeepsItsAction() async throws {
        var sent: [[String: Any]] = []
        let ui = store(["client": "external"], send: { sent.append($0) })
        ui.navigate("settings")
        ui.perform("review-settings")
        XCTAssertEqual(ui.screen, "review-settings")
        XCTAssertEqual(ui.tab, "main")
        ui.perform("cancel-settings")
        XCTAssertEqual(ui.screen, "settings")
        ui.navigate("main")
        ui.update(["state": ["client": "managed", "accessError": "restoring", "errorMessage": "Возврат не записан"]])
        ui.perform("retry-access")
        XCTAssertEqual(sent.last?["action"] as? String, "restore")
    }

    func testFileSelectionFailureIsLocalAndDoesNotInvalidatePreviousValidatedFile() async throws {
        for kind in ["installer", "driver"] {
            let ui = store(["phase": "first", "prepared": false])
            ui.update(["files": [kind: ["name": "previous-valid-file", "valid": true, "message": "Файл проверен"]]])
            let selection = try XCTUnwrap(ui.request(kind))
            complete(ui, selection, ok: false, message: "Не удалось открыть выбор файла. Завершите текущее действие и повторите выбор.")
            XCTAssertFalse(ui.pendingAction(kind))
            XCTAssertTrue(ui.result("file-" + kind).contains("Не удалось открыть"))
            XCTAssertEqual(ui.files[kind]?.name, "previous-valid-file")
            XCTAssertEqual(ui.files[kind]?.valid, true)
            XCTAssertEqual(ui.files[kind]?.error, "")
            ui.update(["state": ["phase": "first"]])
            XCTAssertFalse(ui.result("file-" + kind).isEmpty)
            let retry = try XCTUnwrap(ui.request(kind))
            XCTAssertEqual(ui.result("file-" + kind), "")
            ui.update(["feedback": ["id": retry["id"]!, "ok": false, "cancelled": true, "message": ""]])
            XCTAssertEqual(ui.result("file-" + kind), "")
            let again = try XCTUnwrap(ui.request(kind))
            complete(ui, again, ok: false, message: "Old error")
            ui.update(["files": [kind: ["name": "new-file", "valid": false, "checking": true]]])
            XCTAssertEqual(ui.result("file-" + kind), "")
        }
    }

    func testCompletedPreparationUsesNewNativeSelectionAndDoesNotRemoveStopInhibit() async throws {
        let ui = store(["selected": "previous"])
        ui.perform("replace")
        let request = try XCTUnwrap(ui.request("prepare"))
        complete(ui, request, ok: true, state: ["phase": "stopped", "prepared": true,
                                               "selected": "current", "hold": true, "want": false])
        XCTAssertFalse(ui.editing)
        XCTAssertFalse(ui.replacing)
        XCTAssertEqual(ui.text("selected"), "current")
        XCTAssertTrue(ui.flag("hold"))
        XCTAssertFalse(ui.flag("want"))
        XCTAssertEqual(ui.screen, "stopped")
    }
}
