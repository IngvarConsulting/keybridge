// SPDX-License-Identifier: MIT
import Foundation

/// Presentation only: this projection neither starts work nor fills missing
/// observations with a successful example from the interface prototype.
public enum AppPresentation {
    public static func snapshot(status: [String: Any], preparation: PreparationSnapshot? = nil) -> [String: Any] {
        let prepared = bool(status, "prepared")
        let running = bool(status, "running")
        let stale = bool(status, "stale")
        let ownership = string(status, "ownership")
        let operation = string(status, "operation")
        let lastFailure = status["lastFailure"] as? [String: Any] ?? [:]
        let failureAction = string(lastFailure, "action")
        let failureKind = string(lastFailure, "kind")
        let failureText = string(lastFailure, "message", fallback: string(status, "lastError"))
        let previous = bool(status, "previousAvailable")
        let client = clientState(status)
        let connected = bool(status, "keyConnected")
        let phase = phase(status, preparation: preparation)
        let proof = proof(status, phase: phase, client: client)
        let saved = status["stopSaved"] as? Bool
            ?? (string(status, "stopPersistenceError").isEmpty &&
                !(string(status, "lastOperation") == "stop" && !string(status, "persistenceError").isEmpty))
        let updateProblem = status["updateProblem"] as? Bool
            ?? (previous && (["failure", "unconfirmed", "timeout"].contains(proof) ||
                (["start", "reconcile", "health"].contains(failureAction) && !failureText.isEmpty)))
        var state: [String: Any] = [
            "phase": phase, "prepared": prepared, "client": client,
            "key": connected && !stale, "want": bool(status, "desiredRunning"),
            "hold": bool(status, "autoInhibit"), "auto": bool(status, "autostart"),
            "permission": ["allowed", "denied"].contains(string(status, "loginAccess")) ? string(status, "loginAccess") : "unknown",
            "proof": proof, "saved": saved, "selected": "current",
            "step": preparationStep(preparation?.phase ?? string(status, "phase")),
            "updated": status["updatedInstallation"] as? Bool ?? previous,
            "previousAvailable": previous, "previousValid": bool(status, "previousValid"),
            "updateProblem": updateProblem, "backupAvailable": bool(status, "backupAvailable"),
            "backupState": string(status, "backupState", fallback: "unknown"),
            "pendingQuit": false, "sessionActive": status["sessionActive"] as? Bool ?? true,
            "contextVersion": contextKey(status), "ownership": ownership,
            "running": running && !stale, "stale": stale,
            "busy": bool(status, "busy"), "operation": operation,
            "safetyBlock": stale || ownership == "unknown" ? "unknown" : NSNull(),
            "errorMessage": "", "accessError": NSNull()
        ]
        // The raw diagnostic string is never placed in the product UI.
        if !failureText.isEmpty, failureKind != "cancelled" {
            state["errorMessage"] = failureMessage(action: failureAction.isEmpty ? operation : failureAction, raw: failureText)
            if ["configure", "repair"].contains(failureAction), !bool(status, "busy") {
                state["accessError"] = "configuring"
            }
        }
        if bool(status, "clientRestored") { state["clientRestored"] = true }
        let probe = status["lastProbe"] as? [String: Any] ?? [:]
        return ["state": state,
                "keyLabel": stale ? "Нет актуальных данных" : string(status, "keyModel", fallback: connected ? "USB-ключ HASP" : "Не подтверждён"),
                "componentLabel": componentLabel(status),
                "proofTime": dateText(probe["timestamp"]),
                "resourceRows": resourceRows(status)]
    }

