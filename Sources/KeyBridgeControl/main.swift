// SPDX-License-Identifier: MIT
import Foundation
import ServiceManagement
import KeyBridgeCore
import Darwin

let runtime = BridgePaths.runtime
let arguments = Array(CommandLine.arguments.dropFirst())
let action = arguments.first ?? "status"
func option(_ name: String) -> String? { guard let i = arguments.firstIndex(of: name), i+1 < arguments.count else { return nil }; return arguments[i+1] }
func ensureAgent() throws {
    let pidURL = runtime.appendingPathComponent("agent.pid")
    if let string = try? String(contentsOf: pidURL), let pid = Int32(string.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
           URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath() == BridgePaths.executableDirectory.appendingPathComponent("KeyBridgeAgent").resolvingSymlinksInPath() { return }
    }
    let logURL = runtime.appendingPathComponent("agent.log")
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    let log = try FileHandle(forWritingTo: logURL); try log.seekToEnd()
    let p = Process(); p.executableURL = BridgePaths.executableDirectory.appendingPathComponent("KeyBridgeAgent")
    p.standardOutput = log; p.standardError = log; p.standardInput = FileHandle.nullDevice
    try p.run(); try? log.close()
    for _ in 0..<50 {
        if let string = try? String(contentsOf: pidURL), let pid = Int32(string.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw BridgeError("Фоновый агент не запустился. См. agent.log")
}
do {
    umask(0o077)
    if action == "inspect-import" {
        guard let kind=option("--kind"),let path=option("--path") else {throw BridgeError("Укажите тип и путь установщика.")}
        var result=try ImportValidation.inspect(URL(fileURLWithPath:path),kind:kind);result["ok"]=true
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
    try BridgePaths.preparePrivateDirectory(runtime)
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
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/arch"); p.arguments = ["-arm64", BridgePaths.platform, "ENTERPRISE", "/ManageLicenses"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); print(jsonText(["ok":true,"launched":true])); exit(0)
    }
    guard ["prepare", "start", "stop", "probe", "shutdown", "evidence", "refresh-key", "resources", "rollback", "configure", "repair", "restore", "autostart", "refresh-state"].contains(action) else { throw BridgeError("Неизвестная команда") }
    var request: [String: Any] = ["action": action,"requestID":UUID().uuidString]
    if action == "prepare" {
        guard let installer = option("--installer"), let driver = option("--driver") else { throw BridgeError("Выберите установщик 1С .run и драйвер .deb") }
        request["installer"] = URL(fileURLWithPath: installer).standardizedFileURL.path
        request["driver"] = URL(fileURLWithPath: driver).standardizedFileURL.path
    }
    if action == "rollback",let generation=option("--generation") {
        guard UUID(uuidString:generation) != nil else { throw BridgeError("Некорректное поколение") };request["generation"]=generation
    }
    if action == "autostart" {
        guard let mode=arguments.dropFirst().first,["on","off"].contains(mode) else { throw BridgeError("Укажите autostart on/off") }
        try ApplicationCapabilities.requireLoginLaunch(mode == "on")
        request["enabled"] = mode == "on"
    }
    try ensureAgent()
    let receipt:[String:Any]
    do { receipt=try AgentIPC.exchange(runtime:runtime,message:request) }
    catch { let id=try CommandQueue.enqueue(request,runtime:runtime);receipt=["accepted":true,"requestID":id] }
    guard receipt["accepted"] as? Bool == true,let id=receipt["requestID"] as? String else { throw BridgeError(receipt["error"] as? String ?? "Запрос не принят") }
    print(jsonText(receipt))
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
