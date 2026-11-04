// SPDX-License-Identifier: MIT
import Combine
import Foundation
import KeyBridgeCore

struct InterfaceAction: Identifiable, Equatable {
    var id: String
    var title: String
    var primary = false
    var disabled = false
}
struct InterfaceFile {
    var name: String
    var valid: Bool
    var checking: Bool
    var error: String
    var message: String
    var validation: String
    init(_ data: [String: Any] = [:]) {
        name = data["name"] as? String ?? ""
        valid = data["valid"] as? Bool ?? false
        checking = data["checking"] as? Bool ?? false
        error = data["error"] as? String ?? ""
        message = data["message"] as? String ?? ""
        validation = data["validation"] as? String ?? ""
    }
}

/// Owns navigation and feedback only. Runtime facts always come from AppModel;
/// pressing a button never changes readiness, saved preferences or proof.
@MainActor
final class KeyBridgeInterfaceState: ObservableObject {
    struct Pending {
        let action: String
        let value: Any?
        let epoch: UInt64
        let context: String
        let signature: String
    }
    struct Route { let page: String; let tab: String; let focus: String? }
    @Published private(set) var state: [String: Any] = ["phase": "loading", "client": "unknown", "permission": "unknown", "saved": true]
    @Published var tab = "main"
    @Published var page = ""
    @Published var setupStep = "installer"
    @Published var editing = false
    @Published var replacing = false
    @Published private(set) var pendingAuto: Bool?
    @Published private(set) var autoWorking = false
    @Published private(set) var autoSaved = false
    @Published private(set) var autoError = ""
    @Published private(set) var files = ["installer": InterfaceFile(), "driver": InterfaceFile()]
    @Published private(set) var keyLabel = ""
    @Published private(set) var componentLabel = ""
    @Published private(set) var proofTime = ""
    @Published private(set) var resourcesNote = ""
    @Published private(set) var resourceRows: [(label: String, value: String)] = []
    @Published private(set) var feedbackRevision = 0
    @Published private(set) var feedbackAnnouncement = ""
    @Published var requestedFocus: String?
    var lastFocusedAction: String?
    private(set) var navigation: [Route] = []
    private(set) var pending: [String: Pending] = [:]
    private var results: [String: (text: String, signature: String)] = [:]
    private var seen: [String] = []
    private(set) var epoch: UInt64 = 0
    private var dismissedError: String?
    private let send: ([String: Any]) -> Void
    var scrollPositions: [String: Double] = [:]
    static let commands: Set<String> = ["installer", "driver", "cancel-installer", "cancel-driver", "prepare", "start", "stop", "quit", "configure", "repair", "restore", "rollback", "probe", "monitor", "check-key", "check-client", "check-space", "recheck", "check-permission", "measure", "autostart", "open-url"]
    static let scopes = ["probe": "probe", "check-key": "key", "check-space": "space", "check-permission": "permission", "check-client": "client", "recheck": "safety", "stop": "stop", "quit": "stop", "prepare": "install", "monitor": "monitor", "configure": "config", "repair": "config", "restore": "config", "rollback": "config", "measure": "resources"]
    static let mutations: Set<String> = ["prepare", "start", "stop", "quit", "configure", "repair", "restore", "rollback", "probe"]
    init(send: @escaping ([String: Any]) -> Void = { _ in }) { self.send = send }
    func text(_ key: String) -> String { state[key] as? String ?? "" }
    func flag(_ key: String) -> Bool { state[key] as? Bool ?? false }
    var phase: String { text("phase") }
    var client: String { text("client") }
    var context: String { text("contextVersion") }
    var visibleError: String { !text("accessError").isEmpty && dismissedError == text("accessError") ? "" : text("errorMessage") }
    var active: Bool { ["ready", "starting", "waiting", "probing", "recovering", "paused", "reconciling"].contains(phase) }
    var busy: Bool {
        pending.values.contains { Self.mutations.contains($0.action) } || flag("operationPending") ||
        ["loading", "preparing", "starting", "probing", "stopping", "recovering", "configuring", "restoring", "restoring-version", "reconciling"].contains(phase)
    }
    var diagnosticWaiting: Bool { !text("pendingDiagnostic").isEmpty }
    var diagnosticWaitMessage: String { diagnosticWaiting ? "Проверка ожидает завершения текущего действия" : "" }
    func canRequestDiagnostic(_ action:String)->Bool {
        guard !["loading", "stopping", "paused"].contains(phase), !pendingAction("stop"), !pendingAction("quit"),
              !diagnosticWaiting, !pendingAction(action) else { return false }
        let active = text("activeDiagnostic").isEmpty && phase == "probing" ? "probe" : text("activeDiagnostic")
        let backend = ["recheck":"inspect", "measure":"resources", "probe":"probe"]
        guard !pending.values.contains(where: { ApplicationCommandFlow.diagnostics.contains($0.action) && backend[$0.action] != active }) else { return false }
        if action == "probe" {
            return flag("key") && client == "managed" && text("safetyBlock").isEmpty &&
                !["unsafe", "multiple", "unknown", "data-error", "reconciling", "agent-update", "probing"].contains(phase)
        }
        return true
    }
    var proofSaveNote: String {
        let error=text("proofSaveError")
        return error.isEmpty ? "" : "Результат показан, но не сохранён для следующего запуска. " + error
    }
    var locked: Bool { busy || active || ["unknown", "data-error"].contains(phase) }
    func pendingAction(_ action: String) -> Bool { pending.values.contains { $0.action == action } }
    var routeKey: String { "\(tab):\(screen):\(screen == "setup" ? setupStep : "")" }
    var screen: String {
        // Help pages have their own navigation; diagnosis and configuration
        // review remain subordinate to freshly observed runtime conditions.
        if !page.isEmpty && !["diagnosis", "review-settings"].contains(page) { return page }
        if tab == "settings" { return "settings" }
        if ["agent-update", "loading", "unknown", "data-error"].contains(phase) { return phase }
        if (editing && !busy && !active) || phase == "first" { return "setup" }
        if ["paused", "reconciling", "rollback-error", "restore-error", "preparing", "starting", "stopping", "recovering", "configuring", "restoring", "restoring-version", "install-error", "start-error"].contains(phase) { return phase }
        if client == "missing" { return "client-missing" }
        if page == "review-settings" { return page }
        if !text("accessError").isEmpty && dismissedError != text("accessError") { return "access-error" }
        if ["unknown", "unconfigured", "external"].contains(client) { return "client-\(client)" }
        if ["unsafe", "multiple", "exhausted", "waiting"].contains(phase) { return phase }
        if phase == "update-error" || (phase == "stopped" && flag("updateProblem") && flag("previousAvailable")) { return "update-error" }
        if phase == "stopped" { return flag("saved") ? "stopped" : "stop-unsaved" }
        if page == "diagnosis", ["ready", "probing"].contains(phase) { return page }
        if phase == "probing" { return "diagnosis" }
        return phase == "ready" ? "ready" : "unknown"
    }
    func signature(_ scope: String) -> String {
        if scope == "file-installer" || scope == "file-driver" {
            let file = files[String(scope.dropFirst(5))] ?? InterfaceFile()
            return [phase, String(flag("operationPending")), context, file.name, String(file.valid),
                    String(file.checking), file.error, file.message, file.validation].joined(separator: "\u{1f}")
        }
        let keys: [String]
        switch scope {
        case "key": keys = ["key", "phase", "contextVersion"]
        case "space": keys = ["fault", "contextVersion"]
        case "permission": keys = ["permission", "autoAvailable"]
        case "client": keys = ["client"]
        case "stop": keys = ["phase", "saved", "hold"]
        case "safety": keys = ["phase", "safetyBlock", "key", "contextVersion"]
        case "config": keys = ["client", "phase", "accessError", "hold"]
        case "monitor": keys = ["phase", "contextVersion"]
        case "resources": keys = ["contextVersion"]
        case "probe": keys = ["contextVersion", "proof"]
        case "install": return [phase, files["installer"]?.name ?? "", files["driver"]?.name ?? ""].joined(separator: "\u{1f}")
        default: keys = []
        }
        return keys.map { String(describing: state[$0] ?? NSNull()) }.joined(separator: "\u{1f}")
    }
    func result(_ scope: String) -> String {
        guard let item = results[scope], item.signature == signature(scope) else { return "" }
        return item.text
    }
    private func record(_ scope: String?, _ message: String) {
        guard let scope, !message.isEmpty else { return }
        results[scope] = (message, signature(scope))
    }
    func clearResults() { results.removeAll(); autoSaved = false }
    @discardableResult func request(_ action: String, value: Any? = nil) -> [String: Any]? {
        guard Self.commands.contains(action) else { return nil }
        if ApplicationCommandFlow.diagnostics.contains(action), !canRequestDiagnostic(action) { return nil }
        if ["start", "restore", "rollback"].contains(action), busy { return nil }
        if action == "prepare", ["missing-license-manager", "ambiguous-license-manager"].contains(text("installerIssue")), files["installer"]?.valid != true { return nil }
        if !flag("autoAvailable") && ((action == "autostart" && value as? Bool == true) || action == "check-permission") { return nil }
        if action.hasPrefix("cancel-") { pending = pending.filter { $0.value.action != String(action.dropFirst(7)) } }
        guard action == "open-url" || !pendingAction(action) else { return nil }
        if ["installer", "driver"].contains(action) { results.removeValue(forKey: "file-" + action) }
        if ["cancel-installer", "cancel-driver"].contains(action) { results.removeValue(forKey: "file-" + String(action.dropFirst(7))) }
        if action == "stop" || action == "quit" {
            state["pendingDiagnostic"] = NSNull()
            epoch &+= 1; pending.removeAll(); pendingAuto = nil; autoWorking = false; autoError = ""; clearResults()
        } else if action == "probe" { results.removeValue(forKey:"probe") }
        else if Self.mutations.contains(action) { clearResults() }
        let id = UUID().uuidString
        var request: [String: Any] = ["id": id, "action": action]
        if let value { request["value"] = value }
        if action != "open-url" { pending[id] = Pending(action: action, value: value, epoch: epoch, context: context, signature: signature(Self.scopes[action] ?? "")) }
        record(Self.scopes[action], ["stop", "quit"].contains(action) ? "Сохраняем выключение…" : action == "monitor" ? "Открываем монитор…" : "Проверяем…")
        if action == "autostart" { pendingAuto = value as? Bool ?? false; autoWorking = true; autoSaved = false; autoError = "" }
        objectWillChange.send(); send(request); return request
    }
    func cancelAuto() {
        guard !autoWorking else { return }
        pendingAuto = nil; autoError = ""; autoSaved = false
    }
    func chooseAuto(_ value: Bool) {
        if value == flag("auto") && !(value && (flag("hold") || text("permission") == "unregistered")) { cancelAuto(); return }
        request("autostart", value: value)
    }
    func update(_ payload: [String: Any]) {
        let oldPhase = phase, oldContext = context, oldAvailable = flag("autoAvailable")
        if let next = payload["state"] as? [String: Any] { state.merge(next) { _, new in new } }
        if let next = payload["files"] as? [String: [String: Any]] {
            for kind in ["installer", "driver"] {
                if let data = next[kind] {
                    let wasChecking = files[kind]?.checking == true
                    let file = InterfaceFile(data)
                    files[kind] = file
                    if wasChecking && !file.checking && screen == "setup" && setupStep == kind,
                       let focused = lastFocusedAction, [kind, "cancel-\(kind)"].contains(focused) { requestedFocus = kind }
                }
            }
        }
        if let value = payload["keyLabel"] as? String { keyLabel = value }
        if let value = payload["componentLabel"] as? String { componentLabel = value }
        if let value = payload["proofTime"] as? String { proofTime = value }
        if let value = payload["resourcesNote"] as? String { resourcesNote = value }
        if let rows = payload["resourceRows"] as? [[String: String]] { resourceRows = rows.compactMap { row in guard let label = row["label"], let value = row["value"] else { return nil }; return (label, value) } }
        if !flag("autoAvailable") {
            pending = pending.filter { !($0.value.action == "autostart" && $0.value.value as? Bool == true) && $0.value.action != "check-permission" }
            if pendingAuto == true { pendingAuto = nil; autoWorking = false }
            if oldAvailable { autoSaved = false; autoError = "" }
            if page == "permission" { page = "" }
            navigation = navigation.filter { $0.page != "permission" }
        }
        if oldContext != context || oldPhase != phase {
            if oldContext != context { results.removeAll() }
            if page == "monitor-error" { page = "" }
            navigation = navigation.filter { $0.page != "monitor-error" }
        }
        if oldPhase != phase, ["unknown", "data-error", "unsafe", "multiple", "paused", "reconciling", "stopping"].contains(phase) {
            editing = false; dismissedError = nil; navigate("main")
        }
        if text("errorMessage").isEmpty { dismissedError = nil }
        if let feedback = payload["feedback"] as? [String: Any], let id = feedback["id"] as? String, !seen.contains(id) {
            seen.append(id); if seen.count > 200 { seen.removeFirst() }
            if let request = pending.removeValue(forKey: id), request.epoch == epoch {
                let ok = feedback["ok"] as? Bool == true
                let staleFailure = !ok && ["check-key", "check-client", "recheck", "measure", "monitor"].contains(request.action) && (request.context != context || request.signature != signature(Self.scopes[request.action] ?? ""))
                if !staleFailure {
                    feedbackRevision += 1
                    let message = feedback["message"] as? String ?? ""
                    feedbackAnnouncement = request.action == "autostart" && ok ? "Выбор автозапуска сохранён." : message
                    switch request.action {
                    case "probe":
                        if ok || request.context != context { results.removeValue(forKey: "probe") }
                        else { record("probe", message.isEmpty ? "Не удалось выполнить проверку. Повторите её после завершения текущего действия." : message) }
                    case "installer", "driver":
                        let scope = "file-" + request.action
                        if !ok && feedback["cancelled"] as? Bool != true {
                            record(scope, message.isEmpty ? "Не удалось выбрать файл. Повторите выбор после завершения текущего действия." : message)
                        } else { results.removeValue(forKey: scope) }
                    case "autostart":
                        autoWorking = false
                        if ok { pendingAuto = nil; autoError = ""; autoSaved = true }
                        else { autoError = message.isEmpty ? "Не удалось сохранить выбор. Повторите сохранение или отмените изменение." : message }
                    case "monitor":
                        if ok {
                            if page == "monitor-error" { back() }
                            navigation = navigation.filter { $0.page != "monitor-error" }
                            record("monitor", message.isEmpty ? "Запуск монитора передан в 1С." : message)
                        } else {
                            if page != "monitor-error" { push("monitor-error", focus: "monitor") }
                            record("monitor", message)
                        }
                    case "prepare": editing = false; replacing = false; navigate("main"); record("install", message)
                    case "configure", "repair", "restore", "rollback": navigate("main"); record("config", message)
                    default: record(Self.scopes[request.action], message)
                    }
                }
            }
        }
        if oldPhase == "preparing", phase == "stopped" { editing = false; replacing = false; navigate("main") }
        objectWillChange.send()
    }
    func navigate(_ destination: String) {
        navigation.removeAll(); page = destination == "diagnosis" ? "diagnosis" : ""; tab = destination == "settings" ? "settings" : "main"
    }
    func push(_ destination: String, focus: String? = nil) {
        navigation.append(Route(page: page, tab: tab, focus: focus)); page = destination
    }
    func back() {
        if editing && replacing { editing = false; replacing = false; tab = "settings"; page = "additional"; return }
        if let previous = navigation.popLast() { page = previous.page; tab = previous.tab; requestedFocus = previous.focus }
        else { page = "" }
    }
    func perform(_ action: String) {
        switch action {
        case "additional-actions": push("additional", focus: action)
        case "resources": push(action, focus: action)
        case "back", "close-help", "close-diagnosis", "detail-back": back()
        case "restore-back": navigate("settings"); page = "additional"
        case "diagnose": push("diagnosis", focus: action)
        case "manual-license": push("manual", focus: action)
        case "client-help": push("client-help", focus: action)
        case "storage-help": push("storage", focus: action)
        case "permission": push("permission", focus: action)
        case "review-settings": push("review-settings", focus: action); tab = "main"
        case "cancel-settings": back()
        case "dismiss-access": dismissedError = text("accessError"); back()
        case "configure": request(client == "external" ? "repair" : "configure")
        case "retry-access": request(text("accessError") == "restoring" ? "restore" : client == "external" ? "repair" : "configure")
        case "save-stop": request(flag("pendingQuit") ? "quit" : "stop")
        case "resume-auto": chooseAuto(true)
        case "retry-auto": if let pendingAuto { request("autostart", value: pendingAuto) }
        case "cancel-auto": cancelAuto()
        case "setup-next":
            if setupStep == "installer", files["installer"]?.valid == true { setupStep = "driver" }
            else if setupStep == "driver", files["driver"]?.valid == true { setupStep = "review" }
        case "setup-back": setupStep = setupStep == "review" ? "driver" : "installer"
        case "edit-installer": setupStep = "installer"
        case "cancel-replace": back()
        case "replace", "open-install":
            guard !locked else { return }
            editing = true; replacing = flag("prepared"); setupStep = "installer"; navigate("main")
        case "prepare", "retry-install":
            guard !busy, !active, files["installer"]?.valid == true, files["driver"]?.valid == true else { return }
            navigate("main"); request("prepare")
        case "probe", "recheck", "measure": request(action)
        case "start", "restore", "rollback":
            guard !busy else { return }
            request(action)
        case "open-permission-settings": request("open-url", value: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        default: request(action)
        }
    }
}