    /// Classifies a failed real operation without exposing paths, stderr or
    /// claiming a specific cause when the backend did not establish it.
    public static func failureMessage(action: String, raw: String) -> String {
        let text = raw.lowercased()
        if text.contains("no space") || text.contains("enospc") || text.contains("не хватает места") || text.contains("недостаточно места") {
            return "На Mac не хватает свободного места. Освободите место и повторите действие."
        }
        if text.contains("-128") || text.contains("user canceled") || text.contains("user cancelled") || text.contains("отменено пользователем") {
            return "Разрешение macOS не получено: запрос был отменён. Повторите действие и разрешите изменение."
        }
        if text.contains("permission denied") || text.contains("operation not permitted") || text.contains("доступ запрещ") {
            return "macOS не разрешила доступ к нужным файлам. Проверьте права доступа и повторите действие."
        }
        if action == "restore", text.contains("копи") || text.contains("backup") {
            return "Не удалось прочитать сохранённые настройки 1С. Восстановите их копию из резервной копии Mac и повторите возврат."
        }
        if ["configure", "repair", "restore"].contains(action), text.contains("изменен") || text.contains("изменён") || text.contains("external") {
            return "Настройки 1С изменились после подключения KeyBridge. Вернитесь к настройке поиска лицензии и выберите «Исправить настройки»."
        }
        if ["prepare", "installer"].contains(action), text.contains("lic_manager") || text.contains("менеджер лицензий отсутств") {
            return "В выбранном установщике не найден менеджер лицензий. Выберите полную поставку 1С для Linux x86-64."
        }
        if action == "driver", text.contains("другой пакет") || text.contains("package") && text.contains("aksusbd") {
            return "Выбран другой пакет. Скачайте драйвер aksusbd для Linux amd64 и выберите его файл DEB."
        }
        if ["installer", "driver"].contains(action), text.contains("поврежд") || text.contains("не полностью") || text.contains("метаданн") {
            return action == "driver"
                ? "Не удалось прочитать содержимое драйвера: структура файла не распознана. Скачайте пакет aksusbd для amd64 заново и выберите его."
                : "Не удалось прочитать установщик 1С: структура файла не распознана. Скачайте полную поставку для Linux x86-64 заново и выберите её."
        }
        if ["prepare", "installer", "driver"].contains(action), text.contains("amd64") || text.contains("архитектур") || text.contains("x86-64") {
            if action == "driver" { return "Формат или архитектура драйвера не подходят. Выберите DEB-пакет aksusbd для Linux amd64." }
            if action == "installer" { return "Формат или архитектура установщика не подходят. Выберите полную поставку 1С для Linux x86-64 в файле .run." }
            return "Формат или архитектура выбранного файла не подходят. Проверьте установщик для Linux x86-64 и драйвер amd64."
        }
        if action == "check-client", text.contains("не найден") || text.contains("не установлен") || text.contains("missing") {
            return "Клиент 1С для macOS не найден. Установите его и нажмите «Проверить наличие 1С»."
        }
        if action == "check-key", text.contains("не обнаружен") || text.contains("не найден") || text.contains("ключ отсутствует") {
            return "USB-ключ HASP не обнаружен. Подключите его к этому Mac и повторите проверку подключения."
        }
        switch action {
        case "installer": return "Не удалось прочитать или проверить установщик 1С. Причина пока неизвестна. Скачайте полную поставку для Linux x86-64 и выберите файл заново."
        case "driver": return "Не удалось прочитать или проверить драйвер HASP. Причина пока неизвестна. Скачайте пакет aksusbd для Linux amd64 и выберите файл DEB заново."
        case "check-client": return "Не удалось проверить клиент 1С для macOS. Причина пока неизвестна. Проверьте, что 1С установлена, и повторите проверку наличия."
        case "check-key": return "Не удалось проверить подключение USB-ключа. Причина пока неизвестна. Переподключите ключ к Mac и повторите проверку подключения."
        case "check-space": return "Не удалось проверить свободное место на Mac. Причина пока неизвестна. Откройте раздел «Хранилище» в настройках macOS и повторите проверку."
        case "prepare": return "Установить выбранные программы не удалось. Причину пока определить нельзя. Проверьте файлы и повторите установку."
        case "rollback": return "Предыдущую установку не удалось прочитать или проверить. Текущая установка сохранена; восстановите предыдущую из резервной копии или переустановите программы."
        case "restore": return "Вернуть прежние настройки 1С не удалось. Причина пока неизвестна. Повторите возврат; при повторном отказе восстановите сохранённую копию настроек."
        case "configure", "repair": return "Настроить поиск лицензии не удалось. Причина пока неизвестна. Повторите действие и разрешите изменение в запросе macOS."
        case "autostart": return "Сохранить автозапуск не удалось. Причина записи неизвестна. Повторите сохранение или отмените изменение."
        case "monitor": return "1С не подтвердила открытие монитора лицензий. Повторите открытие или посмотрите лицензию в своей базе 1С."
        case "probe": return "Проверка в 1С не завершилась успешно. Причина пока неизвестна. Проверьте подключение и повторите проверку."
        case "resources", "measure": return "Получить новый замер не удалось. Причина пока неизвестна. Повторите измерение; прежние значения не подтверждают текущее потребление."
        case "stop", "shutdown": return "Завершение выключения не подтверждено. Причина пока неизвестна. Проверьте состояние или повторите выключение."
        default: return "KeyBridge не получил ожидаемый ответ. Причина пока неизвестна. Проверьте состояние и повторите действие."
        }
    }

