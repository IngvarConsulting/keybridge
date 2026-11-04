// SPDX-License-Identifier: MIT
import Foundation
import ServiceManagement
import KeyBridgeCore
import Darwin

let runtime = BridgePaths.runtime
let arguments = Array(CommandLine.arguments.dropFirst())
let action = arguments.first ?? "status"
func option(_ name: String) -> String? { guard let i = arguments.firstIndex(of: name), i+1 < arguments.count else { return nil }; return arguments[i+1] }
func agentProcess() -> (Int32, URL)? {
    let pidURL = runtime.appendingPathComponent("agent.pid")
    guard let string = try? String(contentsOf: pidURL),
          let pid = Int32(string.trimmingCharacters(in: .whitespacesAndNewlines)),
          let path = AgentIdentity.processPath(pid), AgentIdentity.isAgentExecutable(path) else { return nil }
    return (pid, path)
}
@discardableResult func ensureAgent(allowPreviousForStop: Bool = false) throws -> Int32 {
    if !allowPreviousForStop { try InstalledApplication.requireCurrentBuild() }
    let expected = BridgePaths.executableDirectory.appendingPathComponent("KeyBridgeAgent").resolvingSymlinksInPath()
    if let (pid, path) = agentProcess() {
        if allowPreviousForStop { return pid }
        guard path == expected else { throw BridgeError(AgentIdentity.restartMessage) }
        if let status = try? AgentIPC.exchange(runtime:runtime,message:["ipc":"status"]) {
            guard AgentIdentity.matches(status:status,pid:pid,path:path,executableDirectory:BridgePaths.executableDirectory) else {
                throw BridgeError(AgentIdentity.restartMessage)
            }
            return pid
        }
    }
    try InstalledApplication.requireCurrentBuild()
    guard FileManager.default.isExecutableFile(atPath:expected.path) else { throw BridgeError("Установленная копия KeyBridge удалена или заменена. Откройте полное приложение и повторите действие.") }
    let logURL = runtime.appendingPathComponent("agent.log")
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    let log = try FileHandle(forWritingTo: logURL); try log.seekToEnd()
    let p = Process(); p.executableURL = BridgePaths.executableDirectory.appendingPathComponent("KeyBridgeAgent")
    p.standardOutput = log; p.standardError = log; p.standardInput = FileHandle.nullDevice
    try p.run(); try? log.close()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let (pid, path) = agentProcess() {
            guard path == expected else { throw BridgeError(AgentIdentity.restartMessage) }
            if let status = try? AgentIPC.exchange(runtime:runtime,message:["ipc":"status"]) {
                guard AgentIdentity.matches(status:status,pid:pid,path:path,executableDirectory:BridgePaths.executableDirectory) else {
                    throw BridgeError(AgentIdentity.restartMessage)
                }
                return pid
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw BridgeError("KeyBridge не получил ответ фоновой программы. Закройте и снова откройте приложение, затем повторите действие.")
}

/// A system-exit request must never bootstrap a new agent merely to stop it.
/// The agent lock also covers its startup interval before agent.pid is written.
func sessionAgentOrConfirmedAbsence() throws -> Int32? {
    if !FileManager.default.fileExists(atPath:runtime.path) {
        let observation=RuntimeOwnership.observation(runtime:runtime)
        guard observation["ownership"] as? String == "absent",observation["running"] as? Bool == false else { throw BridgeError("Остановка работы с ключом не подтверждена; данные приложения отсутствуют.") }
        return nil
    }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let (pid, _) = agentProcess() { return pid }
        let descriptor = open(runtime.appendingPathComponent("agent.lock").path, O_CREAT|O_RDWR|O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BridgeError("Не удалось проверить завершение фоновой программы KeyBridge.") }
        if flock(descriptor, LOCK_EX|LOCK_NB) == 0 {
            defer { flock(descriptor, LOCK_UN);close(descriptor) }
            let observation = RuntimeOwnership.observation(runtime:runtime)
            guard observation["ownership"] as? String == "absent", observation["running"] as? Bool == false else {
                throw BridgeError("Не удалось подтвердить освобождение USB-ключа. Откройте KeyBridge и повторите выключение.")
            }
            return nil
        }
        close(descriptor)
        Thread.sleep(forTimeInterval:0.1)
    }
    throw BridgeError("Фоновая программа KeyBridge не ответила при завершении сеанса. Повторите завершение после выключения KeyBridge.")
}
/// Explicit Stop remains meaningful before any agent has run. Persist its
/// inhibit under the agent and commit locks without bootstrapping a service.
func stopWithoutAgentIfPossible(saveIntent:Bool = true) throws -> [String:Any]? {
    guard agentProcess() == nil else { return nil }
    try BridgePaths.preparePrivateDirectory(runtime)
    let agentLock=open(runtime.appendingPathComponent("agent.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
    guard agentLock>=0 else { throw BridgeError("Не удалось проверить отсутствие фоновой программы KeyBridge.") }
    defer { close(agentLock) }
    guard flock(agentLock,LOCK_EX|LOCK_NB)==0 else { return nil }
    defer { flock(agentLock,LOCK_UN) }
    guard agentProcess() == nil else { return nil }
    let engine=VMEngine(runtime:runtime,resources:BridgePaths.resources)
    var saved = !saveIntent
    let errors=StopTransaction.perform(persist:{
        guard saveIntent else {return}
        let commit=open(runtime.appendingPathComponent("commit.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard commit>=0 else { throw BridgeError("Не удалось открыть сохранение выключения") }
        defer { close(commit) }
        guard flock(commit,LOCK_EX)==0 else { throw BridgeError("Не удалось согласовать выключение") }
        defer { flock(commit,LOCK_UN) }
        try IntentStore(runtime:runtime).stop();saved=true
    },stop:{ try engine.stop() })
    let actual=engine.status()
    guard errors.isEmpty,actual["ownership"] as? String == "absent" else {
        throw BridgeError(errors.isEmpty ? "Остановка собственной VM не подтверждена":errors.joined(separator:"; "))
    }
    return ["ok":true,"alreadyStopped":true,"agentExited":true,"ownership":"absent","running":false,"stopSaved":saved]
}
do {
    umask(0o077)
    if action == "inspect-import" {
        guard let kind=option("--kind"),let path=option("--path") else {throw BridgeError("Укажите тип и путь установщика.")}
        func inspectSelection() throws -> [String:Any] {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keybridge-inspection-"+UUID().uuidString)
            try BridgePaths.preparePrivateDirectory(directory)
            defer { try? FileManager.default.removeItem(at:directory) }
            let parent=getppid()
            let cancelled={ getppid() != parent }
            let candidates=try ImportArchive.resolve(URL(fileURLWithPath:path),kind:kind,directory:directory.appendingPathComponent("files"),cancelled:cancelled)
            let index=option("--candidate").flatMap(Int.init)
            if candidates.count>1 && index == nil {
                return ["ok":true,"valid":false,"candidates":candidates.map(\.displayName),"message":"В архиве несколько подходящих файлов. Выберите нужный компонент."]
            }
            guard let candidate=(index ?? 0)<candidates.count && (index ?? 0)>=0 ? candidates[index ?? 0] : nil else {throw BridgeError("Выбранный компонент не найден в архиве.")}
            var result=try ImportInspection.inspect(candidate,kind:kind,resources:BridgePaths.resources,workspace:directory.appendingPathComponent("preflight"),cancelled:cancelled)
            result.removeValue(forKey:"resolvedPath")
            result["sourceName"]=URL(fileURLWithPath:path).lastPathComponent
            result["ok"]=true
            return result
        }
        let result=try inspectSelection()
        print(jsonText(result));exit(0)
    }
    if action == "client-status" {
        let helper=BridgePaths.executableDirectory.appendingPathComponent("KeyBridgeConfigure")
        let result=try hostCommand(helper.path,["inspect"],timeout:15)
        guard result.code==0,let data=result.output.data(using:.utf8),let state=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw BridgeError("Не удалось проверить настройки клиента 1С.")}
        print(jsonText(state));exit(0)
    }
    if action == "check-space" {
        let space=try RuntimeResources.preparationSpace(runtime:runtime,resources:BridgePaths.resources,installer:option("--installer").map{URL(fileURLWithPath:$0)},driver:option("--driver").map{URL(fileURLWithPath:$0)})
        print(jsonText(space));exit(0)
    }
    if action == "ensure-agent" {
        try InstalledApplication.requireCurrentBuild()
        try InstalledApplication.validateRuntime(runtime)
        try BridgePaths.preparePrivateDirectory(runtime)
        let pid = try ensureAgent()
        print(jsonText(["ok":true,"agentPID":Int(pid)]));exit(0)
    }
    if action == "status" {
        if let live=try?AgentIPC.exchange(runtime:runtime,message:["ipc":"status"]) { print(jsonText(live));exit(0) }
        var state = readObject(runtime.appendingPathComponent("status.json"))
        state["lastProbe"] = readObject(runtime.appendingPathComponent("probe.json"))
        state["autostart"] = readObject(runtime.appendingPathComponent("intent.json"))["autostart"] ?? false
        state["stale"]=true
        state["lastProbe"]=["result":"unknown","success":false,"message":"Агент недоступен; состояние историческое"]
        print(jsonText(state)); exit(0)
    }
    if action == "monitor" {
        guard let client=ClientInstallation.discover() else {throw BridgeError("Клиент 1С не найден. Установите его и повторите открытие монитора.")}
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/arch")
        p.arguments=["-arm64",client.executable.path,"ENTERPRISE","/ManageLicenses"]
        p.standardInput=FileHandle.nullDevice;p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try p.run()
        let deadline=Date().addingTimeInterval(2)
        while p.isRunning && Date()<deadline { Thread.sleep(forTimeInterval:0.05) }
        if !p.isRunning,p.terminationStatus != 0 {throw BridgeError("1С завершила запуск монитора с ошибкой. Повторите открытие или проверьте лицензию в своей базе.")}
        // A running process cannot prove either a visible window or license data.
        print(jsonText(["ok":false,"launched":true,"resultState":"unknown", "error":"Запуск передан в 1С, но открытие монитора и получение данных не подтверждены. Проверьте окно 1С; доступны повтор и инструкция проверки в своей базе."]))
        exit(0)
    }
    guard ["prepare", "start", "stop", "probe", "shutdown", "session-shutdown", "evidence", "refresh-key", "resources", "rollback", "configure", "repair", "restore", "autostart", "refresh-state", "inspect"].contains(action) else { throw BridgeError("Неизвестная команда") }
    if ["stop","shutdown","session-shutdown"].contains(action),let result=try stopWithoutAgentIfPossible(saveIntent:action != "session-shutdown") {
        print(jsonText(result));exit(0)
    }
    if AgentStopAction(rawValue:action) == nil {
        try InstalledApplication.requireCurrentBuild()
        try InstalledApplication.validateRuntime(runtime)
        try BridgePaths.preparePrivateDirectory(runtime)
    }
    var request: [String: Any] = ["action": action,"requestID":UUID().uuidString]
    if action == "prepare" {
        guard let installer = option("--installer"), let driver = option("--driver") else { throw BridgeError("Выберите установщик 1С .run и драйвер .deb") }
        request["installer"] = URL(fileURLWithPath: installer).standardizedFileURL.path
        request["driver"] = URL(fileURLWithPath: driver).standardizedFileURL.path
    }
    if action == "rollback",let generation=option("--generation") {
        _=generation
        throw BridgeError("Возврат допускается только к предыдущей установке; параметр --generation не поддерживается")
    }
    if action == "autostart" {
        guard let mode=arguments.dropFirst().first,["on","off"].contains(mode) else { throw BridgeError("Укажите autostart on/off") }
        try ApplicationCapabilities.requireLoginLaunch(mode == "on")
        request["enabled"] = mode == "on"
    }
    let agentPID: Int32
    if action == "session-shutdown" {
        guard let pid = try sessionAgentOrConfirmedAbsence() else {
            print(jsonText(["ok":true,"alreadyStopped":true,"agentExited":true,"ownership":"absent","running":false]));exit(0)
        }
        agentPID=pid
    } else { agentPID=try ensureAgent(allowPreviousForStop:AgentStopAction(rawValue:action) != nil) }
    let receipt:[String:Any]
    do { receipt=try AgentIPC.exchange(runtime:runtime,message:request) }
    catch {
        if AgentStopAction(rawValue:action) == nil { try InstalledApplication.requireCurrentBuild() }
        guard FileManager.default.fileExists(atPath:runtime.path) else { throw BridgeError("Данные KeyBridge отсутствуют. Очередь команд не создана; откройте установленное приложение и проверьте состояние.") }
        let id=try CommandQueue.enqueue(request,runtime:runtime);receipt=["accepted":true,"requestID":id]
    }
    guard receipt["accepted"] as? Bool == true,let id=receipt["requestID"] as? String else { throw BridgeError(receipt["error"] as? String ?? "Запрос не принят") }
    print(jsonText(receipt.merging(["agentPID":Int(agentPID)]) { original,_ in original }))
    if arguments.contains("--wait") {
        let deadline = Date().addingTimeInterval(action == "prepare" ? 3600 : 600)
        let resultURL = runtime.appendingPathComponent("results/" + id + ".json")
        while Date() < deadline {
            let live=try?AgentIPC.exchange(runtime:runtime,message:["ipc":"result","requestID":id])
            let result = live.flatMap { $0.isEmpty ? nil:$0 } ?? readObject(resultURL)
            if !result.isEmpty { print(jsonText(result)); exit(result["ok"] as? Bool == true ? 0 : 1) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw BridgeError("Истекло время ожидания. Проверьте состояние приложения.")
    }
} catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
