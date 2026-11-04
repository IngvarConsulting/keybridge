// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import ServiceManagement
import CoreGraphics
import Darwin
import KeyBridgeCore

umask(0o077)
let runtime=BridgePaths.runtime
do { try InstalledApplication.requireCurrentBuild() }
catch { fputs(error.localizedDescription+"\n",stderr);exit(1) }
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
let controllerIntegrity=InstalledApplication.ControllerIntegrity(runtime:runtime)
let work=DispatchQueue(label:"pro.keybridge.agent.operations")
let statusURL=runtime.appendingPathComponent("status.json")
let probeURL=runtime.appendingPathComponent("probe.json")
let cancelURL=runtime.appendingPathComponent("cancel.request")
let activity=AgentActivity()
var active:OperationToken? { activity.current }
var pendingStops=[(String,[String:Any])]()
var pendingUser:(String,[String:Any])?
let sessionState=SessionAvailability()
var sessionActive:Bool { sessionState.state.active }
var exitRequested=false
var reconcilePending=false
let clientObservation=ClientObservation()
var nextClientObservationAt=Date.distantPast
var stopAliases=[String:[String]]()
var stopWriteErrors=[String:String]()

func loginAccess()->String {
    guard BridgePaths.loginLaunchSupported else { return "unsupported" }
    return LoginLaunch.access
}
func updateStatus(_ patch:[String:Any]) {
    statusWriteLock.lock();defer{statusWriteLock.unlock()}
    var observed=snapshot.status()
    observed.merge(patch) { _,new in new }
    var state=activity.applying(to:observed)
    state["updated"]=Date().timeIntervalSince1970
    state["agentPID"]=Int(getpid());state["agentIdentity"]=AgentIdentity.current ?? ""
    state["platformVersion"]=BridgePaths.version
    if let desired=intent?.value {
        state["autostart"]=desired.autostart;state["desiredRunning"]=desired.want
        state["autoInhibit"]=desired.autoInhibit;state["safetyReason"]=desired.safetyReason ?? "";state["remainingAttempts"]=desired.remaining
    }
    state["armed"]=authorization.allowed;state["loginLaunchSupported"]=BridgePaths.loginLaunchSupported
    let session=sessionState.state
    state["loginAccess"]=loginAccess();state["sessionActive"]=session.active
    state["sessionAvailability"]=session.availability.rawValue;state["sessionReason"]=session.reason
    state["reconciling"] = state["operation"] as? String == "reconcile" && state["busy"] as? Bool == true
        && !(engine.hasConnectionContext && state["ownership"] as?String == "owned" && ["running","waiting-key"].contains(state["status"] as?String ?? ""))
    if patch["resources"] != nil {state["resourcesSaveError"]=NSNull()}
    do { try writeObject(state,to:statusURL) }
    catch { if patch["resources"] != nil {state["resourcesSaveError"]=error.localizedDescription};state["persistenceError"]=error.localizedDescription;fputs("KeyBridge status: \(error.localizedDescription)\n",stderr) }
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
    let state=clientObservation.read()
    let old=snapshot.status()
    if !NSDictionary(dictionary:state).isEqual(to:old.filter { state[$0.key] != nil }) { updateStatus(state) }
    return state
}
func clientManaged()->Bool { inspectClient()["clientState"] as? String == "configured" }
func startPermitted(_ token:OperationToken) throws ->[String:Any] {
    try InstalledApplication.requireCurrentBuild()
    if let problem=controllerIntegrity.problem { throw BridgeError(problem) }
    guard authorization.allowed,sessionActive,let intent else { throw BridgeError("Запуск не разрешён текущим намерением") }
    try intent.validateSaved()
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
func recoverRuntime(_ token:OperationToken) throws -> [String:Any] {
    var request:[String:Any]=["action":"health"]
    while true {
        guard journal.isCurrent(token),authorization.allowed,sessionActive else { throw VMEngineError.cancelled }
        do { return try engine.perform(request) }
        catch let error as VMEngineError {
            switch error {
            case .channel:
                request=["action":"recover-channel"]
            case .services(let services):
                invalidateProbe("Изменилось состояние служб")
                request=["action":"recover-services","services":services]
            case .qmp:
                // Unknown USB control requires release before a new capture.
                invalidateProbe("Потерян контроль подключения USB")
                try engine.stop()
                return try startPermitted(token)
            default:throw error
            }
            guard let intent,intent.value.remaining>0 else {
                authorization.set(false)
                try? intent?.hold("Попытки восстановления исчерпаны")
                try engine.stop()
                throw BridgeError("Попытки восстановления исчерпаны. Работа остановлена; проверьте причину и включите явно.")
            }
            try journal.publish(token) { try intent.validateSaved();try intent.consumeAttempt() }
        }
    }
}
func saveProbe(_ result:[String:Any],to url:URL,_ token:OperationToken) throws -> [String:Any] {
    try journal.publish(token) {
        var observed=result
        do { try writeObject(result,to:url) }
        catch { observed["saved"]=false;observed["saveError"]=error.localizedDescription }
        return observed
    }
}
func runProbe(_ token:OperationToken) throws -> [String: Any] {
    guard authorization.allowed,sessionActive,intent?.value.inhibited == false,engine.status()["running"] as? Bool == true else { throw BridgeError("Сначала запустите раздачу") }
    guard let client=ClientInstallation.discover() else {throw BridgeError("Установите клиент 1С для macOS ARM64.")}
    let executable = try hostCommand("/usr/bin/file", ["-L", client.executable.path])
    guard executable.code == 0, executable.output.contains("arm64") else { throw BridgeError("Нужен установленный клиент 1С для macOS ARM64") }
    let folder = runtime.appendingPathComponent("probes/" + UUID().uuidString)
    try BridgePaths.preparePrivateDirectory(folder)
    let database = folder.appendingPathComponent("ib")
    let before = try engine.perform(["action": "licenseEvidence"])
    guard engine.status()["keyConnected"] as? Bool == true else {throw BridgeError("Для проверки в 1С требуется подтверждённое подключение ключа")}
    let create = try hostCommand("/usr/bin/arch", ["-arm64", client.executable.path, "CREATEINFOBASE", "File=\"\(database.path)\";", "/DisableStartupDialogs", "/DisableStartupMessages", "/Out", folder.appendingPathComponent("create.log").path], timeout: 120, log: folder.appendingPathComponent("create.stdout"), cancellation: cancelURL,isCancelled:{ !journal.isCurrent(token) })
    guard journal.isCurrent(token) else { throw VMEngineError.cancelled }
    if create.timedOut || create.code != 0 {
        let after = try engine.perform(["action": "licenseEvidence", "baseline": before])
        let result = LicenseEvidence.creationFailure(exitCode: create.code, timedOut: create.timedOut,
            context: after["context"] as? [String: Any] ?? [:])!
        let observed=try saveProbe(result,to:folder.appendingPathComponent("result.json"),token)
        try? FileManager.default.removeItem(at: database)
        return observed
    }
    if client.version.compare("8.5.4",options:.numeric) == .orderedAscending {
        // Older clients can perform the operation but cannot report its source.
        let cf=folder.appendingPathComponent("probe.cf"),resultFile=folder.appendingPathComponent("result.txt")
        defer { try?FileManager.default.removeItem(at:database);try?FileManager.default.removeItem(at:cf) }
        let run=try hostCommand("/usr/bin/arch",["-arm64",client.executable.path,"DESIGNER","/F",database.path,
            "/DisableStartupDialogs","/DisableStartupMessages","/DumpCfg",cf.path,"/DumpResult",resultFile.path,
            "/Out",folder.appendingPathComponent("client.log").path],timeout:120,log:folder.appendingPathComponent("client.stdout"),
            cancellation:cancelURL,isCancelled:{ !journal.isCurrent(token) })
        guard journal.isCurrent(token) else {throw VMEngineError.cancelled}
        let output=((try?String(contentsOf:resultFile,encoding:.utf8)) ?? "").replacingOccurrences(of:"\u{feff}",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
        let succeeded=run.code==0 && !run.timedOut && output=="0" && ((try?Data(contentsOf:cf).count) ?? 0)>0
        let after=try engine.perform(["action":"licenseEvidence"])
        let result:[String:Any]=["success":false,"result":LicenseEvidence.probeOutcome(clientSucceeded:succeeded,timedOut:run.timedOut),
            "clientOperationSucceeded":succeeded,"timedOut":run.timedOut,"timestamp":Date().timeIntervalSince1970,
            "contextAfter":after["context"] ?? [:],"message":"Эта версия 1С не предоставляет сведения об источнике лицензии проверяемой операции."]
        return try saveProbe(result,to:folder.appendingPathComponent("result.json"),token)
    }
    let processor=folder.appendingPathComponent("probe.epf")
    defer { try?FileManager.default.removeItem(at:database);try?FileManager.default.removeItem(at:processor) }
    let source=BridgePaths.resources.appendingPathComponent("probe/LicenseProbe.xml")
    let compiled=try hostCommand("/usr/bin/arch",["-arm64",client.executable.path,"DESIGNER",
        "/LoadExternalDataProcessorOrReportFromFiles",source.path,processor.path,"/DisableStartupDialogs","/DisableStartupMessages",
        "/Out",folder.appendingPathComponent("compile.log").path],timeout:120,log:folder.appendingPathComponent("compile.stdout"),
        cancellation:cancelURL,isCancelled:{ !journal.isCurrent(token) })
    guard journal.isCurrent(token) else {throw VMEngineError.cancelled}
    if compiled.code != 0 || compiled.timedOut || !FileManager.default.fileExists(atPath:processor.path) {
        let result:[String:Any]=["success":false,"result":compiled.timedOut ? "timeout":"failure","stage":"compile",
            "clientOperationSucceeded":false,"timestamp":Date().timeIntervalSince1970,
            "message":"Клиент 1С не подготовил проверку источника лицензии. Проверьте совместимость установленной версии и повторите проверку."]
        return try saveProbe(result,to:folder.appendingPathComponent("result.json"),token)
    }
    let receiptURL=folder.appendingPathComponent("client-receipt.json")
    let started=Date().timeIntervalSince1970
    let run=try hostCommand("/usr/bin/arch",["-arm64",client.executable.path,"ENTERPRISE","/F",database.path,
        "/RunModeManagedApplication","/Execute",processor.path,"/C",receiptURL.path,
        "/DisableStartupDialogs","/DisableStartupMessages","/Out",folder.appendingPathComponent("client.log").path],
        timeout:120,log:folder.appendingPathComponent("client.stdout"),cancellation:cancelURL,isCancelled:{ !journal.isCurrent(token) })
    guard journal.isCurrent(token) else {throw VMEngineError.cancelled}
    let receipt=readObject(receiptURL)
    let after=try engine.perform(["action":"licenseEvidence"])
    let contextBefore=before["context"] as? [String:Any] ?? [:]
    let contextAfter=after["context"] as? [String:Any] ?? [:]
    let contextStable = !contextBefore.isEmpty && NSDictionary(dictionary:contextBefore).isEqual(to:contextAfter)
    let clientSucceeded=run.code==0 && !run.timedOut && receipt["source"] as? String == "platform-license-monitoring"
    let sourceConfirmed=LicenseEvidence.confirmsHardwareSource(receipt:receipt,database:database,processID:run.processID)
    let confirmed=clientSucceeded && contextStable && sourceConfirmed
    let kind=confirmed ? "success":LicenseEvidence.probeOutcome(clientSucceeded:clientSucceeded,timedOut:run.timedOut)
    let result:[String:Any]=["success":confirmed,"result":kind,"timedOut":run.timedOut,
        "clientOperationSucceeded":clientSucceeded,"causalIsolation":sourceConfirmed,"contextStable":contextStable,
        "contextBefore":contextBefore,"contextAfter":contextAfter,"evidenceMethod":"client-license-monitoring",
        "timestamp":Date().timeIntervalSince1970,"started":started,"exitCode":run.code,"version":client.version,
        "message":confirmed ? "1С получила аппаратную лицензию через KeyBridge.":clientSucceeded ? "Операция 1С выполнена. Источник лицензии не подтверждён.":"Операция 1С не завершилась успешно."]
    return try saveProbe(result,to:folder.appendingPathComponent("result.json"),token)
}
func processNext() {
    guard active==nil else { return }
    if !pendingStops.isEmpty {
        let (id,request)=pendingStops.removeFirst()
        begin(id,request,safety:true)
    } else if let (id,request)=pendingUser {
        pendingUser=nil
        updateStatus(["pendingDiagnostic":NSNull()])
        let receipt=submit(request)
        if receipt["accepted"] as? Bool != true {
            let response:[String:Any]=["ok":false,"resultState":"failed","error":receipt["error"] ?? "Состояние изменилось. Повторите действие."]
            try? journal.recordResponse(id:id,action:request["action"] as? String ?? "",response:response)
            complete(id,response)
        }
    }
}
func cancelPendingUser() {
    guard let (id,request)=pendingUser else { return }
    pendingUser=nil
    updateStatus(["pendingDiagnostic":NSNull()])
    let response:[String:Any]=["ok":false,"resultState":"cancelled","error":"Действие отменено: принята остановка или изменились условия безопасности."]
    try? journal.recordResponse(id:id,action:request["action"] as? String ?? "",response:response)
    complete(id,response)
}
@discardableResult func begin(_ id:String,_ request:[String:Any],safety:Bool=false) -> Bool {
    let action=request["action"] as? String ?? ""
    let token:OperationToken
    do { token=try journal.begin(id:id,action:action,safety:safety) }
    catch { complete(id,["ok":false,"error":error.localizedDescription]);return false }
    activity.begin(token)
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
        var safetyFailed=false
        var needsRecovery=false
        do {
            var result:[String:Any]
            switch action {
            case "start":
                let before=engine.status()
                guard before["prepared"] as? Bool == true else { throw BridgeError("Сначала подготовьте пригодную среду") }
                guard before["ownership"] as? String != "unknown" else { throw VMEngineError.safety("Принадлежность VM неизвестна") }
                guard clientManaged() else { throw BridgeError("Сначала подключите 1С в настройках") }
                try journal.publish(token) {
                    guard let intent else { throw BridgeError("Намерение недоступно: запуск запрещён") }
                    try intent.start();authorization.set(true)
                }
                invalidateProbe("После запуска нужна новая проверка")
                result=try startPermitted(token)
                do { try journal.publish(token) { try intent?.clearSafetyAfterVerification() } }
                catch { authorization.set(false);try engine.stop();throw error }
            case "prepare","rollback":
                try journal.publish(token) {
                    guard let intent else { throw BridgeError("Намерение недоступно") };try intent.prepare();authorization.set(false)
                }
                invalidateProbe("После смены поколения нужна новая проверка")
                result=try engine.perform(request)
            case "stop","shutdown","session-stop","session-shutdown":
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
                    result=try recoverRuntime(token)
                }
                if result["keyConnected"] as? Bool != true { invalidateProbe("Ключ не подтверждён") }
            case "probe":
                guard clientManaged() else { throw BridgeError("Сначала подключите локальную 1С в настройках") }
                let probe=try saveProbe(try runProbe(token),to:probeURL,token)
                try journal.publish(token) { updateStatus(["lastProbe":probe]) }
                result=probe
            case "configure","repair","restore":
                try configureClient(action == "configure" ? "apply":action == "repair" ? "repair":"restore",token)
                result=engine.status();result.merge(inspectClient()){_,new in new}
            case "inspect":
                do { result=try engine.perform(["action":"inspect"]) }
                catch let error as VMEngineError {
                    guard authorization.allowed else {throw error}
                    switch error {case .channel,.services,.qmp:result=try recoverRuntime(token);default:throw error}
                }
                result.merge(inspectClient()){_,new in new}
                updateStatus(result)
            case "refresh-state":
                result=engine.status();result.merge(inspectClient()){_,new in new}
                if result["ownership"] as? String == "absent" {result["status"]=result["prepared"] as? Bool == true ? "stopped":"unprepared";result["keyConnected"]=false;updateStatus(result)}
            case "autostart":
                guard let enabled=request["enabled"] as? Bool,let intent else { throw BridgeError("Настройка автозапуска не задана") }
                try LoginLaunch.setEnabled(enabled, intent:intent, publish: { try journal.publish(token,$0) })
                updateStatus(["registrationError":NSNull()])
                result=engine.status();result["autostart"]=enabled;result["loginAccess"]=loginAccess()
            case "evidence":result=try engine.perform(["action":"licenseEvidence"])
            case "resources":result=try engine.perform(["action":"resources"])
            default:throw BridgeError("Неизвестная команда")
            }
            if !safety && !journal.isCurrent(token) { throw VMEngineError.cancelled }
            if !["probe","evidence","refresh-state"].contains(action) {
                var observation=result["ownership"] != nil ? result : engine.status();observation.removeValue(forKey:"lastProbe")
                updateStatus(observation)
            }
            response=["ok":true,"result":result,"resultState":"finished"]
        } catch {
            if let safety=error as? VMEngineError,case .safety=safety {
                safetyFailed=true
                authorization.set(false);try?intent?.hold(error.localizedDescription)
                do { try engine.stop() } catch { updateStatus(["stopError":error.localizedDescription]) }
            }
            if let vmError=error as? VMEngineError,case .qmp=vmError {
                invalidateProbe("Потерян контроль подключения USB")
                do { try engine.stop();needsRecovery=authorization.allowed && sessionActive }
                catch { authorization.set(false);updateStatus(["stopError":error.localizedDescription]) }
            }
            if action=="start",intent?.value.safetyReason != nil {authorization.set(false)}
            if ["start","prepare","rollback","stop","shutdown","session-stop","session-shutdown","health","refresh-key","reconcile"].contains(action) || safetyFailed { invalidateProbe("Прежняя проба не подтверждает текущее окружение") }
            response=["ok":false,"error":error.localizedDescription,"resultState":journal.isCurrent(token) ? "failed":"cancelled"]
            var kind="operation"
            if let vmError=error as?VMEngineError {switch vmError {case .safety:kind="safety";case .cancelled:kind="cancelled";default:break}}
            updateStatus(["lastError":error.localizedDescription,"message":error.localizedDescription,"lastFailure":["action":action,"kind":kind,"message":error.localizedDescription]])
        }
        let finishedResponse=response
        let terminalSafetyFailed=safetyFailed
        let terminalNeedsRecovery=needsRecovery
        DispatchQueue.main.async {
            // The main queue owns admission. Neither status nor a durable
            // result may announce completion while its slot is still occupied.
            var terminalResponse=finishedResponse
            if !safety && !journal.isCurrent(token) {
                terminalResponse=["ok":false,"resultState":"cancelled","error":"Операция отменена; поздний результат не принят"]
            }
            if let error=journal.finish(token,response:terminalResponse,beforePublishing:{ activity.finish(token) }) {
                terminalResponse["saved"]=false;terminalResponse["saveError"]=error
                let diagnostic=["probe","resources","inspect","evidence","refresh-state"].contains(action)
                if !diagnostic {
                    terminalResponse["ok"]=false;terminalResponse["resultState"]="unsaved"
                    terminalResponse["error"]="Результат действия не сохранён: "+error
                    let actual=engine.status()
                    updateStatus(actual)
                    // A confirmed physical stop is valid even when its record is lost.
                    // Continuing work requires both saved intent and fresh safe facts.
                    let safe=actual["ownership"] as? String == "absent" ||
                        ((try?intent?.validateSaved()) != nil && authorization.allowed &&
                         ["running","waiting-key"].contains(actual["status"] as? String ?? ""))
                    if !safe {
                        authorization.set(false);cancelPendingUser()
                        _=submit(["action":"session-stop"],internalRequest:true)
                    }
                }
                updateStatus(["persistenceError":error])
            }
            if terminalSafetyFailed { cancelPendingUser() }
            if terminalNeedsRecovery { reconcilePending=true }
            var stopCompleted=terminalResponse["ok"] as? Bool == true
            var aliases=[(String,[String:Any])]()
            for alias in stopAliases.removeValue(forKey:id) ?? [] {
                var response=terminalResponse
                if let error=stopWriteErrors.removeValue(forKey:alias) { response["ok"]=false;response["error"]="Остановка не сохранена: "+error }
                do { try journal.recordResponse(id:alias,action:"stop",response:response) } catch { updateStatus(["persistenceError":error.localizedDescription]) }
                aliases.append((alias,response))
                stopCompleted=stopCompleted && response["ok"] as? Bool == true
            }
            stopWriteErrors.removeValue(forKey:id)
            let shouldExit=exitRequested && pendingStops.isEmpty && stopCompleted
            if !shouldExit {
                processNext()
                if active==nil,reconcilePending { reconcilePending=false;_ = submit(["action":"reconcile"],internalRequest:true) }
            }
            var terminal=[String:Any]()
            if !["health","reconcile"].contains(action) {terminal["lastOperation"]=action;terminal["lastOperationOK"]=terminalResponse["ok"] as?Bool ?? false}
            updateStatus(terminal)
            if action != "reconcile" { complete(id,terminalResponse) }
            for (alias,response) in aliases { complete(alias,response) }
            if shouldExit { try?FileManager.default.removeItem(at:pidURL);exit(0) }
        }
    }
    return true
}
func refreshSession(_ event: SessionAvailability.Event = .poll,resume: Bool = true) {
    let change=sessionState.observe(event)
    guard change.changed else { return }
    updateStatus([:])
    if !change.after.active {
        if change.before.active || event == .willSleep || event == .willResignActive {
            invalidateProbe("Сеанс macOS больше не подтверждает работу с ключом")
            _=submit(["action":"session-stop"],internalRequest:true)
        }
    } else if resume && !exitRequested && change.after.permitsAutomaticResume(authorized:authorization.allowed,
        wantsRunning:intent?.value.want == true,inhibited:intent?.value.inhibited != false) {
        _=submit(["action":"reconcile"],internalRequest:true)
    }
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
    if !snapshot.result(id).isEmpty || active?.id == id || pendingUser?.0 == id || pendingStops.contains(where:{$0.0==id}) || stopAliases.values.contains(where:{$0.contains(id)}) { return ["accepted":true,"requestID":id] }
    guard UUID(uuidString:id) != nil else { return ["accepted":false,"error":"Некорректный requestID"] }
    guard ["prepare","rollback","start","stop","shutdown","session-stop","session-shutdown","health","refresh-key","reconcile","probe","configure","repair","restore","inspect","refresh-state","autostart","evidence","resources"].contains(action) else {
        return ["accepted":false,"error":"Неизвестная команда"]
    }
    let stopAction=AgentStopAction(rawValue:action)
    if stopAction == nil {
        refreshSession(resume:false)
        do {
            try InstalledApplication.requireCurrentBuild()
            if let problem=controllerIntegrity.problem { throw BridgeError(problem) }
            try intent?.validateSaved()
        }
        catch { return ["accepted":false,"error":error.localizedDescription] }
    }
    if exitRequested && stopAction == nil { return ["accepted":false,"error":"Агент завершает работу"] }
    let safety=stopAction != nil
    if !sessionActive && !safety { return ["accepted":false,"error":"Сеанс неактивен"] }
    if safety {
        cancelPendingUser()
        if stopAction?.exitsAgent == true {
            exitRequested=true
            authorization.set(false)
        }
        if stopAction?.savesStopIntent == true {
            authorization.set(false)
            do { guard let intent else { throw BridgeError("Хранилище намерения недоступно") };try intent.stop();updateStatus(["stopSaved":true,"stopPersistenceError":NSNull()]) }
            catch { stopWriteErrors[id]=error.localizedDescription;updateStatus(["stopSaved":false,"stopPersistenceError":error.localizedDescription]) }
        }
        do { try journal.receiveSafety(id:id,action:action) }
        catch { stopWriteErrors[id]=(stopWriteErrors[id] ?? "") + "; журнал приёма: " + error.localizedDescription }
        if let active, AgentStopAction(rawValue:active.action) != nil {
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
    if action == "autostart" {
        // Independent preference: it neither enters the VM queue nor cancels it.
        do {
            guard let enabled=request["enabled"] as? Bool,let intent else { throw BridgeError("Настройка автозапуска не задана") }
            try journal.receive(id:id,action:action)
            try intent.validateSaved()
            try LoginLaunch.setEnabled(enabled,intent:intent)
            var response:[String:Any]=["ok":true,"resultState":"finished"]
            do { try journal.recordResponse(id:id,action:action,response:response) }
            catch { response["saved"]=false;response["saveError"]=error.localizedDescription }
            updateStatus([:]);complete(id,response)
            return ["accepted":true,"requestID":id]
        } catch {
            complete(id,["ok":false,"resultState":"failed","error":error.localizedDescription])
            return ["accepted":false,"requestID":id,"error":error.localizedDescription]
        }
    }
    if active != nil || !pendingStops.isEmpty {
        if internalRequest {
            if active?.action != "reconcile" { reconcilePending=true }
            return ["accepted":false,"deferred":true]
        }
        if AgentAdmission.canWait(action:action,active:active?.action,pending:pendingUser != nil,stopping:!pendingStops.isEmpty),
           action != "probe" || (authorization.allowed && snapshot.status()["keyConnected"] as? Bool == true && clientManaged()) {
            do { try journal.receive(id:id,action:action) }
            catch { return ["accepted":false,"error":error.localizedDescription] }
            pendingUser=(id,request.merging(["requestID":id]) { _,new in new })
            updateStatus(["pendingDiagnostic":action])
            return ["accepted":true,"requestID":id,"queued":true]
        }
        let response:[String:Any]=["ok":false,"error":"Контроллер занят; повторите после завершения операции","resultState":"rejected"]
        complete(id,response)
        return ["accepted":false,"requestID":id,"error":response["error"]!]
    }
    let admitted=begin(id,request)
    return ["accepted":admitted,"requestID":id,"error":admitted ? "":"Не удалось сохранить приём операции"]
}

func runtimeChanged(usb:Bool) {
    DispatchQueue.main.async {
        invalidateProbe(usb ? "Изменилось подключение USB":"Изменилось состояние VM или служб")
        if usb {
            do { _=try engine.usbObservation() }
            catch {
                authorization.set(false)
                try?intent?.hold(error.localizedDescription)
                updateStatus(["lastFailure":["kind":"safety","action":"inspect","message":error.localizedDescription]])
                _=submit(["action":"session-stop"],internalRequest:true)
                return
            }
        }
        guard authorization.allowed,sessionActive,!exitRequested,intent?.value.want == true else { return }
        if active != nil {
            // A probe with changed context cannot publish. Reconcile only after
            // the interrupted worker relinquishes the engine.
            if active?.action == "probe" { journal.invalidate();try?engine.requestCancellation() }
            reconcilePending=true
        } else { _=submit(["action":"reconcile"],internalRequest:true) }
    }
}
engine.usbChanged={ runtimeChanged(usb:true) }
engine.runtimeChanged={ runtimeChanged(usb:false) }
snapshot.replace(engine.status())
if intent != nil {snapshot.patch(["stopSaved":true])}
inspectClient()
for (id,response) in journal.recover() { complete(id,response) }
invalidateProbe("Агент запущен; прежнее подтверждение историческое")
let server=try AgentIPC.Server(runtime:runtime) { message in
    switch message["ipc"] as? String {
    case "status":return snapshot.status()
    case "result":return snapshot.result(message["requestID"] as? String ?? "")
    case "cancel":return DispatchQueue.main.sync {
        let id=message["requestID"] as? String ?? ""
        if pendingUser?.0==id {cancelPendingUser();return ["cancelled":true]}
        if let active,active.id==id,AgentStopAction(rawValue:active.action)==nil {
            journal.invalidate();try?engine.requestCancellation()
            return ["cancelled":true]
        }
        return ["cancelled":false]
    }
    default:return DispatchQueue.main.sync { submit(message) }
    }
}
let currentSession=LoginSessionIdentity.current()
if let intent {
    let desired=intent.value
    let login=currentSession != nil && desired.sessionID != currentSession
    do {
        if let currentSession { try intent.update { $0.sessionID=currentSession } }
        if !desired.inhibited,clientManaged(),engine.status()["prepared"] as? Bool == true {
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
    refreshSession()
    if Date()>=nextClientObservationAt {
        let before=snapshot.status(),after=inspectClient()
        nextClientObservationAt=Date().addingTimeInterval(1)
        if (before["clientRevision"] as? String != after["clientRevision"] as? String ||
            before["clientState"] as? String != after["clientState"] as? String),
           authorization.allowed,sessionActive,!exitRequested,intent?.value.want == true {
            if active != nil { reconcilePending=true }
            else { _=submit(["action":"reconcile"],internalRequest:true) }
        }
    }
    let savedIntentProblem:String? = {
        do { try intent?.validateSaved();return nil }
        catch { return error.localizedDescription }
    }()
    if !exitRequested,let problem=controllerIntegrity.problem ?? savedIntentProblem {
        authorization.set(false)
        // Revoke publication before holding: a completing start must not clear
        // the new safety reason after its own verification.
        journal.invalidate()
        // A missing/replaced controller requires a durable safety stop, not
        // session suspension. Preserve externally changed runtime data instead
        // of writing our cached intent over it.
        if controllerIntegrity.runtimeUnchanged,savedIntentProblem == nil {
            do { try intent?.hold(problem) }
            catch { updateStatus(["persistenceError":error.localizedDescription]) }
        }
        updateStatus(["controllerIntegrityError":problem])
        _=submit(["action":"session-shutdown"],internalRequest:true)
        return
    }
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
            _=submit(["action":"session-shutdown"],internalRequest:true)
            DispatchQueue.global().asyncAfter(deadline:.now()+15) { engine.emergencyStop();exit(0) }
        }
    };source.resume();sources.append(source)
}
let notifications=NSWorkspace.shared.notificationCenter
let inactive=notifications.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main){_ in refreshSession(.willResignActive)}
let sleeping=notifications.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){_ in refreshSession(.willSleep)}
let activeSession=notifications.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main){_ in refreshSession(.didBecomeActive)}
let waking=notifications.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){_ in invalidateProbe("После пробуждения нужна новая проба");refreshSession(.didWake)}
if !sessionActive && engine.status()["ownership"] as? String != "absent" {
    _=submit(["action":"session-stop"],internalRequest:true)
} else if authorization.allowed || engine.status()["ownership"] as? String != "absent" {
    _=submit(["action":"reconcile"],internalRequest:true)
}
RunLoop.main.run()