    private static func phase(_ status: [String: Any], preparation: PreparationSnapshot?) -> String {
        guard !status.isEmpty else { return "loading" }
        if bool(status, "stale") { return "unknown" }
        let operation = string(status, "operation")
        let raw = string(status, "status")
        let ownership = string(status, "ownership")
        let running = bool(status, "running")
        let busy = bool(status, "busy")
        if busy {
            switch operation {
            case "prepare": return "preparing"
            case "rollback": return "restoring-version"
            case "stop", "shutdown", "session-stop": return "stopping"
            case "start": return "starting"
            case "probe": return "probing"
            case "configure", "repair": return "configuring"
            case "restore": return "restoring"
            default: break
            }
        }
        // Unknown ownership outranks a stale engine phase or a saved stop.
        if !["owned", "absent"].contains(ownership) { return "unknown" }
        if status["sessionActive"] as? Bool == false { return "paused" }
        if bool(status, "reconciling") { return "reconciling" }
        if busy && ["reconcile", "health", "refresh-key"].contains(operation),
           !(ownership == "owned" && running && ["running", "waiting-key"].contains(raw)) { return "reconciling" }
        if busy && ["preparing", "starting", "stopping", "probing", "recovering"].contains(raw) { return raw }
        let failure = status["lastFailure"] as? [String: Any] ?? [:]
        let action = string(failure, "action")
        let kind = string(failure, "kind")
        let message = string(failure, "message", fallback: string(status, "lastError")).lowercased()
        let safetyCode = string(status, "safetyReasonCode").replacingOccurrences(of: "-", with: "_")
        if kind == "safety" || !safetyCode.isEmpty {
            if safetyCode == "multiple_keys" || message.contains("несколько") { return "multiple" }
            if ["firmware_guard", "firmware_unknown"].contains(safetyCode) || message.contains("прошив") { return "unsafe" }
            // A generic safety failure may concern ownership or USB release;
            // it cannot be represented as a confirmed stopped state.
            return "unknown"
        }
        if running && ownership == "owned" {
            if raw == "waiting-key" && status["keyConnected"] as? Bool == false { return "waiting" }
            if raw == "running" && bool(status, "keyConnected") { return "ready" }
            return "unknown"
        }
        if ownership == "owned" { return "unknown" }
        if action == "rollback" && kind != "cancelled" { return "rollback-error" }
        if action == "restore" && kind != "cancelled" { return "restore-error" }
        if action == "prepare" && kind != "cancelled" { return "install-error" }
        if raw == "error" && preparation?.state == "failed" && !["start", "probe", "stop"].contains(string(status, "lastOperation")) { return "install-error" }
        if ["start", "reconcile", "health", "refresh-key"].contains(action), kind != "cancelled" {
            if integer(status["remainingAttempts"]) == 0 && bool(status, "autoInhibit") { return "exhausted" }
            return "start-error"
        }
        if !bool(status, "prepared") { return "first" }
        guard ownership == "absent" else { return "unknown" }
        return "stopped"
    }

