// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import KeyBridgeCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var state: [String: Any] = [:]
    @Published private(set) var payload: [String: Any] = [:]
    var didChange: (([String: Any]) -> Void)?
    var navigate: ((String) -> Void)?
    private(set) var flow = ApplicationCommandFlow()
    private var fileURLs: [String: URL] = [:]
    private var files: [String: [String: Any]] = [:]
    private var fileRevisions: [String: UUID] = [:]
    private var preparation: PreparationSnapshot?
    private var feedback: [String: Any]?
    private var client: [String: Any] = [:]
    private var poll: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private let submissions = ApplicationSubmissionQueue()
    private var failurePhase: String?
    private var failureMessage = ""
    private var failureContext: String?
    private var updateProblem = false
    private var updateGeneration = ""
    private var clientRestored = false
    private var contextEpoch: UInt64 = 0
    private var reloadSequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0
    private var loaded = false
    private var publishedData: Data?
    let runtime = BridgePaths.runtime

    init() {
        publish()
        poll = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.reload()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    var running: Bool { state["running"] as? Bool ?? false }
    var busy: Bool { flow.active != nil || state["busy"] as? Bool == true }
    var prepared: Bool { state["prepared"] as? Bool ?? false }
    var title: String {
        let phase = (payload["state"] as? [String: Any])?["phase"] as? String ?? "loading"
        switch phase {
        case "ready": return "KeyBridge работает"
        case "stopped": return "KeyBridge выключен"
        case "first": return "Нужно установить программы для ключа"
        case "waiting": return "USB-ключ не обнаружен"
        case "preparing": return "Устанавливаем программы для ключа"
        case "starting": return "Включаем KeyBridge"
        case "stopping": return "Выключаем KeyBridge"
        case "probing": return "Проверяем лицензию в 1С"
        case "recovering": return "Восстанавливаем работу"
        case "loading", "reconciling": return "Проверяем состояние KeyBridge"
        default: return "KeyBridge требует внимания"
        }
    }

    func receive(_ request: [String: Any]) {
        guard let action = request["action"] as? String,
              let id = request["id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return }
        switch action {
        case "hide": NSApp.keyWindow?.orderOut(nil)
        case "open-url":
            if let text = request["value"] as? String, let url = URL(string: text) { openExternal(url) }
        case "installer", "driver": chooseFile(kind: action, id: id)
        case "quit": requestQuit(id: id)
        default: command(action, id: id, value: request["value"])
        }
    }

    func openExternal(_ url: URL) {
        let allowedHosts = ["releases.1c.ru", "portal.1c.ru", "supportportal.thalesgroup.com"]
        let allowed = url.scheme == "https" && allowedHosts.contains(url.host?.lowercased() ?? "")
        let company = url.absoluteString == "https://ingvar.pro/?utm_source=keybridge&utm_medium=app&utm_campaign=settings"
        let settings = url.absoluteString == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            || url.absoluteString == "x-apple.systempreferences:com.apple.settings.Storage"
        guard allowed || company || settings else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshClient() async {
        if let value = try? await Self.execute(["client-status"]) { client = value }
    }
    private func reload() async {
        reloadSequence &+= 1
        let sequence = reloadSequence
        let runtime = self.runtime
        let observation = await Task.detached(priority: .utility) { () -> ([String: Any], PreparationSnapshot?) in
            let snapshot: [String: Any]
            if let live = try? AgentIPC.exchange(runtime: runtime, message: ["ipc": "status"]), !live.isEmpty {
                snapshot = live
            } else {
                var previous = readObject(runtime.appendingPathComponent("status.json"))
                let manifest = readObject(runtime.appendingPathComponent("current.json"))
                if !previous.isEmpty || !manifest.isEmpty {
                    previous["stale"] = true
                    previous["prepared"] = previous["prepared"] ?? !manifest.isEmpty
                } else {
                    previous = ["status": "unprepared", "prepared": false, "running": false,
                                "ownership": "absent", "busy": false]
                    previous.merge(RuntimeOwnership.observation(runtime: runtime), uniquingKeysWith: { _, observed in observed })
                }
                let intent = readObject(runtime.appendingPathComponent("intent.json"))
                previous["autostart"] = intent["autostart"] ?? false
                previous["autoInhibit"] = intent["autoInhibit"] ?? false
                previous["desiredRunning"] = intent["want"] ?? false
                snapshot = previous
            }
            let progress = (try? Data(contentsOf: runtime.appendingPathComponent("preparation.json")))
                .flatMap { try? JSONDecoder().decode(PreparationSnapshot.self, from: $0) }
            return (snapshot, progress)
        }.value
        await refreshClient()
        guard !Task.isCancelled, sequence >= appliedSequence else { return }
        appliedSequence = sequence
        state = observation.0
        preparation = observation.1
        if let failureContext, failureContext != observationContext {
            failurePhase = nil; failureMessage = ""; self.failureContext = nil
        }
        loaded = true
        publish()
    }

    private func publish() {
        var observed = state
        observed["loginLaunchSupported"] = BridgePaths.loginLaunchSupported
        // The live agent knows current client state. On cold start the helper's
        // read-only inspection supplies it without launching the licensing VM.
        for (key, value) in client { observed[key] = value }
        if flow.active == nil, let failurePhase { observed["uiFailurePhase"] = failurePhase }
        var result = AppPresentation.snapshot(status: observed, preparation: preparation)
        var view = result["state"] as? [String: Any] ?? [:]
        view["fault"] = NSNull()
        if !loaded { view["phase"] = "loading" }
        if let active = flow.active {
            let phases = ["prepare": "preparing", "start": "starting", "stop": "stopping", "probe": "probing",
                          "configure": "configuring", "repair": "configuring", "restore": "restoring", "rollback": "restoring-version"]
            if let phase = phases[active.action] { view["phase"] = phase }
            view["operationPending"] = true
        } else if let failurePhase {
            if !["unknown", "unsafe", "multiple", "paused"].contains(view["phase"] as? String ?? "") { view["phase"] = failurePhase }
            view["errorMessage"] = failureMessage
            if failurePhase == "first" { view["fault"] = "space" }
        }
        let generation = state["generation"] as? String ?? ""
        if !generation.isEmpty && generation != updateGeneration {
            updateGeneration = generation
            updateProblem = false
        }
        view["updateProblem"] = updateProblem || (view["updateProblem"] as? Bool == true)
        view["pendingQuit"] = flow.quitRequested
        view["clientRestored"] = clientRestored
        view["contextVersion"] = String(describing: view["contextVersion"] ?? "") + ":\(contextEpoch)"
        result["state"] = view
        result["files"] = files
        if let feedback { result["feedback"] = feedback }
        let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard data != publishedData else { return }
        publishedData = data
        payload = result
        didChange?(result)
    }

    private var observationContext: String {
        let observed = state.merging(client, uniquingKeysWith: { _, fresh in fresh })
        let view = AppPresentation.snapshot(status: observed)["state"] as? [String: Any] ?? [:]
        return view["contextVersion"] as? String ?? ""
    }

    private func chooseFile(kind: String, id: String) {
        guard !busy, !running else { return }
        let panel = NSOpenPanel()
        panel.title = kind == "driver" ? "Выберите драйвер USB-ключа" : "Выберите установщик 1С"
        panel.message = kind == "driver" ? "Нужен пакет aksusbd для Linux amd64 (.deb)." : "Нужна полная поставка 1С для Linux x86-64 (.run), включающая менеджер лицензий."
        panel.prompt = "Выбрать"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: kind == "driver" ? "deb" : "run") ?? .data]
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.feedback = ["id": id, "action": kind, "ok": false, "cancelled": true, "message": ""]
                self.publish(); return
            }
            let revision = UUID()
            self.fileRevisions[kind] = revision
            self.fileURLs[kind] = url
            self.files[kind] = ["name": url.lastPathComponent, "valid": false, "checking": true]
            self.failurePhase = nil
            self.publish()
            Task {
                do {
                    let inspected = try await Self.execute(["inspect-import", "--kind", kind, "--path", url.path])
                    guard self.fileRevisions[kind] == revision else { return }
                    var file = inspected
                    file["name"] = url.lastPathComponent
                    file["checking"] = false
                    file["valid"] = inspected["valid"] as? Bool ?? inspected["ok"] as? Bool ?? true
                    self.files[kind] = file
                    self.feedback = ["id": id, "action": kind, "ok": file["valid"] as? Bool == true, "message": inspected["message"] ?? ""]
                } catch {
                    guard self.fileRevisions[kind] == revision else { return }
                    let message = AppPresentation.failureMessage(action: kind, raw: error.localizedDescription)
                    self.files[kind] = ["name": url.lastPathComponent, "valid": false, "checking": false, "error": message]
                    self.feedback = ["id": id, "action": kind, "ok": false, "message": message]
                }
                self.publish()
            }
        }
    }

    func requestQuit(id: String = UUID().uuidString) {
        flow.requestQuit()
        AppDelegate.shared?.showWindow()
        if flow.active?.action == "stop" { publish(); return }
        command("stop", id: id)
    }

    func command(_ action: String, id: String = UUID().uuidString, value: Any? = nil) {
        let mapping = ["check-key": "refresh-key", "recheck": "refresh-state", "check-permission": "refresh-state", "measure": "resources"]
        let allowed = ["prepare", "start", "stop", "probe", "configure", "repair", "restore", "rollback", "monitor", "autostart", "check-key", "check-client", "check-space", "recheck", "check-permission", "measure"]
        guard allowed.contains(action) else { return }
        if !BridgePaths.loginLaunchSupported && ((action == "autostart" && value as? Bool == true) || action == "check-permission") {
            feedback = ["id": id, "action": action, "ok": false, "message": ApplicationCapabilities.autostartUnavailableMessage]
            publish(); return
        }
        guard let ticket = flow.begin(id: id, action: action) else {
            feedback = ["id": id, "action": action, "ok": false, "message": "Дождитесь завершения текущего действия. Выключение доступно сразу."]
            publish(); return
        }
        operation?.cancel()
        failurePhase = nil
        failureMessage = ""
        failureContext = nil
        feedback = nil
        if ["start", "stop", "prepare", "rollback", "configure", "repair", "restore"].contains(action) { contextEpoch &+= 1 }
        var arguments = [mapping[action] ?? action]
        if action == "autostart" {
            guard let enabled = value as? Bool else {
                _ = flow.finish(ticket, succeeded: false, stopped: false, stopSaved: false); publish(); return
            }
            arguments.append(enabled ? "on" : "off")
        }
        if action == "prepare" || action == "check-space" {
            if let installer = fileURLs["installer"], let driver = fileURLs["driver"] {
                arguments += ["--installer", installer.path, "--driver", driver.path]
            }
            if action == "prepare", files["installer"]?["valid"] as? Bool != true || files["driver"]?["valid"] as? Bool != true {
                _ = flow.finish(ticket, succeeded: false, stopped: false, stopSaved: false)
                feedback = ["id": id, "action": action, "ok": false, "message": "Выберите подходящие установщик 1С и драйвер USB-ключа."]
                publish(); return
            }
        }
        if action == "check-client" { arguments = ["client-status"] }
        publish()
        let submitted = submissions.enqueue { try await Self.execute(arguments) }
        operation = Task {
            var succeeded = false
            var message = ""
            do {
                let receipt = try await submitted.value
                guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                if action == "check-client" { client = receipt }
                if receipt["accepted"] as? Bool == true {
                    guard let requestID = receipt["requestID"] as? String, UUID(uuidString: requestID) != nil else {
                        throw BridgeError("Агент не подтвердил запрос.")
                    }
                    let completion = try await waitForCompletion(requestID, timeout: action == "prepare" ? 3600 : 600)
                    guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                    if completion["ok"] as? Bool != true {
                        throw BridgeError(completion["error"] as? String ?? "Действие не завершено.")
                    }
                }
                guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                if action == "check-space", receipt["sufficient"] as? Bool == false {
                    throw BridgeError("Недостаточно места для подготовки выбранных файлов.")
                }
                if ["configure", "repair", "restore", "check-client", "recheck"].contains(action) { await refreshClient() }
                await reload()
                guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                if action == "check-client", client["clientState"] as? String == "missing" {
                    throw BridgeError("Клиент 1С для macOS не установлен.")
                }
                if action == "check-key", state["keyConnected"] as? Bool != true {
                    throw BridgeError("USB-ключ не обнаружен. Подключите его к Mac напрямую и повторите проверку.")
                }
                if action == "prepare" || action == "rollback" { updateProblem = false }
                if action == "probe", state["previousAvailable"] as? Bool == true {
                    let evaluated = AppPresentation.snapshot(status: state)["state"] as? [String: Any] ?? [:]
                    updateProblem = evaluated["proof"] as? String != "success"
                }
                if action == "restore" { clientRestored = true }
                if action == "configure" || action == "repair" { clientRestored = false }
                succeeded = true
            } catch {
                guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                await reload()
                guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                message = AppPresentation.failureMessage(action: action, raw: error.localizedDescription)
                failureMessage = message
                failureContext = observationContext
                switch action {
                case "prepare": failurePhase = message.localizedCaseInsensitiveContains("мест") ? "first" : "install-error"
                case "check-space": if message.localizedCaseInsensitiveContains("мест") { failurePhase = "first" }
                case "start": failurePhase = state["ownership"] as? String == "unknown" ? "unknown" : "start-error"
                case "rollback": failurePhase = "rollback-error"
                case "restore": failurePhase = "restore-error"
                default: break
                }
                if action == "start", state["previousAvailable"] as? Bool == true { updateProblem = true }
            }
            guard flow.isCurrent(ticket), !Task.isCancelled else { return }
            feedback = ["id": id, "action": action, "ok": succeeded, "message": message]
            let stopped = state["ownership"] as? String == "absent" && state["running"] as? Bool != true && state["stale"] as? Bool != true
            let saved = state["stopSaved"] as? Bool ?? (state["desiredRunning"] as? Bool == false && state["autoInhibit"] as? Bool == true && state["persistenceError"] == nil)
            let shouldQuit = flow.finish(ticket, succeeded: succeeded, stopped: stopped, stopSaved: saved)
            publish()
            if shouldQuit { AppDelegate.shared?.finishQuit() }
        }
    }

    private func waitForCompletion(_ id: String, timeout: TimeInterval) async throws -> [String: Any] {
        let runtime = self.runtime
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let result = await Task.detached(priority: .utility) { () -> [String: Any] in
                if let live = try? AgentIPC.exchange(runtime: runtime, message: ["ipc": "result", "requestID": id]), !live.isEmpty { return live }
                return readObject(runtime.appendingPathComponent("results").appendingPathComponent(id + ".json"))
            }.value
            if !result.isEmpty { return result }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw BridgeError("Не получен результат действия. Проверьте состояние KeyBridge и повторите действие.")
    }

    nonisolated private static func execute(_ arguments: [String]) async throws -> [String: Any] {
        try await Task.detached(priority: .userInitiated) {
            let executable = BridgePaths.executableDirectory.appendingPathComponent("KeyBridgeControl")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw BridgeError("Не найден управляющий компонент. Установите полную сборку KeyBridge.")
            }
            let result = try hostCommand(executable.path, arguments, timeout: 120)
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let object = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if result.code != 0 || result.timedOut || object?["ok"] as? Bool == false {
                throw BridgeError(object?["error"] as? String ?? (text.isEmpty ? "Действие не завершено." : text))
            }
            if arguments.first == "monitor", text == "OK" { return ["ok": true] }
            guard let object else { throw BridgeError("Управляющий компонент не вернул результат.") }
            return object
        }.value
    }
}
