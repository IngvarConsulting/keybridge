// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import ServiceManagement
import CoreGraphics
import Darwin
import KeyBridgeCore

umask(0o077)
let runtime=BridgePaths.runtime
try BridgePaths.preparePrivateDirectory(runtime)
let lockFD=open(runtime.appendingPathComponent("agent.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
guard lockFD>=0,flock(lockFD,LOCK_EX|LOCK_NB)==0 else { exit(0) }
let pidURL=runtime.appendingPathComponent("agent.pid")
try String(getpid()).write(to:pidURL,atomically:true,encoding:.utf8)
let engine=VMEngine(runtime:runtime,resources:BridgePaths.resources)
let journal=OperationJournal(runtime:runtime)
let snapshot=RuntimeSnapshot()
let statusWriteLock=NSRecursiveLock()
let authorization=RunAuthorization()
let intent:IntentStore? = {
    do { return try IntentStore(runtime:runtime) }
    catch { fputs("KeyBridge intent: \(error.localizedDescription)\n",stderr);return nil }
}()
let work=DispatchQueue(label:"pro.keybridge.agent.operations")
let statusURL=runtime.appendingPathComponent("status.json")
let probeURL=runtime.appendingPathComponent("probe.json")
let cancelURL=runtime.appendingPathComponent("cancel.request")
var active:OperationToken?
var pendingStops=[(String,[String:Any])]()
let sessionState=RunAuthorization()
var sessionActive:Bool { get { sessionState.allowed } set { sessionState.set(newValue) } }
sessionActive=(CGSessionCopyCurrentDictionary() as? [String:Any])?[kCGSessionOnConsoleKey as String] as? Bool ?? false
var exitRequested=false
var reconcilePending=false
var nextReconcileAt=Date.distantPast
var stopAliases=[String:[String]]()
var stopWriteErrors=[String:String]()

func loginAccess()->String {
    guard BridgePaths.loginLaunchSupported else { return "unsupported" }
    switch SMAppService.agent(plistName:"pro.keybridge.pilot.agent.plist").status {
    case .enabled:return "allowed"
    case .requiresApproval:return "denied"
    default:return "unknown"
    }
}
func updateStatus(_ patch:[String:Any]) {
    statusWriteLock.lock();defer{statusWriteLock.unlock()}
    snapshot.patch(patch)
    var state=snapshot.status()
    state["updated"]=Date().timeIntervalSince1970
    state["platformVersion"]=BridgePaths.version
    if let desired=intent?.value {
        state["autostart"]=desired.autostart;state["desiredRunning"]=desired.want
        state["autoInhibit"]=desired.autoInhibit;state["remainingAttempts"]=desired.remaining
    }
    state["armed"]=authorization.allowed;state["loginLaunchSupported"]=BridgePaths.loginLaunchSupported
    state["loginAccess"]=loginAccess();state["sessionActive"]=sessionActive
    state["reconciling"] = state["operation"] as? String == "reconcile" && state["busy"] as? Bool == true
        && !(engine.hasConnectionContext && state["ownership"] as?String == "owned" && ["running","waiting-key"].contains(state["status"] as?String ?? ""))
    do { try writeObject(state,to:statusURL) }
    catch { state["persistenceError"]=error.localizedDescription;fputs("KeyBridge status: \(error.localizedDescription)\n",stderr) }
    snapshot.replace(state)
}
func invalidateProbe(_ message:String) {
    statusWriteLock.lock();defer{statusWriteLock.unlock()}
    let result:[String:Any]=["result":"unknown","success":false,"message":message,"timestamp":Date().timeIntervalSince1970]
    snapshot.patch(["lastProbe":result])
    do { try writeObject(result,to:probeURL) } catch { updateStatus(["persistenceError":error.localizedDescription]) }
}
func complete(_ id:String,_ response:[String:Any]) {
    snapshot.complete(id,response)
    do {
        let folder=runtime.appendingPathComponent("results");try BridgePaths.preparePrivateDirectory(folder)
        try writeObject(response,to:folder.appendingPathComponent(id+".json"))
    } catch { updateStatus(["persistenceError":error.localizedDescription]) }
}
func configureClient(_ operation:String,_ token:OperationToken) throws {
    guard engine.status()["ownership"] as? String == "absent" else { throw BridgeError("Сначала остановите раздачу перед изменением настроек 1С") }
    let helper=BridgePaths.executableDirectory.appendingPathComponent("KeyBridgeConfigure").path
    if operation == "apply",try hostCommand(helper,["status"]).output.trimmingCharacters(in:.whitespacesAndNewlines)=="configured" { return }
    let folder=runtime.appendingPathComponent("configuration")
    try BridgePaths.preparePrivateDirectory(folder)
    let fifo=folder.appendingPathComponent(token.id+".fifo")
    guard mkfifo(fifo.path,0o600)==0 else { throw BridgeError("Канал подтверждения настройки не создан") }
    defer{try?FileManager.default.removeItem(at:fifo)}
    let command=shellQuote(helper)+" "+shellQuote(operation)+" --lease "+shellQuote(fifo.path)
    let escaped=command.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
    let result=try hostCommand("/usr/bin/osascript",["-e","do shell script \"\(escaped)\" with administrator privileges"],timeout:300,cancellation:cancelURL,isCancelled:{ !journal.isCurrent(token) },onPoll:{ try journal.grantConfiguration(token,fifo:fifo) })
    guard journal.isCurrent(token) else { throw BridgeError("Настройка прервана; её фактическое состояние нужно проверить") }
    guard result.code==0,!result.timedOut else { throw BridgeError("Настройка 1С не подтверждена: "+result.output) }
}
@discardableResult func inspectClient()->[String:Any] {
    let helper=BridgePaths.executableDirectory.appendingPathComponent("KeyBridgeConfigure").path
    guard let result=try?hostCommand(helper,["inspect"],timeout:15),result.code==0,
          let data=result.output.data(using:.utf8),let state=(try?JSONSerialization.jsonObject(with:data)) as? [String:Any] else {
        let state:[String:Any]=["clientState":"unknown","backupState":"unknown","backupAvailable":false];updateStatus(state);return state
    }
    updateStatus(state);return state
}
func clientManaged()->Bool { inspectClient()["clientState"] as? String == "configured" }
func startPermitted(_ token:OperationToken) throws ->[String:Any] {
    guard authorization.allowed,sessionActive,let intent else { throw BridgeError("Запуск не разрешён текущим намерением") }
    var state=engine.status()
    if state["ownership"] as? String == "owned",!engine.hasConnectionContext {
        // Adopt process ownership, but never invent continuity of an old USB
        // capture. Release it, then reacquire with this observer and a new epoch.
        invalidateProbe("После восстановления агента требуется новый контекст USB")
        try engine.stop();state=engine.status()
    }
    guard state["ownership"] as? String != "unknown" else { throw VMEngineError.safety("Принадлежность VM неизвестна; второй запуск запрещён") }
    if state["ownership"] as? String == "absent" {
        guard intent.value.remaining>0 else { authorization.set(false);try?intent.hold();throw BridgeError("Бюджет восстановления исчерпан") }
        try journal.publish(token) { try intent.consumeAttempt() }
        invalidateProbe("Новый запуск требует новой проверки")
    }
    return try engine.perform(["action":"start"])
}
func runProbe(_ token:OperationToken) throws -> [String: Any] {
    guard engine.status()["running"] as? Bool == true else { throw BridgeError("Сначала запустите раздачу") }
    guard let client=ClientInstallation.discover() else {throw BridgeError("Установите клиент 1С для macOS ARM64.")}
    let executable = try hostCommand("/usr/bin/file", ["-L", client.executable.path])
    guard executable.code == 0, executable.output.contains("arm64") else { throw BridgeError("Нужен установленный клиент 1С для macOS ARM64") }
    let folder = runtime.appendingPathComponent("probes/" + UUID().uuidString)
    try BridgePaths.preparePrivateDirectory(folder)
    let database = folder.appendingPathComponent("ib")
    let before = try engine.perform(["action": "licenseEvidence"])
    let create = try hostCommand("/usr/bin/arch", ["-arm64", client.executable.path, "CREATEINFOBASE", "File=\"\(database.path)\";", "/DisableStartupDialogs", "/DisableStartupMessages", "/Out", folder.appendingPathComponent("create.log").path], timeout: 120, log: folder.appendingPathComponent("create.stdout"), cancellation: cancelURL,isCancelled:{ !journal.isCurrent(token) })
    if create.timedOut { throw BridgeError("Процесс 1С не завершился за время проверки создания базы. См. create.log в локальном каталоге probes.") }
    guard create.code == 0 else { throw BridgeError("Не удалось создать отдельную проверочную базу: \(create.output)") }
    let cf = folder.appendingPathComponent("probe.cf")
    let resultFile = folder.appendingPathComponent("result.txt")
    let started = Date().timeIntervalSince1970
    let run = try hostCommand("/usr/bin/arch", ["-arm64", client.executable.path, "DESIGNER", "/F", database.path,
        "/DisableStartupDialogs", "/DisableStartupMessages", "/DisableUnrecoverableErrorMessage", "/DumpCfg", cf.path,
        "/Out", folder.appendingPathComponent("client.log").path, "/DumpResult", resultFile.path], timeout: 120, log: folder.appendingPathComponent("client.stdout"), cancellation: cancelURL,isCancelled:{ !journal.isCurrent(token) })
    let dumpResult = ((try? String(contentsOf: resultFile, encoding: .utf8)) ?? "").replacingOccurrences(of: "\u{feff}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    let cfBytes = (try? FileManager.default.attributesOfItem(atPath: cf.path)[.size] as? NSNumber)?.intValue ?? 0
    let issuedBefore = (before["seize"] as? Int ?? 0) + (before["reuse"] as? Int ?? 0)
    var after = try engine.perform(["action": "licenseEvidence","baseline":before])
    let logDeadline = Date().addingTimeInterval(15)
    while run.code == 0 && dumpResult == "0" && cfBytes > 0 && Date() < logDeadline &&
        (after["seize"] as? Int ?? 0) + (after["reuse"] as? Int ?? 0) <= issuedBefore {
        Thread.sleep(forTimeInterval: 0.5)
        after = try engine.perform(["action": "licenseEvidence","baseline":before])
    }
    let issuedAfter = (after["seize"] as? Int ?? 0) + (after["reuse"] as? Int ?? 0)
    let hardwareDelta = (after["hardwareLocal"] as? Int ?? 0) - (before["hardwareLocal"] as? Int ?? 0)
    let clientSucceeded = run.code == 0 && !run.timedOut && dumpResult == "0" && cfBytes > 0
    let operationSucceeded = clientSucceeded && issuedAfter > issuedBefore && hardwareDelta > 0
    let contextBefore=before["context"] as? [String:Any] ?? [:]
    let contextAfter=after["context"] as? [String:Any] ?? [:]
    let continuity=LicenseEvidence.continuous(before:before,after:after)
    let contextStable = !contextBefore.isEmpty && NSDictionary(dictionary:contextBefore).isEqual(to:contextAfter)
    // No available source yet binds a LIC event to this client process. Never
    // convert aggregate deltas into a causal success, even on the happy path.
    let confirmed=false
    let result: [String: Any] = ["success": confirmed, "result": operationSucceeded ? "unconfirmed" : "failure",
        "message": operationSucceeded ? "Операция 1С выполнена; аппаратная выдача наблюдалась в VM. Связь с этой пробой не подтверждена." : "Получение лицензии от VM не подтверждено; см. диагностику проверки",
        "clientOperationSucceeded":clientSucceeded,"journalContinuous":continuity,"contextStable":contextStable,"causalIsolation":false,"contextBefore":contextBefore,"contextAfter":contextAfter,
        "timestamp": Date().timeIntervalSince1970, "started": started, "exitCode": run.code, "dumpResult": dumpResult,
        "configurationBytes": cfBytes, "managerIssuanceDelta": issuedAfter - issuedBefore, "hardwareLocalDelta": hardwareDelta, "architecture": "arm64", "version": client.version,
        "evidenceScope": "Aggregate guest hardware-license events; no causal client isolation"]
    try journal.publish(token) { try writeObject(result, to: folder.appendingPathComponent("result.json")) }
    // Generated 1C content stays private, and does not need to accumulate.
    try? FileManager.default.removeItem(at: database); try? FileManager.default.removeItem(at: cf)
    return result
}
func processNext() {
    guard active==nil,!pendingStops.isEmpty else { return }
    let (id,request)=pendingStops.removeFirst()
    begin(id,request,safety:true)
}
@discardableResult func begin(_ id:String,_ request:[String:Any],safety:Bool=false) -> Bool {
    let action=request["action"] as? String ?? ""
    let token:OperationToken
    do { token=try journal.begin(id:id,action:action,safety:safety) }
    catch { complete(id,["ok":false,"error":error.localizedDescription]);return false }
    active=token
    let admissionError=journal.persistenceError
    let stopWriteError=stopWriteErrors[id]
    if !safety { try?FileManager.default.removeItem(at:cancelURL) }
    updateStatus(["busy":true,"operation":action,"lastError":""])
    if !["health","reconcile"].contains(action) {updateStatus(["lastFailure":NSNull()])}
    work.async {
        engine.operationCancelled={ !journal.isCurrent(token) }
        engine.publicationBarrier={ body in try journal.publish(token,body) }
        engine.stateSink={ patch in try? journal.publish(token) {
            var observation=patch;observation.removeValue(forKey:"lastProbe")
            if patch["lastProbe"] != nil { invalidateProbe("Окружение изменилось") }
            updateStatus(observation)
        } }
        var response:[String:Any]
        do {
            var result:[String:Any]
            switch action {
            case "start":
                guard engine.status()["prepared"] as? Bool == true else { throw BridgeError("Сначала подготовьте пригодную среду") }
                guard engine.status()["ownership"] as? String != "unknown" else { throw VMEngineError.safety("Принадлежность VM неизвестна") }
                guard clientManaged() else { throw BridgeError("Сначала подключите 1С в настройках") }
                try journal.publish(token) {
                    guard let intent else { throw BridgeError("Намерение недоступно: запуск запрещён") }
                    try intent.start();authorization.set(true)
                }
                invalidateProbe("После запуска нужна новая проверка")
                result=try startPermitted(token)
            case "prepare","rollback":
                try journal.publish(token) {
                    guard let intent else { throw BridgeError("Намерение недоступно") };try intent.prepare();authorization.set(false)
                }
                invalidateProbe("После смены поколения нужна новая проверка")
                result=try engine.perform(request)
            case "stop","shutdown","session-stop":
                let errors=StopTransaction.perform(persist:{
                    if let stopWriteError { throw BridgeError(stopWriteError) }
                },stop:{ try engine.stop() })
                invalidateProbe("Прежнее подтверждение после остановки недействительно")
                result=engine.status()
                var all=errors;if let admissionError { all.append("Журнал приёма не сохранён: "+admissionError) }
                if !all.isEmpty { throw BridgeError(all.joined(separator:"; ")) }
            case "health","refresh-key","reconcile":
                let before=engine.status()
                if !authorization.allowed || !sessionActive || intent?.value.want != true {
                    try engine.stop();result=engine.status()
                } else if before["prepared"] as? Bool != true || !clientManaged() {
                    authorization.set(false);try?intent?.hold()
                    try engine.stop()
                    throw BridgeError("Поколение или настройки клиента больше не подтверждены; автоматическое возобновление запрещено")
                } else if before["ownership"] as? String == "absent" {
                    result=try startPermitted(token)
                } else if !engine.hasConnectionContext {
                    result=try startPermitted(token)
                } else {
                    do { result=try engine.perform(["action":"health"]) }
                    catch {
                        if let safety=error as? VMEngineError,case .safety=safety { throw error }
                        invalidateProbe("Наблюдение или службы изменились")
                        guard authorization.allowed,sessionActive,intent?.value.want == true else { throw error }
                        try engine.stop()
                        result=try startPermitted(token)
                    }
                }
                if result["keyConnected"] as? Bool != true { invalidateProbe("Ключ не подтверждён") }
            case "probe":
                guard clientManaged() else { throw BridgeError("Сначала подключите локальную 1С в настройках") }
                let probe=try runProbe(token)
                try journal.publish(token) { try writeObject(probe,to:probeURL);updateStatus(["lastProbe":probe]) }
                result=probe
            case "configure","repair","restore":
                try configureClient(action == "configure" ? "apply":action == "repair" ? "repair":"restore",token)
                result=engine.status();result.merge(inspectClient()){_,new in new}
            case "refresh-state":
                result=engine.status();result.merge(inspectClient()){_,new in new}
                if result["ownership"] as? String == "absent" {result["status"]=result["prepared"] as? Bool == true ? "stopped":"unprepared";result["keyConnected"]=false;updateStatus(result)}
            case "autostart":
                guard let enabled=request["enabled"] as? Bool,let intent else { throw BridgeError("Настройка автозапуска не задана") }
                try journal.publish(token) { try intent.setAutostart(enabled) }
                updateStatus(["registrationError":NSNull()])
                if enabled {
                    let service=SMAppService.agent(plistName:"pro.keybridge.pilot.agent.plist")
                    do { if service.status != .enabled && service.status != .requiresApproval { try service.register() } }
                    catch { updateStatus(["registrationError":error.localizedDescription]) }
                }
                result=engine.status();result["autostart"]=enabled;result["loginAccess"]=loginAccess()
            case "evidence":result=try engine.perform(["action":"licenseEvidence"])
            case "resources":result=try engine.perform(["action":"resources"])
            default:throw BridgeError("Неизвестная команда")
            }
            if !safety && !journal.isCurrent(token) { throw VMEngineError.cancelled }
            if !["probe","evidence","refresh-state"].contains(action) {
                var observation=engine.status();observation.removeValue(forKey:"lastProbe")
                updateStatus(observation)
            }
            response=["ok":true,"result":result,"resultState":"finished"]
        } catch {
            if let safety=error as? VMEngineError,case .safety=safety {
                authorization.set(false);try?intent?.hold()
                do { try engine.stop() } catch { updateStatus(["stopError":error.localizedDescription]) }
            }
            if !["configure","repair","restore","autostart"].contains(action) { invalidateProbe("Прежняя проба не подтверждает текущее окружение") }
            response=["ok":false,"error":error.localizedDescription,"resultState":journal.isCurrent(token) ? "failed":"cancelled"]
            var kind="operation"
            if let vmError=error as?VMEngineError {switch vmError {case .safety:kind="safety";case .cancelled:kind="cancelled";default:break}}
            updateStatus(["lastError":error.localizedDescription,"message":error.localizedDescription,"lastFailure":["action":action,"kind":kind,"message":error.localizedDescription]])
            if authorization.allowed,intent?.value.remaining == 0 {
                authorization.set(false);try?intent?.hold()
            }
        }
        journal.finish(token,response:response)
        if action != "reconcile" { complete(id,response) }
        let terminalResponse=response
        var terminal:[String:Any]=["busy":false,"operation":""]
        if !["health","reconcile"].contains(action) {terminal["lastOperation"]=action;terminal["lastOperationOK"]=response["ok"] as?Bool ?? false}
        updateStatus(terminal)
        DispatchQueue.main.async {
            for alias in stopAliases.removeValue(forKey:id) ?? [] {
                var response=terminalResponse
                if let error=stopWriteErrors.removeValue(forKey:alias) { response["ok"]=false;response["error"]="Остановка не сохранена: "+error }
                do { try journal.recordResponse(id:alias,action:"stop",response:response) } catch { updateStatus(["persistenceError":error.localizedDescription]) }
                complete(alias,response)
            }
            stopWriteErrors.removeValue(forKey:id)
            active=nil
            if action == "reconcile" { nextReconcileAt=Date().addingTimeInterval(5) }
            if action == "shutdown" || (exitRequested && pendingStops.isEmpty) { try?FileManager.default.removeItem(at:pidURL);exit(0) }
            processNext()
            if active==nil,reconcilePending { reconcilePending=false;_ = submit(["action":"reconcile"],internalRequest:true) }
        }
    }
    return true
}
@discardableResult func submit(_ request:[String:Any],internalRequest:Bool=false)->[String:Any] {
    let id=request["requestID"] as? String ?? UUID().uuidString
    let action=request["action"] as? String ?? ""
    if !internalRequest,snapshot.result(id).isEmpty {
        let record=readObject(runtime.appendingPathComponent("operations/"+id+".json"))
        let result=readObject(runtime.appendingPathComponent("results/"+id+".json"))
        if let terminal=record["response"] as? [String:Any] { snapshot.complete(id,terminal) }
        else if !result.isEmpty { snapshot.complete(id,result) }
    }
    if !snapshot.result(id).isEmpty || active?.id == id || pendingStops.contains(where:{$0.0==id}) || stopAliases.values.contains(where:{$0.contains(id)}) { return ["accepted":true,"requestID":id] }
    guard UUID(uuidString:id) != nil else { return ["accepted":false,"error":"Некорректный requestID"] }
    if exitRequested && action != "shutdown" { return ["accepted":false,"error":"Агент завершает работу"] }
    let safety=["stop","shutdown","session-stop"].contains(action)
    if !sessionActive && !safety { return ["accepted":false,"error":"Сеанс неактивен"] }
    if safety {
        if action != "session-stop" {
            authorization.set(false)
            do { guard let intent else { throw BridgeError("Хранилище намерения недоступно") };try intent.stop();updateStatus(["stopSaved":true,"stopPersistenceError":NSNull()]) }
            catch { stopWriteErrors[id]=error.localizedDescription;updateStatus(["stopSaved":false,"stopPersistenceError":error.localizedDescription]) }
        }
        do { try journal.receiveSafety(id:id,action:action) }
        catch { stopWriteErrors[id]=(stopWriteErrors[id] ?? "") + "; журнал приёма: " + error.localizedDescription }
        if let active, ["stop","shutdown","session-stop"].contains(active.action) {
            stopAliases[active.id,default:[]].append(id)
            // The alias is completed with the same response; it never restarts stop.
            return ["accepted":true,"requestID":id]
        }
        if let pending=pendingStops.first {
            stopAliases[pending.0,default:[]].append(id)
            return ["accepted":true,"requestID":id]
        }
        journal.invalidate();try?engine.requestCancellation()
        invalidateProbe("Принята остановка")
        if active != nil { pendingStops.append((id,request)) }
        else { begin(id,request,safety:true) }
        return ["accepted":true,"requestID":id]
    }
    if active != nil || !pendingStops.isEmpty {
        if internalRequest,active?.action != "reconcile" { reconcilePending=true }
        let response:[String:Any]=["ok":false,"error":"Контроллер занят; повторите после завершения операции","resultState":"rejected"]
        complete(id,response)
        return ["accepted":false,"requestID":id,"error":response["error"]!]
    }
    let admitted=begin(id,request)
    return ["accepted":admitted,"requestID":id,"error":admitted ? "":"Не удалось сохранить приём операции"]
}

engine.usbChanged={
    DispatchQueue.main.async {
        let connected=snapshot.status()["usbTransition"] as? String == "captured"
        invalidateProbe("Изменилось подключение USB")
        if connected,engine.status()["ownership"] as? String != "absent" {
            authorization.set(false)
            _ = submit(["action":"session-stop"],internalRequest:true)
            do { try intent?.hold() } catch { updateStatus(["persistenceError":error.localizedDescription]) }
        } else { reconcilePending=true }
    }
}
snapshot.replace(engine.status())
if intent != nil {snapshot.patch(["stopSaved":true])}
inspectClient()
for (id,response) in journal.recover() { complete(id,response) }
invalidateProbe("Агент запущен; прежнее подтверждение историческое")
let server=try AgentIPC.Server(runtime:runtime) { message in
    switch message["ipc"] as? String {
    case "status":return snapshot.status()
    case "result":return snapshot.result(message["requestID"] as? String ?? "")
    default:return DispatchQueue.main.sync { submit(message) }
    }
}
let currentSession=LoginSessionIdentity.current()
if let intent {
    let desired=intent.value
    let login=currentSession != nil && desired.sessionID != currentSession
    do {
        if let currentSession { try intent.update { $0.sessionID=currentSession } }
        if !desired.autoInhibit,clientManaged(),engine.status()["prepared"] as? Bool == true {
            if login {
                if desired.autostart && loginAccess()=="allowed" {
                    try intent.update { $0.want=true;$0.remaining=3 };authorization.set(true)
                }
            } else if desired.want { authorization.set(true) }
        }
    } catch { updateStatus(["persistenceError":error.localizedDescription]) }
}
updateStatus(["busy":false,"operation":""])
let poll=Timer.scheduledTimer(withTimeInterval:0.4,repeats:true) { _ in
    do {
        for (id,request) in try CommandQueue.take(runtime:runtime) {
            var value=request;value["requestID"]=id;_ = submit(value)
        }
    } catch { updateStatus(["persistenceError":error.localizedDescription]) }
}
var sources=[DispatchSourceSignal]()
for number in [SIGTERM,SIGINT,SIGHUP] {
    signal(number,SIG_IGN)
    let source=DispatchSource.makeSignalSource(signal:number,queue:.main)
    source.setEventHandler {
        if !exitRequested {
            _=submit(["action":"shutdown"],internalRequest:true);exitRequested=true
            DispatchQueue.global().asyncAfter(deadline:.now()+15) { engine.emergencyStop();exit(0) }
        }
    };source.resume();sources.append(source)
}
let notifications=NSWorkspace.shared.notificationCenter
let inactive=notifications.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main){_ in sessionActive=false;_ = submit(["action":"session-stop"],internalRequest:true)}
let sleeping=notifications.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){_ in sessionActive=false;_ = submit(["action":"session-stop"],internalRequest:true)}
let activeSession=notifications.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main){_ in sessionActive=true;if authorization.allowed {_ = submit(["action":"reconcile"],internalRequest:true)}}
let waking=notifications.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){_ in sessionActive=true;invalidateProbe("После пробуждения нужна новая проба");if authorization.allowed {_ = submit(["action":"reconcile"],internalRequest:true)}}
let health=Timer.scheduledTimer(withTimeInterval:5,repeats:true){_ in
    if authorization.allowed,sessionActive,!exitRequested,intent?.value.want == true,Date()>=nextReconcileAt { _ = submit(["action":"reconcile"],internalRequest:true) }
}
if authorization.allowed || engine.status()["ownership"] as? String != "absent" {
    _=submit(["action":"reconcile"],internalRequest:true)
}
RunLoop.main.run()