    private static func proof(_ status: [String: Any], phase: String, client: String) -> String {
        guard let probe = status["lastProbe"] as? [String: Any], !probe.isEmpty else { return "none" }
        let result = string(probe, "result")
        if bool(status, "stale") || bool(probe, "historical") || probe["current"] as? Bool == false { return "stale" }
        if result == "unknown" || result == "stale" { return "stale" }
        if !["ready", "probing"].contains(phase) || client != "managed" { return "stale" }
        if let context = probe["contextAfter"] as? [String: Any] {
            for (probeName, stateName) in [("generation", "generation"), ("run", "runID")] {
                let expected = string(status, stateName)
                if !expected.isEmpty && string(context, probeName) != expected { return "stale" }
            }
        }
        if ["success", "licensed"].contains(result) {
            // A boolean or observed aggregate issuance alone is not the agreed
            // causal license proof. Existing backend intentionally cannot yet
            // satisfy this branch (the documented G06 gap).
            let context = probe["contextAfter"] as? [String: Any] ?? [:]
            let connection = string(status, "keyConnection")
            let boundToRun = !string(status, "generation").isEmpty && !string(status, "runID").isEmpty && !connection.isEmpty &&
                string(context, "generation") == string(status, "generation") && string(context, "run") == string(status, "runID") &&
                string(context, "usb") == connection
            let confirmed = boundToRun && bool(probe, "success") && bool(probe, "clientOperationSucceeded") &&
                bool(probe, "journalContinuous") && bool(probe, "contextStable") &&
                bool(probe, "causalIsolation") && (integer(probe["managerIssuanceDelta"]) ?? 0) > 0 &&
                (integer(probe["hardwareLocalDelta"]) ?? 0) > 0
            return confirmed ? "success" : "unconfirmed"
        }
        if ["timeout", "timedOut"].contains(result) || bool(probe, "timedOut") { return "timeout" }
        if ["failure", "failed", "error"].contains(result) { return "failure" }
        return result == "unconfirmed" ? "unconfirmed" : "none"
    }

    private static func clientState(_ status: [String: Any]) -> String {
        switch string(status, "clientState") {
        case "configured", "managed": return "managed"
        case "missing": return "missing"
        case "external": return "external"
        case "unconfigured": return "unconfigured"
        default: return "unknown"
        }
    }

