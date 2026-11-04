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
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var importDirectories: [String: URL] = [:]
    private var rejectedInstaller: InstallerFailureBinding?
    private var preparation: PreparationSnapshot?
    private var feedback: [String: Any]?
    private var client: [String: Any] = [:]
    private let clientObservation=ClientObservation()
    private var poll: Task<Void, Never>?
    private var operations: [String:Task<Void, Never>] = [:]
    private let submissions = ApplicationSubmissionQueue()
    private var failurePhase: String?
    private var failureMessage = ""
    private var failureInstallerIssue = ""
    private var failureContext: String?
    private var updateProblem = false
    private var updateGeneration = ""
    private var clientRestored = false
    private var contextEpoch: UInt64 = 0
    private var reloadSequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0
    private var loaded = false
    private var restoringController = false
    private var terminating = false
    private var publishedData: Data?
    let runtime = BridgePaths.runtime

    init(startPolling: Bool = true) {
        publish()
        guard startPolling else { return }
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
    private var isTemporaryCopy: Bool {
        let app = Bundle.main.bundleURL
        let readOnly = (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        return app.pathExtension == "app" && (readOnly || app.path.hasPrefix("/Volumes/") || app.path.contains("/AppTranslocation/"))
    }
    func restoreControllerIfNeeded() {
        guard validateRuntimeForLaunch() else { return }
        // A clean first launch needs no background process. After a previous
        // run, ask the current controller for a fresh observation, rather than
        // leaving the UI on a historical status after a confirmed Quit.
        guard ["current.json", "status.json"].contains(where: {
            FileManager.default.fileExists(atPath: runtime.appendingPathComponent($0).path)
        }) else { return }
        restoreController()
    }
    func resumeAtLogin() {
        guard validateRuntimeForLaunch() else { AppDelegate.shared?.showWindow(); return }
        guard LoginLaunch.isRegistered else { return }
        restoreController()
    }
    private func validateRuntimeForLaunch() -> Bool {
        do {
            try InstalledApplication.validateRuntime(runtime)
            state["runtimeDataError"] = ""
            return true
        } catch {
            state["runtimeDataError"] = error.localizedDescription
            loaded = true
            publish()
            return false
        }
    }
    private func restoreController() {
        guard !terminating, !restoringController else { return }
        restoringController = true
        publish()
        // Reserve submission order now: a later Quit/session end must wait for
        // this receipt and cannot be overtaken by a delayed controller launch.
        let submitted = submissions.enqueue { try await Self.execute(["ensure-agent"]) }
        Task {
            defer { restoringController = false; publish() }
            do {
                // Starting the controller is not a request to start the VM.
                // The controller reconciles the saved login choice and stop.
                _ = try await submitted.value
                guard !terminating else { return }
                await reload()
            } catch {
                guard !terminating else { return }
                await reload()
                failurePhase = "unknown"
                failureMessage = AppPresentation.failureMessage(action: "autostart", raw: error.localizedDescription)
                failureContext = observationContext
                publish()
            }
        }
    }
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
        guard !terminating, let action = request["action"] as? String,
              let id = request["id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return }
        switch action {
        case "open-url":
            if let text = request["value"] as? String, let url = URL(string: text) { openExternal(url) }
        case "installer", "driver": chooseFile(kind: action, id: id)
        case "cancel-installer", "cancel-driver":
            let kind = action == "cancel-installer" ? "installer" : "driver"
            cancelImport(kind: kind)
            feedback = ["id": id, "action": action, "ok": true, "message": ""]
            publish()
        case "quit": requestQuit(id: id)
        default: command(action, id: id, value: request["value"])
        }
    }

    func openExternal(_ url: URL) {
        let allowedHosts = ["releases.1c.ru", "portal.1c.ru", "supportportal.thalesgroup.com"]
        let allowed = url.scheme == "https" && allowedHosts.contains(url.host?.lowercased() ?? "")
        let company = url.absoluteString == "https://ingvar.pro/?utm_source=keybridge&utm_medium=app&utm_campaign=settings"
        let release = url.absoluteString == "https://github.com/IngvarConsulting/keybridge/releases/latest"
        let settings = url.absoluteString == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            || url.absoluteString == "x-apple.systempreferences:com.apple.settings.Storage"
        guard allowed || company || settings || release else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshClient() async {
        let observation=clientObservation
        client = await Task.detached(priority:.utility) { observation.read() }.value
    }
    private func reload() async {
        reloadSequence &+= 1
        let sequence = reloadSequence
        let runtime = self.runtime
        let observation = await Task.detached(priority: .utility) { () -> ([String: Any], PreparationSnapshot?) in
            var snapshot: [String: Any]
            if var live = try? AgentIPC.exchange(runtime: runtime, message: ["ipc": "status"]), !live.isEmpty {
                let pid = (try? String(contentsOf: runtime.appendingPathComponent("agent.pid")))
                    .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let matches = pid.flatMap { process in AgentIdentity.processPath(process).map {
                    AgentIdentity.matches(status: live, pid: process, path: $0, executableDirectory: BridgePaths.executableDirectory)
                } } ?? false
                live["agentNeedsRestart"] = !matches
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
            do { try InstalledApplication.validateRuntime(runtime); snapshot["runtimeDataError"] = "" }
            catch { snapshot["runtimeDataError"] = error.localizedDescription }
            let progress = (try? Data(contentsOf: runtime.appendingPathComponent("preparation.json")))
                .flatMap { try? JSONDecoder().decode(PreparationSnapshot.self, from: $0) }
            return (snapshot, progress)
        }.value
        // The agent already observes client configuration. A cold/stopped app
        // uses the same native read-only observer, never a subprocess chain.
        if observation.0["stale"] as? Bool == true || observation.0["clientState"] == nil {
            await refreshClient()
        } else { client=[:] }
        guard !Task.isCancelled, sequence >= appliedSequence else { return }
        appliedSequence = sequence
        state = observation.0
        preparation = observation.1
        if let failureContext, failureContext != observationContext {
            failurePhase = nil; failureMessage = ""; failureInstallerIssue = ""; self.failureContext = nil
        }
        loaded = true
        publish()
    }

    private func publish() {
        var observed = state
        observed["loginLaunchSupported"] = BridgePaths.loginLaunchSupported && !isTemporaryCopy
        observed["loginAccess"] = LoginLaunch.access
        // The live agent knows current client state. On cold start the helper's
        // read-only inspection supplies it without launching the licensing VM.
        for (key, value) in client { observed[key] = value }
        if flow.active == nil, let failurePhase { observed["uiFailurePhase"] = failurePhase }
        var result = AppPresentation.snapshot(status: observed, preparation: preparation,
                                             installerRevision: fileRevisions["installer"], rejectedInstaller: rejectedInstaller)
        var view = result["state"] as? [String: Any] ?? [:]
        view["fault"] = NSNull()
        view["operationPending"] = flow.active != nil || state["busy"] as? Bool == true
        view["pendingDiagnostic"] = state["pendingDiagnostic"] ?? NSNull()
        view["activeDiagnostic"] = ["probe", "inspect", "resources"].contains(state["operation"] as? String ?? "") ? state["operation"]! : ""
        if !loaded || restoringController { view["phase"] = "loading" }
        if let active = flow.active {
            let phases = ["prepare": "preparing", "start": "starting", "stop": "stopping", "probe": "probing",
                          "configure": "configuring", "repair": "configuring", "restore": "restoring", "rollback": "restoring-version"]
            let awaitingOtherOperation = ApplicationCommandFlow.diagnostics.contains(active.action) &&
                (state["pendingDiagnostic"] as? String != nil || (state["busy"] as? Bool == true && state["operation"] as? String != active.action))
            if !awaitingOtherOperation, let phase = phases[active.action] { view["phase"] = phase }
            view["operationPending"] = true
        } else if let failurePhase {
            if !["unknown", "data-error", "unsafe", "multiple", "paused", "agent-update"].contains(view["phase"] as? String ?? "") { view["phase"] = failurePhase }
            view["errorMessage"] = failureMessage
            view["installerIssue"] = failureInstallerIssue
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
        guard !terminating, !busy, !running else {
            let reason = terminating ? "KeyBridge завершает работу. Откройте приложение снова и выберите файл."
                : running ? "KeyBridge ещё работает с ключом. Выключите его, затем выберите файл снова."
                : "Сейчас выполняется другое действие. Дождитесь его завершения, затем выберите файл снова."
            feedback = ["id": id, "action": kind, "ok": false, "message": reason]
            publish(); return
        }
        let panel = NSOpenPanel()
        panel.title = kind == "driver" ? "Выберите драйвер USB-ключа" : "Выберите установщик 1С"
        panel.message = kind == "driver" ? "Выберите пакет aksusbd для Linux amd64 (.deb) или скачанный архив. KeyBridge найдёт и проверит драйвер." : "Выберите полную поставку 1С для Linux x86-64 (.run) или скачанный архив. KeyBridge проверит наличие менеджера лицензий."
        panel.prompt = "Выбрать"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ([kind == "driver" ? "deb" : "run"] + ["zip", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz2"]).compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.feedback = ["id": id, "action": kind, "ok": false, "cancelled": true, "message": ""]
                self.publish(); return
            }
            guard !self.terminating, !self.busy, !self.running else {
                self.feedback = ["id": id, "action": kind, "ok": false, "message": "Дождитесь завершения действия и выберите файл снова."]
                self.publish(); return
            }
            self.inspectFile(url, kind: kind, id: id)
        }
    }

    private func inspectFile(_ url: URL, kind: String, id: String) {
        let previous = fileRevisions[kind].flatMap { importTasks[$0] }
        previous?.cancel()
        if let directory = importDirectories.removeValue(forKey: kind) { try? FileManager.default.removeItem(at: directory) }
        let revision = UUID()
        if kind == "installer" {
            if rejectedInstaller?.matches(status: state, preparation: preparation) != true {
                rejectedInstaller = InstallerFailureBinding(status: state, preparation: preparation,
                                                            installerRevision: fileRevisions["installer"])
            }
            if !failureInstallerIssue.isEmpty {
                failurePhase = nil; failureMessage = ""; failureInstallerIssue = ""; failureContext = nil
            }
        }
        fileRevisions[kind] = revision
        fileURLs.removeValue(forKey: kind)
        files[kind] = ["name": url.lastPathComponent, "valid": false, "checking": true, "message": "Читаем файл или архив…"]
        publish()
        let resources = BridgePaths.resources
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keybridge-selection-" + revision.uuidString)
        importTasks[revision] = Task {
            var retained = false
            defer {
                importTasks.removeValue(forKey: revision)
                if !retained { try? FileManager.default.removeItem(at: directory) }
            }
            do {
                await previous?.value
                try Task.checkCancellation()
                let candidates = try await Self.importWork {
                    try ImportArchive.resolve(url, kind: kind, directory: directory.appendingPathComponent("files"), cancelled: { Task.isCancelled })
                }
                try Task.checkCancellation()
                guard fileRevisions[kind] == revision else { return }
                let candidate = try await selectCandidate(candidates, kind: kind)
                try Task.checkCancellation()
                files[kind]?["message"] = kind == "installer" ? "Проверяем наличие менеджера лицензий…" : "Проверяем программы драйвера…"
                publish()
                let inspected = try await Self.importWork {
                    try ImportInspection.inspect(candidate, kind: kind, resources: resources,
                                                 workspace: directory.appendingPathComponent("preflight"), cancelled: { Task.isCancelled })
                }
                try Task.checkCancellation()
                guard fileRevisions[kind] == revision, inspected["valid"] as? Bool == true else { return }
                var file = inspected
                file["name"] = candidate.displayName
                file["sourceName"] = url.lastPathComponent
                file["checking"] = false
                files[kind] = file
                fileURLs[kind] = candidate.file
                importDirectories[kind] = directory
                retained = true
                feedback = ["id": id, "action": kind, "ok": true, "message": inspected["message"] ?? ""]
            } catch {
                guard fileRevisions[kind] == revision else { return }
                let cancelled = Task.isCancelled || error is CancellationError
                let message: String
                if cancelled { message = "Проверка отменена. Выберите файл заново." }
                else if error is BridgeError || error is VMEngineError { message = error.localizedDescription }
                else { message = "Не удалось прочитать файл. Проверьте доступ к нему или скачайте его заново и повторите выбор." }
                files[kind] = ["name": url.lastPathComponent, "valid": false, "checking": false, "error": message]
                feedback = ["id": id, "action": kind, "ok": false, "cancelled": cancelled, "message": message]
            }
            publish()
        }
    }

    /// Cancelling the parent task also cancels the worker and waits for its
    /// process cleanup. A replaced selection can never publish its old result.
    nonisolated private static func importWork<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try body() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private func selectCandidate(_ candidates: [ImportCandidate], kind: String) async throws -> ImportCandidate {
        guard !candidates.isEmpty else { throw BridgeError("В архиве нет подходящего компонента. Выберите другой файл.") }
        if candidates.count == 1 { return candidates[0] }
        try Task.checkCancellation()
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { throw BridgeError("Откройте окно KeyBridge и выберите архив снова: в нём несколько подходящих файлов.") }
        let alert = NSAlert()
        alert.messageText = kind == "installer" ? "В архиве несколько установщиков 1С" : "В архиве несколько драйверов HASP"
        alert.informativeText = "Выберите нужный файл. После выбора KeyBridge проверит его перед установкой."
        alert.addButton(withTitle: "Выбрать"); alert.addButton(withTitle: "Отмена")
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 28), pullsDown: false)
        choice.addItems(withTitles: candidates.map(\.displayName)); alert.accessoryView = choice
        let response = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response) }
            }
        }, onCancel: {
            Task { @MainActor in if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) } }
        })
        try Task.checkCancellation()
        guard response == .alertFirstButtonReturn else { throw CancellationError() }
        return candidates[choice.indexOfSelectedItem]
    }

    private func cancelImport(kind: String) {
        guard let revision = fileRevisions[kind], let task = importTasks[revision] else { return }
        task.cancel()
        fileRevisions[kind] = UUID()
        fileURLs.removeValue(forKey: kind)
        files[kind]?["checking"] = false; files[kind]?["valid"] = false
        files[kind]?["message"] = "Проверка отменена. Выберите файл заново."
    }

    func beginTermination() {
        terminating = true
        importTasks.values.forEach { $0.cancel() }
    }

    func finishImports() async {
        let tasks = Array(importTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        for directory in importDirectories.values { try? FileManager.default.removeItem(at: directory) }
        importDirectories.removeAll()
    }

    func requestQuit(id: String = UUID().uuidString) {
        guard !terminating else { return }
        for kind in ["installer", "driver"] { cancelImport(kind: kind) }
        flow.requestQuit()
        AppDelegate.shared?.showWindow()
        if flow.active?.action == "stop" { publish(); return }
        command("stop", id: id)
    }

    /// Ending the macOS session releases this session's resources without
    /// turning the user's future login choice into an explicit Stop.
    func endSession(completion: @escaping (Bool) -> Void) {
        beginTermination()
        operations.values.forEach { $0.cancel() }; operations.removeAll()
        flow = ApplicationCommandFlow()
        Task {
            do {
                let submitted = submissions.enqueue { try await Self.execute(["session-shutdown"]) }
                let receipt = try await submitted.value
                if receipt["alreadyStopped"] as? Bool == true {
                    let runtime = self.runtime
                    let ownership = await Task.detached(priority: .utility) {
                        RuntimeOwnership.observation(runtime: runtime)
                    }.value
                    guard receipt["agentExited"] as? Bool == true,
                          ownership["ownership"] as? String == "absent",
                          ownership["running"] as? Bool == false else {
                        throw ApplicationShutdown.Failure.unsafeState
                    }
                } else {
                    guard receipt["accepted"] as? Bool == true,
                          let id = receipt["requestID"] as? String, UUID(uuidString: id) != nil,
                          let pid = receipt["agentPID"] as? Int, let agentPID = Int32(exactly: pid), agentPID > 1 else {
                        throw ApplicationShutdown.Failure.noReceipt
                    }
                    let result = try await waitForCompletion(id, timeout: 30)
                    let deadline = Date().addingTimeInterval(10)
                    while !ApplicationShutdown.hasExited(agentPID), Date() < deadline {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let runtime = self.runtime
                    let evidence = await Task.detached(priority: .utility) {
                        ApplicationShutdown.observe(runtime: runtime, agentPID: agentPID, completion: result)
                    }.value
                    guard evidence.sessionEnded else { throw ApplicationShutdown.Failure.unsafeState }
                }
                await finishImports()
                completion(true)
            } catch {
                terminating = false
                await reload()
                failurePhase = "unknown"
                failureMessage = "KeyBridge не подтвердил остановку при выходе из macOS. Проверьте состояние KeyBridge и повторите выход из системы."
                failureContext = observationContext
                publish()
                AppDelegate.shared?.showWindow()
                completion(false)
            }
        }
    }

    func command(_ action: String, id: String = UUID().uuidString, value: Any? = nil) {
        guard !terminating else { return }
        if !["stop", "check-client"].contains(action), !validateRuntimeForLaunch() {
            feedback = ["id": id, "action": action, "ok": false, "message": state["runtimeDataError"] as? String ?? "Не удалось проверить данные KeyBridge."]
            publish(); return
        }
        let mapping = ["check-key": "refresh-key", "recheck": "inspect", "check-permission": "refresh-state", "measure": "resources"]
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
        if action == "stop" {
            operations.values.forEach { $0.cancel() }; operations.removeAll()
            state["pendingDiagnostic"] = NSNull()
        }
        if ["start", "stop", "prepare", "rollback", "configure", "repair", "restore"].contains(action) {
            failurePhase = nil; failureMessage = ""; failureInstallerIssue = ""; failureContext = nil
        }
        if action == "prepare" { rejectedInstaller = nil }
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
        operations[id] = Task {
            defer { operations.removeValue(forKey:id) }
            var succeeded = false
            var message = ""
            var shutdown: ApplicationShutdown.Evidence?
            do {
                let receipt = try await submitted.value
                guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                if receipt["queued"] as? Bool == true {
                    state["pendingDiagnostic"] = arguments.first ?? action
                    publish()
                }
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
                if action == "stop", flow.quitRequested {
                    // Quit may have arrived while this Stop was already running.
                    // Sending Shutdown only after its completion avoids an old
                    // agent coalescing Shutdown into a non-exiting Stop alias.
                    shutdown = try await shutDownAgentForQuit(ticket)
                    guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                }
                succeeded = true
            } catch {
                guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                await reload()
                guard flow.isCurrent(ticket), !Task.isCancelled else { return }
                message = (error as? ApplicationShutdown.Failure)?.localizedDescription
                    ?? AppPresentation.failureMessage(action: action, raw: error.localizedDescription)
                if ["prepare", "check-space", "start", "rollback", "restore"].contains(action) {
                    failureMessage = message
                    failureInstallerIssue = AppPresentation.installerIssue(action: action, raw: error.localizedDescription)
                    if !failureInstallerIssue.isEmpty {
                        rejectedInstaller = InstallerFailureBinding(status: state, preparation: preparation,
                                                                    installerRevision: fileRevisions["installer"])
                        // The installer advertised a manager, but its actual installation failed
                        // validation. Preserve the source label and the valid driver.
                        files["installer"] = ["name": files["installer"]?["name"] as? String ?? "",
                                              "sourceName": files["installer"]?["sourceName"] as? String ?? "",
                                              "valid": false, "checking": false, "error": message]
                    }
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
            }
            guard flow.isCurrent(ticket), !Task.isCancelled else { return }
            feedback = ["id": id, "action": action, "ok": succeeded, "message": message]
            let stopped = shutdown?.stopped ?? (state["ownership"] as? String == "absent" && state["running"] as? Bool != true && state["stale"] as? Bool != true)
            let saved = shutdown?.stopSaved ?? (state["stopSaved"] as? Bool ?? (state["desiredRunning"] as? Bool == false && state["autoInhibit"] as? Bool == true && state["persistenceError"] == nil))
            let shouldQuit = flow.finish(ticket, succeeded: succeeded, stopped: stopped, stopSaved: saved,
                                         agentExited: shutdown?.agentExited ?? false)
            publish()
            if shouldQuit { AppDelegate.shared?.finishQuit() }
        }
    }

    private func shutDownAgentForQuit(_ ticket: ApplicationCommandFlow.Ticket) async throws -> ApplicationShutdown.Evidence {
        let submission = submissions.enqueue { try await Self.execute(["shutdown"]) }
        let receipt = try await submission.value
        guard flow.isCurrent(ticket), !Task.isCancelled else { throw CancellationError() }
        if receipt["alreadyStopped"] as? Bool == true, receipt["agentExited"] as? Bool == true {
            let runtime = self.runtime
            let evidence = await Task.detached {
                ApplicationShutdown.observeWithoutAgent(runtime: runtime, completion: receipt)
            }.value
            guard evidence.confirmed else { throw ApplicationShutdown.Failure.unsafeState }
            return evidence
        }
        guard receipt["accepted"] as? Bool == true,
              let id = receipt["requestID"] as? String, UUID(uuidString: id) != nil,
              let pid = receipt["agentPID"] as? Int, let agentPID = Int32(exactly: pid), agentPID > 1 else {
            throw ApplicationShutdown.Failure.noReceipt
        }
        let completion = try await waitForCompletion(id, timeout: 30)
        guard completion["ok"] as? Bool == true else {
            throw BridgeError(completion["error"] as? String ?? ApplicationShutdown.Failure.noReceipt.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(10)
        while !ApplicationShutdown.hasExited(agentPID) {
            guard flow.isCurrent(ticket), !Task.isCancelled else { throw CancellationError() }
            guard Date() < deadline else { throw ApplicationShutdown.Failure.agentStillRunning }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let runtime = self.runtime
        let evidence = await Task.detached(priority: .utility) {
            ApplicationShutdown.observe(runtime: runtime, agentPID: agentPID, completion: completion)
        }.value
        guard evidence.confirmed else { throw ApplicationShutdown.Failure.unsafeState }
        return evidence
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
        _ = await Task.detached(priority:.utility) {
            try? AgentIPC.exchange(runtime:runtime,message:["ipc":"cancel","requestID":id])
        }.value
        throw BridgeError("Истёк срок ожидания. Запрошена отмена действия; проверьте фактическое состояние KeyBridge.")
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
