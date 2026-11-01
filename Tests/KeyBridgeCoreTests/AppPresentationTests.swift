// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class AppPresentationTests: XCTestCase {
    func testAutostartCapabilityIsIndependentOfSavedChoiceAndOSPermission() {
        var observed=running
        observed["autostart"]=true
        observed["loginAccess"]="allowed"
        XCTAssertEqual(state(observed)["autoAvailable"] as?Bool,false)
        observed["loginLaunchSupported"]=false
        XCTAssertEqual(state(observed)["autoAvailable"] as?Bool,false)
        XCTAssertEqual(state(observed)["auto"] as?Bool,true)
        observed["loginLaunchSupported"]=true
        XCTAssertEqual(state(observed)["autoAvailable"] as?Bool,true)
    }
    private var running: [String: Any] {
        ["prepared": true, "running": true, "ownership": "owned", "status": "running",
         "keyConnected": true, "keyModel": "Observed key", "keyConnection": "connection-a", "clientState": "configured",
         "desiredRunning": true, "autoInhibit": false, "autostart": false, "loginAccess": "allowed",
         "generation": "generation-a", "runID": "run-a", "memoryMiB": 128, "cpus": 1,
         "currentVersion": "8.5.9", "runtimeVersion": "10.40", "sessionActive": true]
    }
    private var stopped: [String: Any] {
        var value = running
        value.merge(["running": false, "ownership": "absent", "status": "stopped", "keyConnected": false,
                     "desiredRunning": false, "autoInhibit": true, "usbReleased": true]) { _, new in new }
        return value
    }
    private func state(_ value: [String: Any], preparation: PreparationSnapshot? = nil) -> [String: Any] {
        AppPresentation.snapshot(status: value, preparation: preparation)["state"] as! [String: Any]
    }
    private func rows(_ value: [String: Any]) -> [String: String] {
        let rows = AppPresentation.snapshot(status: value)["resourceRows"] as! [[String: String]]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["label"]!, $0["value"]!) })
    }
    private var resourceSample: [String: Any] {
        ["sampledAt": 1_790_000_000.0,
         "context": ["generation": "generation-a", "run": "run-a", "ownership": "owned"],
         "base": ["available": true, "allocatedBytes": 64 * 1_048_576],
         "runtime": ["available": true, "allocatedBytes": 736 * 1_048_576],
         "generations": [
            ["role": "selected", "available": true, "allocatedBytes": 240 * 1_048_576],
            ["role": "previous", "available": true, "allocatedBytes": 220 * 1_048_576],
            ["role": "retained", "available": true, "allocatedBytes": 210 * 1_048_576],
            ["role": "candidate", "available": true, "allocatedBytes": 36 * 1_048_576]],
         "virtualDiskBytes": 5 * 1_073_741_824 as Int64,
         "guest": ["usedBytes": 74 * 1_048_576], "qemuRSSBytes": 234 * 1_048_576]
    }

    func testEmptyInputIsLoadingNotAnInventedSuccessfulOrStoppedState() {
        XCTAssertEqual(state([:])["phase"] as? String, "loading")
        XCTAssertEqual(state([:])["proof"] as? String, "none")
        XCTAssertEqual(rows([:])["Память для работы с ключом"], "Нет данных")
    }

    func testOfflineStatusCannotClaimRunningOrStoppedEvenIfPersistedSnapshotDoes() {
        for var old in [running, stopped] {
            old["stale"] = true
            old["lastProbe"] = ["result": "success", "success": true]
            XCTAssertEqual(state(old)["phase"] as? String, "unknown")
            XCTAssertEqual(state(old)["running"] as? Bool, false)
            XCTAssertEqual(state(old)["key"] as? Bool, false)
            XCTAssertEqual(state(old)["proof"] as? String, "stale")
        }
    }

    func testUnknownOwnershipOutranksSavedStopAndOldStoppedPhase() {
        var value = stopped
        value["ownership"] = "unknown"
        value["stopSaved"] = true
        XCTAssertEqual(state(value)["phase"] as? String, "unknown")
        XCTAssertEqual(state(value)["saved"] as? Bool, true)
        XCTAssertEqual(state(value)["hold"] as? Bool, true)
        value.removeValue(forKey: "ownership")
        XCTAssertEqual(state(value)["phase"] as? String, "unknown")
    }

    func testPhysicallyStoppedButUnsavedIntentRemainsDistinguishable() {
        var value = stopped
        value["stopSaved"] = false
        value["stopPersistenceError"] = "arbitrary diagnostic text"
        XCTAssertEqual(state(value)["phase"] as? String, "stopped")
        XCTAssertEqual(state(value)["saved"] as? Bool, false)
        value["stopSaved"] = true
        value["stopPersistenceError"] = NSNull()
        XCTAssertEqual(state(value)["saved"] as? Bool, true)
    }

    func testOperationsRemainInProgressRatherThanCompletingFromReceipt() {
        let expected = ["prepare": "preparing", "start": "starting", "stop": "stopping", "probe": "probing",
                        "configure": "configuring", "repair": "configuring", "restore": "restoring", "rollback": "restoring-version"]
        for (action, phase) in expected {
            var value = running; value["busy"] = true; value["operation"] = action
            XCTAssertEqual(state(value)["phase"] as? String, phase, action)
        }
    }

    func testNormalHealthPollDoesNotReplaceReadyScreenWithRestartScreen() {
        var value = running; value["busy"] = true; value["operation"] = "reconcile"
        XCTAssertEqual(state(value)["phase"] as? String, "ready")
        value["reconciling"] = true
        XCTAssertEqual(state(value)["phase"] as? String, "reconciling")
    }

    func testSleepAndReconciliationDoNotRemoveStopOrRefreshProof() {
        var value = stopped; value["sessionActive"] = false
        value["lastProbe"] = ["result": "success", "success": true]
        XCTAssertEqual(state(value)["phase"] as? String, "paused")
        XCTAssertEqual(state(value)["proof"] as? String, "stale")
        XCTAssertEqual(state(value)["hold"] as? Bool, true)
        value["sessionActive"] = true; value["reconciling"] = true
        XCTAssertEqual(state(value)["phase"] as? String, "reconciling")
        XCTAssertEqual(state(value)["want"] as? Bool, false)
    }

    func testProbeFailureDoesNotTurnHealthyKeyBridgeIntoFailedStart() {
        for outcome in ["failure", "unconfirmed", "timeout"] {
            var value = running
            value["lastProbe"] = ["result": outcome, "success": false]
            value["lastFailure"] = ["action": "probe", "kind": "operation", "message": "test"]
            XCTAssertEqual(state(value)["phase"] as? String, "ready")
            XCTAssertEqual(state(value)["proof"] as? String, outcome)
        }
    }

    func testAggregateIssuanceOrSuccessFlagAloneIsNotCausalProof() {
        var value = running
        value["lastProbe"] = ["result": "success", "success": true,
                              "managerIssuanceDelta": 1, "hardwareLocalDelta": 1]
        XCTAssertEqual(state(value)["proof"] as? String, "unconfirmed")
    }

    func testCausalProofMustMatchCurrentGenerationAndRun() {
        var value = running
        let evidence: [String: Any] = ["result": "success", "success": true, "clientOperationSucceeded": true,
            "journalContinuous": true, "contextStable": true, "causalIsolation": true,
            "managerIssuanceDelta": 1, "hardwareLocalDelta": 1,
            "contextAfter": ["generation": "generation-a", "run": "run-a", "usb": "connection-a"]]
        value["lastProbe"] = evidence
        XCTAssertEqual(state(value)["proof"] as? String, "success")
        value["runID"] = "run-b"
        XCTAssertEqual(state(value)["proof"] as? String, "stale")
        value["runID"] = "run-a"; value["generation"] = "generation-b"
        XCTAssertEqual(state(value)["proof"] as? String, "stale")
    }

    func testClientMissingAndUnknownAreNotClaimedConfigured() {
        for input in ["missing", "external", "unconfigured", "unknown"] {
            var value = stopped; value["clientState"] = input
            XCTAssertEqual(state(value)["client"] as? String, input)
        }
        XCTAssertEqual(state(running)["client"] as? String, "managed")
    }

    func testAStoredPreparationDoesNotCountAsLicenseProof() {
        XCTAssertEqual(state(stopped)["phase"] as? String, "stopped")
        XCTAssertEqual(state(stopped)["proof"] as? String, "none")
        XCTAssertEqual(state(stopped)["hold"] as? Bool, true)
        var first = stopped; first["prepared"] = false; first["status"] = "unprepared"
        XCTAssertEqual(state(first)["phase"] as? String, "first")
    }

    func testSafetyFailuresStaySpecificAndNeverClaimKeyReleased() {
        let cases = [("Несколько ключей", "multiple"), ("Защита прошивки неизвестна", "unsafe"), ("USB неизвестен", "unknown")]
        for (message, expected) in cases {
            var value = stopped
            value["lastFailure"] = ["action": "start", "kind": "safety", "message": message]
            XCTAssertEqual(state(value)["phase"] as? String, expected)
        }
        for (code, expected) in [("multiple-keys", "multiple"), ("firmware-unknown", "unsafe")] {
            var value = stopped; value["safetyReasonCode"] = code
            XCTAssertEqual(state(value)["phase"] as? String, expected)
        }
    }

    func testRollbackAndRestoreRefusalsAreNotSuccessfulStoppedScreen() {
        for (action, expected) in [("rollback", "rollback-error"), ("restore", "restore-error")] {
            var value = stopped
            value["lastFailure"] = ["action": action, "kind": "operation", "message": "unavailable"]
            XCTAssertEqual(state(value)["phase"] as? String, expected)
        }
    }

    func testVersionTextUsesSelectedManifestNotAnExampleOrMacClientVersion() {
        var value = running; value["platformVersion"] = "8.3.mac-only"
        XCTAssertEqual(AppPresentation.snapshot(status: value)["componentLabel"] as? String, "1С 8.5.9 · драйвер HASP 10.40")
        value.removeValue(forKey: "currentVersion"); value.removeValue(forKey: "runtimeVersion")
        let label = AppPresentation.snapshot(status: value)["componentLabel"] as? String
        XCTAssertEqual(label, "1С: версия не определена · драйвер HASP: версия не определена")
        XCTAssertFalse(label?.contains("8.3.mac-only") ?? true)
    }

    func testUnknownResourcesAndKnownEmptyPreviousAreDifferent() {
        XCTAssertEqual(rows(stopped)["Предыдущая установка"], "Нет измерения")
        var value = stopped
        value["resources"] = ["sampledAt": 1_790_000_000.0, "context": ["ownership": "absent"], "generations": [[String: Any]]()]
        XCTAssertEqual(rows(value)["Предыдущая установка"], "0 МиБ")
        XCTAssertEqual(rows(value)["Занято внутри Linux"], "Нет измерения")
        XCTAssertEqual(rows(value)["Память процесса на Mac"], "Нет измерения")
        XCTAssertEqual(rows(value)["Виртуальная ёмкость диска"], "Нет измерения")
    }

    func testPhysicalCompositionDoesNotConfuseVirtualCapacityOrRetainedDisks() {
        var value = running; value["resources"] = resourceSample
        let output = rows(value)
        XCTAssertEqual(output["Всего занято на Mac"], "800 МиБ")
        XCTAssertEqual(output["Текущая установка"], "240 МиБ")
        XCTAssertEqual(output["Предыдущая установка"], "220 МиБ")
        XCTAssertEqual(output["Другие сохранённые установки"], "210 МиБ")
        XCTAssertEqual(output["Незавершённые установки"], "36 МиБ")
        XCTAssertEqual(output["Виртуальная ёмкость диска"], "5 ГиБ")
        XCTAssertEqual(output["Память для работы с ключом"], "128 МиБ · 1 vCPU")
        XCTAssertEqual(output["Занято внутри Linux"], "74 МиБ")
        XCTAssertEqual(output["Память процесса на Mac"], "234 МиБ")
    }

    func testResourceSampleBecomesHistoricalAfterContextChangeAndOffline() {
        for patch: [String: Any] in [["generation": "generation-b"], ["runID": "run-b"], ["ownership": "absent"], ["stale": true]] {
            var value = running; value["resources"] = resourceSample; value.merge(patch) { _, new in new }
            XCTAssertEqual(rows(value)["Занято внутри Linux"], "Ранее: 74 МиБ")
            XCTAssertTrue(rows(value)["Время замера"]?.hasSuffix("исторический") == true)
        }
    }

    func testIncompleteDiskMeasurementDoesNotTurnIntoZeroOrCompleteTotal() {
        var sample = resourceSample
        sample["base"] = ["available": false, "allocatedBytes": 0]
        sample["generations"] = [["role": "previous", "available": false, "allocatedBytes": 0]]
        var value = running; value["resources"] = sample
        XCTAssertEqual(rows(value)["Всего занято на Mac"], "Нет измерения")
        XCTAssertEqual(rows(value)["Основа Alpine"], "Нет измерения")
        XCTAssertEqual(rows(value)["Предыдущая установка"], "Нет измерения")
    }

    func testObservationContextIgnoresPollingTimeButChangesWithKeyAndClient() {
        let first = state(running)["contextVersion"] as? String
        var poll = running; poll["updated"] = 12.0; poll["updatedAt"] = "another timestamp"; poll["busy"] = true
        XCTAssertEqual(state(poll)["contextVersion"] as? String, first)
        poll["keyConnection"] = "another physical connection"
        XCTAssertNotEqual(state(poll)["contextVersion"] as? String, first)
        poll = running; poll["clientRevision"] = "new configuration"
        XCTAssertNotEqual(state(poll)["contextVersion"] as? String, first)
    }

    func testProductErrorNeverEchoesRawPathsOrUnknownTechnicalDiagnostics() {
        let raw = "fatal at /Users/private/secrets/installer.run: exec_error code=123"
        let message = AppPresentation.failureMessage(action: "prepare", raw: raw)
        XCTAssertFalse(message.contains("/Users"))
        XCTAssertFalse(message.contains("exec_error"))
        XCTAssertTrue(message.contains("Повторите") || message.contains("повторите"))
    }

    func testSuccessfulRefreshExplicitlyClearsPreviousErrorAndAuthorizationFailure() {
        var value = stopped
        value["lastFailure"] = ["action": "configure", "kind": "operation", "message": "user canceled (-128)"]
        XCTAssertEqual(state(value)["accessError"] as? String, "configuring")
        XCTAssertFalse((state(value)["errorMessage"] as? String ?? "").isEmpty)
        value["lastFailure"] = NSNull(); value["lastError"] = ""
        XCTAssertEqual(state(value)["errorMessage"] as? String, "")
        XCTAssertTrue(state(value)["accessError"] is NSNull)
    }

    func testImportFailuresTellWhichFileToReplaceAndDoNotRequireExactVersion() {
        let installer = AppPresentation.failureMessage(action: "installer", raw: "unreadable")
        XCTAssertTrue(installer.contains("полную поставку для Linux x86-64"))
        XCTAssertTrue(installer.contains("выберите файл заново"))
        let manager = AppPresentation.failureMessage(action: "installer", raw: "lic_manager absent")
        XCTAssertTrue(manager.contains("не содержит нужный менеджер лицензий"))
        XCTAssertTrue(manager.contains("Выберите другой установщик"))
        XCTAssertFalse(manager.contains("полную поставку"))
        let driver = AppPresentation.failureMessage(action: "driver", raw: "unreadable")
        XCTAssertTrue(driver.contains("aksusbd для Linux amd64"))
        XCTAssertFalse(driver.contains("10.33"))
        XCTAssertFalse(installer.contains("8.5.4.1878"))
    }

    func testConfirmedManagerCompositionFailureRequiresAnotherInstallerAndClearsAfterRefresh() {
        for (raw, issue) in [
            ("KEYBRIDGE_ERROR=missing_license_manager", "missing-license-manager"),
            ("В установщике 1С отсутствует компонент lic_manager. Подробности в локальном журнале: /private/test", "missing-license-manager"),
            ("KEYBRIDGE_ERROR=ambiguous_license_manager", "ambiguous-license-manager"),
            ("После установки найдено несколько менеджеров лицензий", "ambiguous-license-manager")
        ] {
            var value = stopped
            value["lastFailure"] = ["action": "prepare", "kind": "operation", "message": raw]
            let projected = state(value)
            XCTAssertEqual(projected["phase"] as? String, "install-error")
            XCTAssertEqual(projected["installerIssue"] as? String, issue)
            let message = projected["errorMessage"] as? String ?? ""
            XCTAssertTrue(message.contains("Выберите другой установщик 1С"))
            XCTAssertFalse(message.contains("полную поставку"))
            XCTAssertFalse(message.contains("Повторите"))
            XCTAssertFalse(message.contains("/private"))
            value["lastFailure"] = NSNull()
            XCTAssertEqual(state(value)["installerIssue"] as? String, "")
        }
    }

    func testRuntimeErrorsAndCancellationDoNotInventMissingInstallerComponents() {
        for action in ["prepare", "start", "probe"] {
            XCTAssertEqual(AppPresentation.installerIssue(action: action, raw: "lic_manager failed to open port"), "")
        }
        XCTAssertEqual(AppPresentation.installerIssue(action: "start", raw: "missing_license_manager"), "")
        var value = stopped
        value["lastFailure"] = ["action": "prepare", "kind": "cancelled", "message": "missing_license_manager"]
        XCTAssertEqual(state(value)["installerIssue"] as? String, "")
    }

    func testNewInstallerSelectionHidesOnlyItsHistoricalFailureWhileBackendStillReportsIt() throws {
        for issue in ["missing_license_manager", "ambiguous_license_manager"] {
            var observed = stopped
            observed["prepared"] = false
            observed["status"] = "error"
            observed["lastError"] = issue
            observed["lastOperation"] = "prepare"
            observed["lastFailure"] = ["action": "prepare", "kind": "operation", "message": issue]
            let progress = failedPreparation(id: "attempt-A")
            let rejectedRevision = UUID(), replacementRevision = UUID()
            let binding = try XCTUnwrap(InstallerFailureBinding(status: observed, preparation: progress,
                                                               installerRevision: rejectedRevision))
            func project(_ revision: UUID) -> [String: Any] {
                AppPresentation.snapshot(status: observed, preparation: progress, installerRevision: revision,
                                         rejectedInstaller: binding)["state"] as! [String: Any]
            }
            XCTAssertEqual(project(rejectedRevision)["phase"] as? String, "install-error")
            // Choosing a driver changes no installer revision and must not hide it.
            XCTAssertFalse((project(rejectedRevision)["installerIssue"] as? String ?? "").isEmpty)
            for _ in 0..<2 { // A subsequent periodic snapshot must not revive the error.
                let view = project(replacementRevision)
                XCTAssertEqual(view["phase"] as? String, "first")
                XCTAssertEqual(view["installerIssue"] as? String, "")
                XCTAssertEqual(view["errorMessage"] as? String, "")
            }
            XCTAssertEqual((observed["lastFailure"] as? [String: String])?["message"], issue)
            XCTAssertEqual(observed["lastError"] as? String, issue)
            XCTAssertEqual(progress.state, "failed")
            observed["lastError"] = "" // Ordinary status refreshes can clear this transient field.
            XCTAssertEqual(project(replacementRevision)["installerIssue"] as? String, "")
            XCTAssertEqual(project(replacementRevision)["phase"] as? String, "first")
            observed["prepared"] = true
            XCTAssertEqual(project(replacementRevision)["phase"] as? String, "stopped")
        }
    }

    func testNewSelectionNeverSuppressesANewAttemptOrAnUnrelatedFailure() throws {
        var observed = stopped
        observed["lastFailure"] = ["action": "prepare", "kind": "operation", "message": "missing_license_manager"]
        let progress = failedPreparation(id: "attempt-A")
        let binding = try XCTUnwrap(InstallerFailureBinding(status: observed, preparation: progress, installerRevision: UUID()))
        let newRevision = UUID()
        let newAttempt = AppPresentation.snapshot(status: observed, preparation: failedPreparation(id: "attempt-B"),
                                                 installerRevision: newRevision, rejectedInstaller: binding)["state"] as! [String: Any]
        XCTAssertEqual(newAttempt["phase"] as? String, "install-error")
        XCTAssertEqual(newAttempt["installerIssue"] as? String, "missing-license-manager")
        for (action, message) in [("prepare", "ENOSPC"), ("configure", "permission denied")] {
            observed["lastFailure"] = ["action": action, "kind": "operation", "message": message]
            let view = AppPresentation.snapshot(status: observed, preparation: progress, installerRevision: newRevision,
                                                rejectedInstaller: binding)["state"] as! [String: Any]
            XCTAssertFalse((view["errorMessage"] as? String ?? "").isEmpty)
            if action == "configure" { XCTAssertEqual(view["accessError"] as? String, "configuring") }
            else { XCTAssertEqual(view["phase"] as? String, "install-error") }
        }
    }

    private func failedPreparation(id: String) -> PreparationSnapshot {
        PreparationSnapshot(id: id, state: "failed", phase: "verify_imports", startedAt: 1,
                            phaseStartedAt: 1, updatedAt: 2, lastOutputAt: 2, finishedAt: 2, recoveryReason: nil)
    }

    func testLocalCheckFailuresExplainTheActualMissingDependency() {
        XCTAssertTrue(AppPresentation.failureMessage(action: "check-client", raw: "missing").contains("Клиент 1С для macOS не найден"))
        XCTAssertTrue(AppPresentation.failureMessage(action: "check-key", raw: "USB-ключ не обнаружен").contains("Подключите его к этому Mac"))
        XCTAssertTrue(AppPresentation.failureMessage(action: "check-space", raw: "no response").contains("Хранилище"))
        XCTAssertTrue(AppPresentation.failureMessage(action: "check-space", raw: "ENOSPC").contains("не хватает свободного места"))
    }
}