    private static func contextKey(_ status: [String: Any]) -> String {
        var context = [String: Any]()
        for key in ["generation", "runID", "ownership", "keyConnected", "keyConnection", "usbEpoch", "clientState", "clientRevision", "sessionActive", "stale"] {
            context[key] = status[key] ?? NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]),
              let key = String(data: data, encoding: .utf8) else { return "unknown" }
        return key
    }

    private static func componentLabel(_ status: [String: Any]) -> String {
        guard bool(status, "prepared") else { return "Ещё не установлены" }
        let current = string(status, "currentVersion")
        let driver = string(status, "runtimeVersion")
        return (current.isEmpty ? "1С: версия не определена" : "1С " + current) + " · " +
            (driver.isEmpty ? "драйвер HASP: версия не определена" : "драйвер HASP " + driver)
    }

    private static func resourceRows(_ status: [String: Any]) -> [[String: String]] {
        let resources = status["resources"] as? [String: Any] ?? [:]
        let historical = resourceHistorical(resources, status: status)
        let prefix = historical ? "Ранее: " : ""
        func value(_ bytes: Int64?) -> String { bytes.map { prefix + byteText($0) } ?? "Нет измерения" }
        func allocated(_ object: Any?) -> Int64? {
            guard let object = object as? [String: Any], object["available"] as? Bool == true else { return nil }
            return integer(object["allocatedBytes"])
        }
        let base = allocated(resources["base"])
        let runtime = allocated(resources["runtime"])
        let total: Int64? = base.flatMap { b in runtime.flatMap { r in
            let sum = b.addingReportingOverflow(r); return sum.overflow ? nil : sum.partialValue
        } }
        func generationBytes(_ role: String) -> Int64? {
            guard let generations = resources["generations"] as? [[String: Any]] else { return nil }
            var sum: Int64 = 0
            for item in generations where string(item, "role") == role {
                guard let count = allocated(item) else { return nil }
                let next = sum.addingReportingOverflow(count); guard !next.overflow else { return nil }; sum = next.partialValue
            }
            return sum
        }
        let guest = resources["guest"] as? [String: Any] ?? [:]
        let memory = integer(status["memoryMiB"])
        let cpu = integer(status["cpus"])
        let profile = memory.flatMap { m in cpu.map { c in "\(m) МиБ · \(c) vCPU" } } ?? "Нет данных"
        let time = dateText(resources["sampledAt"])
        let sampled = time.isEmpty ? "Измерение не проводилось" : time + (historical ? " · исторический" : "")
        return [("Память для работы с ключом", profile), ("Время замера", sampled),
                ("Всего занято на Mac", value(total)), ("Основа Alpine", value(base)),
                ("Текущая установка", value(generationBytes("selected"))),
                ("Предыдущая установка", value(generationBytes("previous"))),
                ("Другие сохранённые установки", value(generationBytes("retained"))),
                ("Незавершённые установки", value(generationBytes("candidate"))),
                ("Виртуальная ёмкость диска", value(integer(resources["virtualDiskBytes"]))),
                ("Занято внутри Linux", value(integer(guest["usedBytes"]))),
                ("Память процесса на Mac", value(integer(resources["qemuRSSBytes"])))].map { ["label": $0.0, "value": $0.1] }
    }

    private static func resourceHistorical(_ resources: [String: Any], status: [String: Any]) -> Bool {
        if bool(resources, "historical") || bool(status, "stale") { return true }
        guard let context = resources["context"] as? [String: Any] else { return !resources.isEmpty }
        for (sampleKey, currentKey) in [("generation", "generation"), ("run", "runID"), ("ownership", "ownership")] {
            if let sampled = context[sampleKey] as? String, sampled != string(status, currentKey) { return true }
        }
        if let identity = context["processIdentity"] as? [NSNumber],
           let current = status["processIdentity"] as? [NSNumber], identity != current { return true }
        return false
    }

    private static func preparationStep(_ phase: String) -> Int {
        switch phase {
        case "verify", "linux", "import": return 0
        case "boot", "verify_imports", "dependencies", "driver", "firmware_guard", "manager_install": return 1
        default: return 2
        }
    }

    private static func bool(_ values: [String: Any], _ name: String) -> Bool { values[name] as? Bool ?? false }
    private static func string(_ values: [String: Any], _ name: String, fallback: String = "") -> String {
        guard let value = values[name] as? String, !value.isEmpty else { return fallback }; return value
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.int64Value
        return result >= 0 ? result : nil
    }
    private static func dateText(_ value: Any?) -> String {
        let date: Date?
        if let number = value as? NSNumber, number.doubleValue > 0 { date = Date(timeIntervalSince1970: number.doubleValue) }
        else if let string = value as? String { date = ISO8601DateFormatter().date(from: string) }
        else { date = nil }
        guard let date else { return "" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    private static func byteText(_ value: Int64) -> String {
        if value == 0 { return "0 МиБ" }
        let units: [(Double, String)] = [(1_073_741_824, "ГиБ"), (1_048_576, "МиБ"), (1_024, "КиБ")]
        for (divisor, unit) in units where Double(value) >= divisor {
            let amount = Double(value) / divisor
            let formatted = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), amount)
                .replacingOccurrences(of: ".0", with: "").replacingOccurrences(of: ".", with: ",")
            return formatted + " " + unit
        }
        return "\(value) Б"
    }
}
