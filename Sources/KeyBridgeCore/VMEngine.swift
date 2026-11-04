// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Darwin

public enum VMEngineError: Error, LocalizedError {
    case message(String)
    case cancelled
    case safety(String)
    case channel(String)
    case qmp(String)
    case services([String])
    public var errorDescription: String? {
        switch self {
        case .message(let value), .safety(let value), .channel(let value), .qmp(let value): return value
        case .services(let names): return "Требуется восстановление служб: " + names.joined(separator: ", ")
        case .cancelled: return "Подготовка отменена. Рабочая среда сохранена."
        }
    }
}

/// Serialized, native host controller. Proprietary inputs and generated images never enter the app bundle.
public final class VMEngine {
    private let runtime: URL
    private let resources: URL
    private let fm = FileManager.default
    private var child: Process?
    private var ownedGeneration: URL?
    // Injectable system boundaries for fault tests; production always uses the
    // OS inventory and audit-token signal implementation.
    var observeProcesses: (URL) -> VMOwnership = HostProcessInspector.observe
    var qmpTransport: ((String, [String: Any]) throws -> Any)?
    var guestTransport:((URL,String,Data?) throws ->String)?
    var observeUSB:(() throws ->[USBConnection])?
    var shutdownGuest:((URL)->Void)?
    var subscribeRuntimeChanges:((URL)throws->Void)?
    var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    public var operationCancelled: (() -> Bool)?
    public var publicationBarrier: (((() throws -> Void)) throws -> Void)?
    public var usbChanged:(()->Void)?
    public var runtimeChanged:(()->Void)?
    private var serviceObserver:Process?
    private let qmpLock=NSLock()
    private var qmpObserver:DispatchSourceRead?
    private var observedQMP:Int32?
    private var qmpReadBuffer=Data()
    private var qmpObservationLost=false
    var qmpTimeout:TimeInterval = 8
    public var stateSink: (([String:Any]) -> Void)?
    public var hasConnectionContext:Bool { usbMonitor != nil || observeUSB != nil }
    private let usbMonitorLock=NSLock()
    private var usbMonitor:USBMonitor?
    private var capturedUSB:USBConnection?
    private var preparing = false
    private var preparation: PreparationSession?
    private var activeLog: URL { runtime.appendingPathComponent("logs/engine.log") }
    private var qmpPath: URL { runtime.appendingPathComponent("qmp.sock") }
    private var pidPath: URL { runtime.appendingPathComponent("qemu.pid") }
    private var cancelPath: URL { runtime.appendingPathComponent("cancel.request") }
    private var manifestPath: URL { runtime.appendingPathComponent("current.json") }
    private var statePath: URL { runtime.appendingPathComponent("status.json") }
    private var version: String { BridgePaths.version }
    public static let sshPort = 22422
    public static let managerPort = 15441

    public init(runtime: URL, resources: URL) {
        self.runtime = runtime.standardizedFileURL
        self.resources = resources.standardizedFileURL
        // The production agent constructs its single engine only after taking
        // agent.lock. A fresh owner can reconcile an interrupted attempt without
        // guessing from heartbeat age or touching a VM or its disks.
        if let recovered = try? PreparationSession.recoverInterrupted(runtime: self.runtime) {
            let succeeded = recovered["state"] as? String == "succeeded"
            let message = succeeded ? "Среда готова. Можно запустить раздачу." : "Подготовка прервана перезапуском фонового агента. Повторите подготовку."
            update(["status": succeeded ? "stopped" : "error", "phase": recovered["phase"] ?? "verify",
                    "busy": false, "running": observeProcesses(self.runtime).running, "message": message,
                    "lastError": succeeded ? NSNull() : message as Any])
        }
    }

    public func status() -> [String: Any] {
        var result = readJSON(statePath) ?? [:]
        if result.isEmpty { result = ["status":"unprepared", "message":"Добавьте свои установщики", "busy":false, "running":false] }
        let observation = observeProcesses(runtime)
        result["ownership"] = observation.name
        result["running"] = observation.running
        if case .unknown(let reason) = observation {
            result["ownershipError"] = reason
        } else { result["ownershipError"] = NSNull() }
        let generations=GenerationStore(runtime:runtime).snapshot()
        let generation=generations.current
        result["prepared"] = generation != nil
        result["generations"] = generations.summaries
        result.merge(generations.presentation){_,new in new}
        result["cpus"] = 1
        result["runID"] = observationRunID(observation)
        if var sample=result["resources"] as? [String:Any] {
            sample["historical"] = !NSDictionary(dictionary:sample["context"] as? [String:Any] ?? [:]).isEqual(to:resourceContext(observation))
            result["resources"]=sample
        }
        result["generation"] = generation?.id ?? ""
        result["endpoint"] = "127.0.0.1:\(Self.managerPort)"
        result["platformVersion"] = version
        result["guestOS"] = generation?.backend ?? "unknown"
        result["memoryMiB"] = readJSON(manifestPath)?["memoryMiB"] ?? 128
        return result
    }

    /// This file can be created by the agent while a serialized operation is busy.
    public func requestCancellation() throws {
        try makePrivateDirectory(runtime)
        try Data().write(to: cancelPath, options:.atomic)
    }

    @discardableResult public func perform(_ request: [String: Any]) throws -> [String: Any] {
        try makePrivateDirectory(runtime)
        try makePrivateDirectory(runtime.appendingPathComponent("logs"))
        #if !arch(arm64)
        throw VMEngineError.message("Приложение должно работать нативно на Apple Silicon.")
        #endif
        let action = request["action"] as? String ?? "status"
        if action == "status" { return status() }
        if action == "cancel" { try requestCancellation(); return status() }
        if ["start", "prepare"].contains(action) { try? fm.removeItem(at: cancelPath) }
        do {
            switch action {
            case "prepare": try withPreparation { try prepare(request) }
            case "start": try start()
            case "rollback": try rollback()
            case "stop": try stop()
            case "attach": try attach()
            case "health": try health()
            case "inspect": try inspectRuntime()
            case "recover-channel": try recoverChannel()
            case "recover-services": try recoverServices(request["services"] as? [String] ?? [])
            case "licenseEvidence": return try licenseEvidence(request["baseline"] as? [String:Any])
            case "resources": return try resourceUsage()
            default: throw VMEngineError.message("Неизвестное действие: \(action)")
            }
            return status()
        } catch {
            if action == "resources" { throw error }
            let ownership=observeProcesses(runtime)
            var failure: [String: Any] = ["status":"error", "busy":false, "message":error.localizedDescription, "lastError":error.localizedDescription, "running":ownership.running,"ownership":ownership.name]
            if case .unknown(let reason)=ownership { failure["ownershipError"]=reason }
            if action == "prepare", let phase = readJSON(runtime.appendingPathComponent("preparation.json"))?["phase"] as? String { failure["phase"] = phase }
            update(failure)
            throw error
        }
    }

    func update(_ values: [String: Any]) {
        var state = readJSON(statePath) ?? [:]
        for (key, value) in values { state[key] = value }
        state["updatedAt"] = ISO8601DateFormatter().string(from:Date())
        state["prepared"] = (try? GenerationStore(runtime:runtime).current()) != nil
        state["endpoint"] = "127.0.0.1:\(Self.managerPort)"
        state["platformVersion"] = version
        state["guestOS"] = readJSON(manifestPath)?["backend"] ?? "unknown"
        state["memoryMiB"] = readJSON(manifestPath)?["memoryMiB"] ?? 128
        if let stateSink {
            // With an agent, that controller is the only status writer. A raw
            // engine write here would briefly publish false idle on disk, or
            // let a cancelled operation bypass its publication barrier.
            var patch=values
            for key in ["updatedAt","prepared","endpoint","platformVersion","guestOS","memoryMiB"] { patch[key]=state[key] }
            stateSink(patch)
            return
        }
        do { try writeJSON(state,to:statePath) }
        catch { state["persistenceError"]=error.localizedDescription; fputs("KeyBridge status: \(error.localizedDescription)\n",stderr) }
    }

    private func readJSON(_ path: URL) -> [String:Any]? {
        guard let data = try? Data(contentsOf:path) else { return nil }
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
    }

    private func writeJSON(_ object: [String:Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:path, options:.atomic)
    }

    private func makePrivateDirectory(_ path: URL) throws {
        try fm.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let attrs = try fm.attributesOfItem(atPath:path.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw VMEngineError.message("Каталог данных принадлежит другому пользователю.") }
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)
    }

    private func requireFile(_ path: URL) throws {
        let attributes = try fm.attributesOfItem(atPath:path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw VMEngineError.message("Требуется обычный файл: \(path.lastPathComponent)") }
    }

    private func hash(_ path: URL, sha512: Bool = false) throws -> String {
        try preparationMessage("Проверка контрольной суммы \(path.lastPathComponent)")
        let input = try FileHandle(forReadingFrom:path); defer { try? input.close() }
        if sha512 {
            var digest = SHA512()
            while let data = try input.read(upToCount:1024*1024), !data.isEmpty { try checkCancellation(); digest.update(data:data) }
            let value = digest.finalize().map{String(format:"%02x",$0)}.joined()
            try preparationMessage("Контрольная сумма \(path.lastPathComponent) вычислена")
            return value
        }
        var digest = SHA256()
        while let data = try input.read(upToCount:1024*1024), !data.isEmpty { try checkCancellation(); digest.update(data:data) }
        let value = digest.finalize().map{String(format:"%02x",$0)}.joined()
        try preparationMessage("Контрольная сумма \(path.lastPathComponent) вычислена")
        return value
    }

    private func checkCancellation() throws {
        if operationCancelled?() == true || fm.fileExists(atPath:cancelPath.path) { throw VMEngineError.cancelled }
        try preparation?.heartbeat()
    }

    /// Production lifecycle is also usable by offline command fixtures: no VM,
    /// installer or hardware is required to exercise terminal progress states.
    func withPreparation(_ operation: () throws -> Void) throws {
        try makePrivateDirectory(runtime)
        try makePrivateDirectory(runtime.appendingPathComponent("logs"))
        preparation = try PreparationSession(runtime: runtime)
        defer { preparation = nil }
        do {
            try preparationMessage("Проверка выбранных установщиков")
            try operation()
            // The operation may already have committed current.json. A progress
            // disk error must not report rollback after that commit succeeded.
            do { try preparation?.finish("succeeded") }
            catch { try? preparation?.finish("succeeded") }
        } catch {
            try? preparationMessage(error.localizedDescription)
            let cancelled: Bool
            if case VMEngineError.cancelled = error { cancelled = true } else { cancelled = false }
            try? preparation?.finish(cancelled ? "cancelled" : "failed")
            throw error
        }
    }

    private func preparationMessage(_ message: String) throws {
        let bytes = Data((message + "\n").utf8)
        try appendPrivateLog(bytes, to: activeLog)
        try preparation?.record(bytes, parseMarkers: false)
    }

    private func preparationPhase(_ phase: String, _ message: String) throws {
        try preparation?.advance(to: phase)
        update(["phase": phase, "message": message])
        try preparationMessage(message)
    }

    /// Copy in bounded chunks so cancellation and engine heartbeat remain live
    /// during large local imports, independently of subprocess polling.
    private func copyForPreparation(_ source: URL, to destination: URL) throws {
        try checkCancellation()
        try preparationMessage("Копирование \(source.lastPathComponent)")
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw VMEngineError.message("Не удалось создать копию \(destination.lastPathComponent)") }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false
        defer { try? output.close(); if !complete { try? fm.removeItem(at: destination) } }
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try checkCancellation()
        complete = true
        try preparationMessage("Копирование \(source.lastPathComponent) завершено")
    }

    @discardableResult func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 60, checking: Bool = true, cancellable: Bool = true) throws -> String {
        defer { try? preparation?.finishCommandOutput() }
        let result = try StreamingCommand.run(executable, arguments, directory: runtime.appendingPathComponent("logs"),
            input: input, timeout: timeout,
            cancellation: { cancellable && (self.operationCancelled?() == true || self.fm.fileExists(atPath: self.cancelPath.path)) },
            output: { bytes in
                try appendPrivateLog(bytes, to: self.activeLog)
                let previous = self.preparation?.values["phase"] as? String
                try self.preparation?.record(bytes)
                if let phase = self.preparation?.values["phase"] as? String, phase != previous { self.update(["phase": phase]) }
            }, heartbeat: { try self.preparation?.heartbeat() })
        let text = result.output
        if checking && result.status != 0 {
            let reasons: [String:String] = [
                "missing_dependencies":"Для rmlic не хватает библиотек Linux",
                "rmlic_failed":"Менеджер лицензий завершился с ошибкой при запуске",
                "rmlic_timeout":"Менеджер запущен, но не открыл порт лицензирования за отведённое время",
                "runtime_readiness_timeout":"Драйвер HASP не завершил подготовку своего диагностического API вовремя",
                "firmware_updates_not_disabled":"Runtime не подтвердил запрет обновления прошивки ключа",
                "guest_disk_full":"Внутри Linux не хватает места для подготовки компонентов",
                "guest_memory":"Linux зарегистрировал нехватку памяти во время подготовки",
                "stage_imports":"Не удалось проверить импортированные установщики",
                "stage_verify_imports":"Не удалось проверить установщики в Alpine",
                "invalid_driver_package":"Выбранный файл не является исправным DEB-пакетом",
                "wrong_driver_package":"Нужен пакет драйвера HASP с именем aksusbd",
                "wrong_driver_architecture":"Нужен драйвер HASP для Linux amd64",
                "missing_driver_runtime":"В DEB-пакете отсутствуют программы aksusbd и hasplmd",
                "invalid_platform_installer":"Не удалось прочитать сведения установщика 1С",
                "missing_license_manager":"В установщике 1С отсутствует компонент lic_manager",
                "ambiguous_license_manager":"После установки найдено несколько менеджеров лицензий",
                "stage_dependencies":"Не удалось установить зависимости Linux",
                "stage_driver":"Не удалось установить драйвер HASP",
                "stage_firmware_guard":"Runtime не подтвердил запрет обновления прошивки ключа",
                "stage_manager_install":"Установщик менеджера лицензий завершился с ошибкой",
                "stage_manager_configure":"Не удалось настроить установленный менеджер лицензий",
                "stage_manager_start":"Не удалось запустить менеджер лицензий",
                "stage_manager_ready":"Менеджер лицензий не подтвердил готовность"
            ]
            let marker = text.split(separator:"\n").compactMap { line -> String? in
                if let data=String(line).data(using:.utf8), let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let status=object["status"] as? String { return status }
                guard line.hasPrefix("KEYBRIDGE_ERROR=") else { return nil }
                return String(line.dropFirst("KEYBRIDGE_ERROR=".count).split(separator:" ").first ?? "")
            }.first { reasons[$0] != nil }
            let reason = marker.flatMap { reasons[$0] } ?? "Ошибка \(URL(fileURLWithPath:executable).lastPathComponent) (код \(result.status))"
            throw VMEngineError.message("\(reason). Подробности в локальном журнале: \(activeLog.path)")
        }
        return text
    }

    private func nativeBinary(_ name: String) throws -> URL {
        let url = resources.appendingPathComponent("runtime/bin/\(name)")
        try requireFile(url)
        let description = try run("/usr/bin/file",["-L",url.path])
        guard description.contains("arm64") else { throw VMEngineError.message("В приложении отсутствует ARM64-сборка \(name).") }
        return url
    }

    private func prepare(_ request: [String:Any]) throws {
        try requireAbsent()
        guard let installerPath=request["installer"] as? String, let driverPath=request["driver"] as? String else { throw VMEngineError.message("Добавьте установщик 1С .run и драйвер HASP .deb.") }
        let installer = URL(fileURLWithPath:installerPath), driver=URL(fileURLWithPath:driverPath)
        try requireFile(installer); try requireFile(driver)
        _ = try nativeBinary("qemu-system-x86_64"); _ = try nativeBinary("qemu-img")
        update(["status":"preparing", "phase":"verify", "busy":true,"running":false,"message":"Проверка выбранных установщиков", "lastError":NSNull(),"lastProbe":NSNull()])
        try ImportValidation.check(installer: installer, driver: driver)
        let imageTool=try nativeBinary("qemu-img")
        let space=try RuntimeResources.preparationSpace(runtime:runtime,resources:resources,installer:installer,driver:driver)
        update(["preparationSpace":space])
        guard space["sufficient"] as? Bool == true else { throw BridgeError("Недостаточно места для копий установщиков и двух образов при подготовке") }
        // Record the selected bytes for provenance and transfer integrity, not as an allowlist.
        let installerHash = try hash(installer)
        let driverHash = try hash(driver)
        try preparationPhase("linux", "Создание VM из готового предобраза Alpine")
        let base = resources.appendingPathComponent("base/alpine.qcow2")
        try requireFile(base)
        let generation=runtime.appendingPathComponent("generations/\(UUID().uuidString)")
        try makePrivateDirectory(generation)
        preparing=true; var accepted=false
        defer {
            preparing=false
            if !accepted {
                try? stop()
                // Retain interrupted candidates and their diagnostics. Absence of
                // a PID file is never authorization to unlink a live disk.
            }
        }
        let seed=generation.appendingPathComponent("seed"); try makePrivateDirectory(seed)
        let key=generation.appendingPathComponent("id_ed25519")
        try run("/usr/bin/ssh-keygen",["-q","-t","ed25519","-N","","-C","keybridge-local","-f",key.path])
        try copyForPreparation(key.appendingPathExtension("pub"),to:seed.appendingPathComponent("authorized_keys"))
        let hostKey=seed.appendingPathComponent("ssh_host_ed25519_key")
        try run("/usr/bin/ssh-keygen",["-q","-t","ed25519","-N","","-C","keybridge-guest","-f",hostKey.path])
        let pinned=try String(contentsOf:hostKey.appendingPathExtension("pub"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        try ("keybridge-" + generation.lastPathComponent.lowercased() + " " + pinned + "\n").write(to:generation.appendingPathComponent("known_hosts"),atomically:true,encoding:.utf8)
        for name in ["vmlinuz-virt", "initramfs-virt"] {
            try copyForPreparation(resources.appendingPathComponent("base/" + name),to:generation.appendingPathComponent(name))
        }
        try writeJSON(["backend":"alpine", "memoryMiB":128, "cpus":1],to:generation.appendingPathComponent("guest.json"))
        try run("/usr/bin/hdiutil",["makehybrid","-iso","-joliet","-default-volume-name","cidata","-o",generation.appendingPathComponent("seed.iso").path,seed.path],timeout:120)
        // A private full copy avoids depending on a mutable application bundle.
        try copyForPreparation(base,to:generation.appendingPathComponent("guest.qcow2"))
        let imports=generation.appendingPathComponent("imports"); try makePrivateDirectory(imports)
        try preparationPhase("import", "Импорт ваших компонентов в локальную среду")
        try copyForPreparation(installer,to:imports.appendingPathComponent("setup.run"))
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:imports.appendingPathComponent("setup.run").path)
        try copyForPreparation(driver,to:imports.appendingPathComponent("runtime.deb"))
        try "\(installerHash)  setup.run\n\(driverHash)  runtime.deb\n".write(to:imports.appendingPathComponent("sha256sums"),atomically:true,encoding:.utf8)
        try fm.copyItem(at:resources.appendingPathComponent("guest/verify_imports.sh"),to:imports.appendingPathComponent("verify_imports.sh"))
        try fm.copyItem(at:resources.appendingPathComponent("guest/sentinel_guard.py"),to:imports.appendingPathComponent("sentinel_guard.py"))
        try fm.copyItem(at:resources.appendingPathComponent("guest/rmlic_ready.sh"),to:imports.appendingPathComponent("rmlic_ready.sh"))
        try run("/usr/bin/hdiutil",["makehybrid","-iso","-joliet","-default-volume-name","keybridge","-o",generation.appendingPathComponent("imports.iso").path,imports.path],timeout:300)
        try preparationPhase("boot", "Первый запуск Linux — это может занять несколько минут")
        try launch(generation, installing:true)
        try awaitSSH(generation,timeout:480)
        try preparationMessage("Linux доступен. Проверка импортированных установщиков в гостевой среде")
        let script=try Data(contentsOf:resources.appendingPathComponent("guest/alpine_provision.sh"))
        let installation=try ssh(generation,"sudo sh -s",input:script,timeout:1800)
        guard installation.contains("KEYBRIDGE_PREPARED") else { throw VMEngineError.message("Установка не подтвердила готовность среды.") }
        let importedJSON = try ssh(generation,"cat /var/lib/keybridge/imports.json")
        guard let importedData = importedJSON.data(using:.utf8),
              let imported = try JSONSerialization.jsonObject(with:importedData) as? [String:Any],
              let managerVersion = imported["managerVersion"] as? String,
              let runtimeVersion = imported["runtimeVersion"] as? String else {
            throw VMEngineError.message("Не удалось прочитать сведения установленных компонентов.")
        }
        try preparationPhase("finalize", "Проверка Alpine и сохранение результата")
        try stopVM()
        try checkCancellation()
        let compact=generation.appendingPathComponent("compact.qcow2")
        try run(imageTool.path,["convert","-c","-O","qcow2",generation.appendingPathComponent("guest.qcow2").path,compact.path],timeout:300)
        try fm.removeItem(at:generation.appendingPathComponent("guest.qcow2"))
        try fm.moveItem(at:compact,to:generation.appendingPathComponent("guest.qcow2"))
        for path in [imports,generation.appendingPathComponent("imports.iso"),seed,generation.appendingPathComponent("seed.iso")] { try? fm.removeItem(at:path) }
        _ = try run(imageTool.path,["check","-f","qcow2",generation.appendingPathComponent("guest.qcow2").path],timeout:120)
        try preparationMessage("Проверка среды завершена. Сохранение результата")
        let manifest: [String:Any] = ["backend":"alpine", "memoryMiB":128, "generation":generation.lastPathComponent,"version":managerVersion,"runtimeVersion":runtimeVersion,"installerDescription":imported["installerDescription"] ?? "","installerSHA256":installerHash,"driverSHA256":driverHash,"preparationID":preparation?.values["id"] as? String ?? "","createdAt":ISO8601DateFormatter().string(from:Date())]
        try publishCurrent {
            try GenerationStore(runtime:self.runtime).publish(manifest)
        }
        accepted=true
        update(["status":"stopped", "phase":"ready", "busy":false,"running":false,"message":"Среда готова. Можно запустить раздачу.","lastError":NSNull()])
    }

    private func isAlpine(_ generation: URL) -> Bool {
        readJSON(generation.appendingPathComponent("guest.json"))?["backend"] as? String == "alpine"
    }

    private func currentGeneration() throws -> URL {
        try GenerationStore(runtime:runtime).current().folder
    }

    private func publishCurrent(_ body: () throws -> Void) throws {
        try checkCancellation()
        if let publicationBarrier { try publicationBarrier(body) }
        else { try body() }
    }

    private func rollback() throws {
        try requireAbsent()
        let selected=try GenerationStore(runtime:runtime).rollback()
        let imageTool=try nativeBinary("qemu-img")
        _ = try run(imageTool.path,["check","-f","qcow2",selected.folder.appendingPathComponent("guest.qcow2").path],timeout:120)
        try publishCurrent { try GenerationStore(runtime:self.runtime).publish(selected.manifest) }
        update(["prepared":true,"status":"stopped","phase":"ready","busy":false,"running":false,"generation":selected.id,"lastProbe":NSNull(),"message":"Выбрано сохранённое поколение. Выполните новую проверку после запуска."])
    }

    private func launch(_ generation: URL, installing: Bool) throws {
        try requireAbsent()
        let binary=try nativeBinary("qemu-system-x86_64")
        guard qmpPath.path.utf8.count < 104 else { throw VMEngineError.message("Путь к данным слишком длинный для управления VM.") }
        for port in [Self.sshPort,Self.managerPort] { try checkPort(port) }
        try checkPort(Self.managerPort, datagram:true)
        for path in [qmpPath,pidPath] { try? fm.removeItem(at:path) }
        let network="user,id=lan,restrict=on,hostfwd=tcp:127.0.0.1:\(Self.sshPort)-:22,hostfwd=tcp:127.0.0.1:\(Self.managerPort)-:1544,hostfwd=udp:127.0.0.1:\(Self.managerPort)-:475"
        func disk(_ name: String)->String { generation.appendingPathComponent(name).path.replacingOccurrences(of:",",with:",,") }
        guard isAlpine(generation) else { throw VMEngineError.message("Поддерживается только Alpine с 128 МиБ и одним vCPU") }
        let runID = UUID().uuidString
        var args=["-name","keybridge-" + runID,"-L",resources.appendingPathComponent("runtime/share/qemu").path,"-machine","q35",
                  "-accel","tcg,thread=single,tb-size=16","-cpu","max","-smp","1","-m","128",
                  "-nodefaults","-display","none","-monitor","none","-serial","file:\(runtime.appendingPathComponent("logs/serial.log").path)",
                  "-qmp","unix:\(qmpPath.path),server=on,wait=off","-pidfile",pidPath.path,
                  "-drive","file=\(disk("guest.qcow2")),if=virtio,format=qcow2,discard=unmap",
                  "-netdev",network,"-device","virtio-net-pci,netdev=lan","-device","qemu-xhci,id=xhci"]
        for name in ["seed.iso", "imports.iso"] where installing && fm.fileExists(atPath:generation.appendingPathComponent(name).path) {
            args += ["-drive","file=\(disk(name)),if=ide,media=cdrom,readonly=on"]
        }
        args += ["-kernel",generation.appendingPathComponent("vmlinuz-virt").path,
                 "-initrd",generation.appendingPathComponent("initramfs-virt").path,
                 "-append","root=/dev/vda rootfstype=ext4 rw console=ttyS0 modules=virtio_pci,virtio_blk,ext4"]
        let log=runtime.appendingPathComponent("logs/qemu.log"); if !fm.fileExists(atPath:log.path) { fm.createFile(atPath:log.path,contents:nil) }
        let handle=try FileHandle(forWritingTo:log); try handle.seekToEnd()
        let process=Process();process.executableURL=binary;process.arguments=args;process.standardInput=FileHandle.nullDevice;process.standardOutput=handle;process.standardError=handle
        process.terminationHandler = { [weak self] _ in self?.runtimeChanged?() }
        try process.run();try? handle.close();child=process;ownedGeneration=generation
        try writeJSON(["pid":process.processIdentifier,"generation":generation.lastPathComponent,"runID":runID,"installing":installing],to:runtime.appendingPathComponent("active-vm.json"))
        for _ in 0..<100 {
            try checkCancellation()
            if !process.isRunning { throw VMEngineError.message("QEMU не запустился; смотрите локальный qemu.log.") }
            if fm.fileExists(atPath:qmpPath.path), ownPID()==process.processIdentifier {
                update(["running":true,"ownership":"owned","usbReleased":NSNull(),"runID":runID])
                return
            }
            Thread.sleep(forTimeInterval:0.1)
        }
        throw VMEngineError.message("QEMU не создал канал управления.")
    }

    private func start() throws {
        switch observeProcesses(runtime) {
        case .owned: try health(); return
        case .absent: stoppedCleanup()
        case .unknown(let reason): throw VMEngineError.safety("Владелец VM не установлен: " + reason)
        }
        let generation=try currentGeneration()
        update(["status":"starting","phase":"boot","busy":true,"running":false,"keyConnected":false,"keyConnection":NSNull(),"message":"Запуск Linux и менеджера лицензий","lastError":NSNull(),"lastProbe":NSNull()])
        do {
            try launch(generation,installing:false)
            try awaitSSH(generation,timeout:420)
            let services = "sudo /usr/local/sbin/keybridge-services start"
            _ = try ssh(generation,services + " && sudo /usr/local/bin/keybridge-rmlic-ready 90",timeout:110)
            try attach()
        } catch {
            try? stopVM()
            throw error
        }
    }

    private func sshOptions(_ generation: URL) -> [String] {
        ["-F","/dev/null","-i",generation.appendingPathComponent("id_ed25519").path,"-o","IdentitiesOnly=yes","-o","BatchMode=yes","-o","ConnectTimeout=6","-o","StrictHostKeyChecking=yes","-o","UserKnownHostsFile=\"\(generation.appendingPathComponent("known_hosts").path)\"","-o","HostKeyAlias=keybridge-\(generation.lastPathComponent)","-p",String(Self.sshPort),"hasp@127.0.0.1"]
    }

    private func ssh(_ generation: URL, _ command:String,input:Data?=nil,timeout:TimeInterval=40) throws -> String {
        do {
            if let guestTransport { return try guestTransport(generation,command,input) }
            return try run("/usr/bin/ssh",sshOptions(generation)+[command],input:input,timeout:timeout)
        } catch {
            if let error=error as? VMEngineError, case .cancelled=error { throw error }
            try checkCancellation()
            throw VMEngineError.channel("Канал SSH или гостевая команда недоступны: " + error.localizedDescription)
        }
    }

    private func awaitSSH(_ generation:URL,timeout:TimeInterval) throws {
        let deadline=Date().addingTimeInterval(timeout)
        while Date()<deadline {
            try checkCancellation()
            guard ownPID() != nil else { throw VMEngineError.message("VM остановилась во время загрузки.") }
            if (try? ssh(generation,"true",timeout:10)) != nil { return }
            Thread.sleep(forTimeInterval:2)
        }
        throw VMEngineError.message("Linux не завершил загрузку вовремя; смотрите локальный serial.log.")
    }

    private func liveGeneration(_ observation:VMOwnership? = nil) throws -> URL {
        guard case .owned(_, let generation?, _) = observation ?? observeProcesses(runtime) else {
            throw VMEngineError.message("Поколение работающей VM не подтверждено")
        }
        return runtime.appendingPathComponent("generations/" + generation)
    }

    public func usbObservation() throws -> [USBConnection] {
        let connections: [USBConnection]
        do { connections=try currentUSBConnections() }
        catch { throw VMEngineError.safety("Наблюдатель USB недоступен: " + error.localizedDescription) }
        guard connections.count <= 1 else { throw VMEngineError.safety("Найдено несколько USB-ключей") }
        return connections
    }

    private func currentUSBConnections() throws ->[USBConnection] {
        if let observeUSB { return try observeUSB() }
        usbMonitorLock.lock();defer { usbMonitorLock.unlock() }
        if usbMonitor == nil { usbMonitor=try USBMonitor(resources:resources,changed:{ [weak self] in self?.usbChanged?() }) }
        return try usbMonitor!.snapshot()
    }

    private func attach() throws {
        do { try attachChecked() }
        catch let error as VMEngineError {
            if case .cancelled=error { throw error }
            if case .safety=error { try?stopVM() }
            if case .qmp=error { try?stopVM() }
            throw error
        }
    }

    private func attachChecked() throws {
        let generation=try liveGeneration()
        let connections:[USBConnection]
        do {
            connections=try currentUSBConnections()
        } catch { throw VMEngineError.safety("Состояние USB неизвестно: "+error.localizedDescription) }
        guard connections.count<=1 else { update(["safetyReasonCode":"multiple-keys"]);throw VMEngineError.safety("Несколько HASP-ключей: раздача прекращена") }
        if let capturedUSB,connections.first != capturedUSB {
            try releaseCapture()
        }
        // Subscribe before reading protection: a change during the handshake
        // must be covered by the following read, and later changes by events.
        try armRuntimeObservers(generation)
        // Use this app's read-only checker, including readiness fixes, for existing VMs too.
        guard let guardScript=try?Data(contentsOf:resources.appendingPathComponent("guest/sentinel_guard.py")) else {
            update(["safetyReasonCode":"firmware-unknown"]);throw VMEngineError.safety("Проверка защиты прошивки недоступна")
        }
        let guardJSON:String
        do { guardJSON=try ssh(generation,"python3 - check-config",input:guardScript,timeout:55) }
        catch { throw error }
        guard let data=guardJSON.data(using:.utf8), let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], result["status"] as? String == "ok", result["no_auto_fwup"] as? String == "1" else { update(["safetyReasonCode":"firmware-unknown"]);throw VMEngineError.safety("Запрет обновления прошивки ключа не подтверждён; раздача прекращена.") }
        if connections.isEmpty {
            try releaseCapture()
            return
        }
        let tree=try qmp("human-monitor-command",["command-line":"info qtree"]) as? String ?? ""
        if !tree.contains("physical_hasp") {
            guard let selected=connections.first else {
                update(["status":"waiting-key","busy":false,"running":true,"message":"Менеджер запущен. Подключите USB-ключ и нажмите «Проверить ключ».","keyConnected":false,"keyModel":NSNull(),"keyType":"Локальный USB"])
                return
            }
            update(["usbTransition":"capturing","keyConnected":NSNull()])
            // Clear historical guest hotplug evidence before this capture.
            _ = try ssh(generation,"sudo sh -c 'mkdir -p /run/keybridge; : > /run/keybridge/usb-events.log'",timeout:15)
            _ = try qmp("device_add",["driver":"usb-host","id":"physical_hasp","bus":"xhci.0","hostbus":selected.bus,"hostaddr":selected.address])
            capturedUSB=selected
        } else if capturedUSB == nil {
            throw VMEngineError.safety("Передача ключа принадлежит прежнему наблюдателю; нужен новый запуск")
        }
        try observeAttachedKey(generation, wait: 20)
    }

    private func releaseCapture() throws {
        if capturedUSB != nil {
            _ = try qmp("device_del", ["id":"physical_hasp"])
            // device_del is asynchronous. Do not capture the next epoch until
            // QMP confirms the stale device was actually removed.
            let deadline=Date().addingTimeInterval(qmpTimeout)
            while true {
                try checkCancellation()
                let tree=try qmp("human-monitor-command",["command-line":"info qtree"]) as? String ?? ""
                if !tree.contains("physical_hasp") { break }
                guard Date()<deadline else { throw VMEngineError.qmp("QMP не подтвердил освобождение прежнего подключения") }
                pause(0.1)
            }
        }
        capturedUSB=nil
        update(["status":"waiting-key","busy":false,"running":true,"message":"Менеджер запущен. Ожидание USB-ключа.","keyConnected":false,"keyConnection":NSNull(),"keyModel":NSNull(),"firmware":NSNull(),"lastProbe":NSNull(),"usbTransition":"released"])
    }

    private func observationRunID(_ observation:VMOwnership)->String {
        if case .owned(_,_,let run)=observation { return run ?? "" };return ""
    }
    private func resourceContext(_ observation:VMOwnership)->[String:Any] {
        var context:[String:Any]=["ownership":observation.name,"generation":(try?GenerationStore(runtime:runtime).current().id) ?? "","run":observationRunID(observation)]
        if let process=observation.identity {context["processIdentity"]=process.audit}
        return context
    }
    private func resourceUsage() throws ->[String:Any] {
        var result=RuntimeResources.disk(runtime:runtime,resources:resources)
        let before=observeProcesses(runtime)
        result["context"]=resourceContext(before)
        if case .owned(let process,_,_)=before {
          do {
            let rss=try hostCommand("/bin/ps",["-p",String(process.pid),"-o","rss="])
            if try ProcessIdentity.capture(process.pid)==process,let kib=Int(rss.output.trimmingCharacters(in:.whitespacesAndNewlines)) { result["qemuRSSBytes"]=kib*1024 }
            let script="""
            import json
            from pathlib import Path
            mem={}
            for line in Path('/proc/meminfo').read_text().splitlines():
                key,value=line.split(':',1);mem[key]=int(value.strip().split()[0])*1024
            vm={line.split()[0]:int(line.split()[1]) for line in Path('/proc/vmstat').read_text().splitlines()}
            print(json.dumps({'totalBytes':mem['MemTotal'],'availableBytes':mem['MemAvailable'],'usedBytes':mem['MemTotal']-mem['MemAvailable'],'swapTotalBytes':mem['SwapTotal'],'swapUsedBytes':mem['SwapTotal']-mem['SwapFree'],'oomKills':vm.get('oom_kill',0)}))
            """
            let text=try ssh(try liveGeneration(),"python3 -",input:Data(script.utf8),timeout:20)
            if let data=text.data(using:.utf8),let guest=try JSONSerialization.jsonObject(with:data) as? [String:Any] { result["guest"]=guest }
          } catch { result["memoryError"]=error.localizedDescription }
        }
        result["sampledAt"]=Date().timeIntervalSince1970
        result["historical"] = !NSDictionary(dictionary:resourceContext(before)).isEqual(to:resourceContext(observeProcesses(runtime)))
        update(["resources":result])
        return result
    }

    private func licenseEvidence(_ baseline:[String:Any]? = nil) throws -> [String:Any] {
        try health()
        guard ownPID() != nil else { throw VMEngineError.message("VM не запущена.") }
        let source=try Data(contentsOf:resources.appendingPathComponent("guest/license_evidence.py"))
        let encoded=try JSONSerialization.data(withJSONObject:baseline ?? [:]).base64EncodedString()
        let script=Data(("import json,base64\nBASELINE=json.loads(base64.b64decode('"+encoded+"'))\n").utf8)+source
        let output=try ssh(try liveGeneration(),"sudo -n python3 -",input:script,timeout:30)
        guard let data=output.data(using:.utf8),var result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { throw VMEngineError.message("Не удалось прочитать подтверждение лицензирования.") }
        var context=result["context"] as? [String:Any] ?? [:]
        if case .owned(let process,let generation,let run)=observeProcesses(runtime) {
            context["generation"]=generation ?? "";context["run"]=run ?? ""
            context["audit"]=process.audit
        }
        if let capturedUSB { context["usb"]=capturedUSB.descriptor }
        result["context"]=context
        return result
    }

    private func health() throws {
        update(["safetyReasonCode":NSNull()])
        let ownership=observeProcesses(runtime)
        switch ownership {
        case .absent:
            update(["running":false,"busy":false,"status":"stopped","ownership":"absent","message":"Раздача остановлена","keyConnected":false]); return
        case .owned:
            let generation=try liveGeneration(ownership)
            let connections:[USBConnection]
            do { connections=try currentUSBConnections() }
            catch { throw VMEngineError.safety("Наблюдение USB недоступно: " + error.localizedDescription) }
            guard connections.count <= 1 else { try? stopVM(); throw VMEngineError.safety("Найдено несколько ключей") }
            if connections.isEmpty {
                try releaseCapture()
                try armRuntimeObservers(generation)
                let result=try guestObservation(generation)
                guard result["status"] as? String == "ok",result["no_auto_fwup"] as? String == "1" else { throw VMEngineError.safety("Защита прошивки не подтверждена") }
                if let failed=result["failedServices"] as? [String],!failed.isEmpty { throw VMEngineError.services(failed) }
                return
            }
            if let capturedUSB,connections.first != capturedUSB { try releaseCapture() }
            if capturedUSB != nil {
                do { try armRuntimeObservers(generation);try observeAttachedKey(generation, wait: 0) }
                catch let error as VMEngineError {
                    if case .safety=error { try? stopVM() }
                    if case .qmp=error { try? stopVM() }
                    throw error
                }
            } else {
                try attach()
            }
        case .unknown(let reason):
            update(["status":"error","ownership":"unknown","busy":false,"keyConnected":NSNull()])
            throw VMEngineError.safety("Состояние VM неизвестно: " + reason)
        }
    }

    /// Explicit observation never creates an object or captures a USB device.
    private func inspectRuntime() throws {
        let ownership=observeProcesses(runtime)
        let connections=try usbObservation()
        var facts:[String:Any] = ["ownership":ownership.name,"running":ownership.running,
            "physicalKeyCount":connections.count,"physicalKeyConnection":connections.first?.descriptor ?? [:],
            "protection":"unknown","keyConnected":connections.isEmpty ? false : NSNull()]
        switch ownership {
        case .absent:
            facts.merge(["status":"stopped","keyConnected":false,"message":"VM остановлена. Защита внутри Linux не проверена."]) { _,new in new }
        case .unknown(let reason):
            facts["ownershipError"]=reason
            update(facts)
            throw VMEngineError.safety("Принадлежность VM неизвестна: " + reason)
        case .owned:
            let result=try guestObservation(liveGeneration(ownership))
            facts["protection"] = result["status"] as? String == "ok" && result["no_auto_fwup"] as? String == "1" ? "confirmed" : "unknown"
            facts["services"] = result["services"]
            facts["managerReady"] = result["managerReady"]
            update(facts)
            guard facts["protection"] as? String == "confirmed" else { throw VMEngineError.safety("Защита прошивки не подтверждена") }
            _ = try qmp("query-status")
            guard let keys=result["keys"] as? [[String:Any]],keys.count<=1 else { throw VMEngineError.safety("Наблюдение ключей Linux неоднозначно") }
            facts["guestKeys"]=keys
            if let capturedUSB,connections == [capturedUSB] {
                let tree=try qmp("human-monitor-command",["command-line":"info qtree"]) as? String ?? ""
                guard USBTransfer.matches(tree,connection:capturedUSB) else { throw VMEngineError.qmp("QMP не подтвердил текущее подключение USB") }
                facts["keyConnected"]=keys.count==1
            }
            if let failed=result["failedServices"] as? [String], !failed.isEmpty { throw VMEngineError.services(failed) }
        }
        update(facts)
    }

    private func guestObservation(_ generation:URL) throws -> [String:Any] {
        var sources=[String:String]()
        for name in ["sentinel_guard", "key_info", "alpine_ready"] {
            sources[name]=try String(contentsOf:resources.appendingPathComponent("guest/\(name).py"),encoding:.utf8)
        }
        let encoded=try JSONSerialization.data(withJSONObject:sources).base64EncodedString()
        let header="import json, base64\nSOURCES=json.loads(base64.b64decode('\(encoded)'))\n"
        let script=header + (try String(contentsOf:resources.appendingPathComponent("guest/health.py"),encoding:.utf8))
        let output=try ssh(generation,"sudo -n python3 -",input:Data(script.utf8),timeout:20)
        guard let data=output.data(using:.utf8),let result=(try?JSONSerialization.jsonObject(with:data)) as? [String:Any] else {
            throw VMEngineError.safety("Неизвестный ответ наблюдателя Linux")
        }
        return result
    }

    /// One admitted recovery attempt; the agent owns the persistent budget.
    private func recoverChannel() throws {
        let ownership=observeProcesses(runtime)
        let generation=try liveGeneration(ownership)
        let connections=try usbObservation()
        if let capturedUSB,connections != [capturedUSB] {
            if connections.isEmpty { try releaseCapture(); return }
            throw VMEngineError.safety("USB-контекст изменился при потере SSH")
        }
        try checkCancellation()
        // A successful authenticated request proves the channel before any action.
        _ = try ssh(generation,"true",timeout:10)
        try health()
    }

    private func recoverServices(_ names:[String]) throws {
        let allowed=Set(["aksusbd_x86_64","hasplmd_x86_64","rmlic"])
        guard !names.isEmpty,Set(names).isSubset(of:allowed) else { throw VMEngineError.message("Неизвестная отказавшая служба") }
        let generation=try liveGeneration()
        _ = try usbObservation()
        // Refresh the safety precondition before touching any guest service.
        let result=try guestObservation(generation)
        guard result["status"] as? String == "ok",result["no_auto_fwup"] as? String == "1" else { throw VMEngineError.safety("Защита прошивки не подтверждена") }
        let failed=Set(result["failedServices"] as? [String] ?? [])
        if names.contains(where:failed.contains) {
            // The admitted recovery already owns this expected service change.
            serviceObserver?.terminationHandler=nil;serviceObserver?.terminate();serviceObserver=nil
        }
        for name in names where failed.contains(name) {
            try checkCancellation()
            let script=try Data(contentsOf:resources.appendingPathComponent("guest/alpine_service.sh"))
            _ = try ssh(generation,"sudo sh -s -- restart-service " + name,input:script,timeout:30)
            if name == "rmlic" { _ = try ssh(generation,"sudo /usr/local/bin/keybridge-rmlic-ready 30",timeout:40) }
        }
        try health()
    }

    private func armRuntimeObservers(_ generation:URL) throws {
        if let subscribeRuntimeChanges { try subscribeRuntimeChanges(generation);return }
        if qmpTransport == nil { _ = try qmp("query-status",observe:true) }
        try armServiceObserver(generation)
    }

    /// Called on the serialized executor, including before expected shutdown.
    private func stopQMPObserver() {
        qmpLock.lock();defer { qmpLock.unlock() }
        if let fd=observedQMP { Darwin.shutdown(fd,SHUT_RDWR) }
        qmpObserver?.cancel();qmpObserver=nil;observedQMP=nil
        qmpReadBuffer.removeAll();qmpObservationLost=false
    }

    /// The QMP chardev has one client. Reuse its connection for commands and
    /// consume asynchronous frames only while no command owns the read lock.
    private func observeQMP(_ fd:Int32) {
        let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:DispatchQueue.global(qos:.utility))
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.qmpLock.lock()
            guard self.observedQMP==fd,self.qmpObserver?.isCancelled == false else { self.qmpLock.unlock();return }
            var bytes=[UInt8](repeating:0,count:16384)
            let count=Darwin.read(fd,&bytes,bytes.count)
            var lost=false
            if count>0 {
                self.qmpReadBuffer.append(contentsOf:bytes.prefix(count))
                if let newline=self.qmpReadBuffer.lastIndex(of:10) { self.qmpReadBuffer.removeSubrange(...newline) }
                lost=self.qmpReadBuffer.count>2*1024*1024
            } else if count==0 || (errno != EAGAIN && errno != EINTR) { lost=true }
            if lost {
                self.qmpObservationLost=true
                self.qmpObserver?.cancel();self.qmpObserver=nil;self.observedQMP=nil
                self.qmpReadBuffer.removeAll()
            }
            self.qmpLock.unlock()
            if lost { self.runtimeChanged?() }
        }
        observedQMP=fd;qmpObserver=source
        source.resume()
    }

    /// A blocking guest pidfd subscription detects exits without periodic checks.
    /// The SSH process also ends when the VM or its channel disappears.
    private func armServiceObserver(_ generation:URL) throws {
        if let observer=serviceObserver,!observer.isRunning { serviceObserver=nil }
        guard guestTransport == nil,serviceObserver == nil else { return }
        let script=try Data(contentsOf:resources.appendingPathComponent("guest/health.py"))
        let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/ssh")
        process.arguments=sshOptions(generation)+["sudo -n python3 - --watch-services"]
        process.standardInput=input;process.standardOutput=output;process.standardError=errors
        process.terminationHandler={ [weak self] _ in self?.runtimeChanged?() }
        try process.run()
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        let errorFD=errors.fileHandleForReading.fileDescriptor
        _ = fcntl(errorFD,F_SETFL,O_NONBLOCK)
        func failure(_ reason:String)->VMEngineError {
            var bytes=[UInt8](repeating:0,count:2048)
            let count=Darwin.read(errorFD,&bytes,bytes.count)
            let detail=count>0 ? String(decoding:bytes.prefix(count),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines) : ""
            return .channel(reason + (detail.isEmpty ? "" : ": " + detail))
        }
        var armed=false
        defer {
            if !armed { process.terminationHandler=nil; if process.isRunning { process.terminate() } }
        }
        try input.fileHandleForWriting.write(contentsOf:script)
        try input.fileHandleForWriting.close()
        let fd=output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        // Real service recovery can delay this handshake beyond 10 seconds.
        // Use the same finite bound as ordinary guest commands.
        let deadline=ProcessInfo.processInfo.systemUptime + 40
        var line=Data(),byte:UInt8=0
        while line.count<4096 {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime<deadline else { throw failure("Истёк срок подтверждения подписки на события служб") }
            var descriptor=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            if Darwin.poll(&descriptor,1,50)<=0 { continue }
            let count=Darwin.read(fd,&byte,1)
            if count<0 && (errno==EAGAIN || errno==EINTR) { continue }
            guard count==1 else { throw failure("Наблюдатель служб завершился до подтверждения подписки") }
            if byte==10 { break };line.append(byte)
        }
        guard let result=(try?JSONSerialization.jsonObject(with:line)) as? [String:Any] else { throw VMEngineError.channel("Неизвестный ответ наблюдателя служб") }
        if let failed=result["failedServices"] as? [String],!failed.isEmpty { throw VMEngineError.services(failed) }
        guard result["watching"] as? Bool == true else { throw VMEngineError.channel("Наблюдатель служб не подтвердил подписку") }
        serviceObserver=process
        armed=true
    }

    /// Reuses all safety observations in one guest interpreter/SSH connection.
    /// A steady observation never repeats capture or waits for hotplug delivery.
    private func observeAttachedKey(_ generation: URL, wait: TimeInterval) throws {
        guard let captured=capturedUSB else { throw VMEngineError.safety("Подключение ключа не подтверждено") }
        func requireSameUSB() throws {
            let connections: [USBConnection]
            do { connections=try currentUSBConnections() }
            catch { throw VMEngineError.safety("Наблюдение USB недоступно") }
            guard connections.count <= 1 else { throw VMEngineError.safety("Найдено несколько ключей") }
            guard connections == [captured] else { throw VMEngineError.message("Подключение USB изменилось; ожидается новое событие") }
        }
        try requireSameUSB()
        let deadline=Date().addingTimeInterval(wait)
        while true {
            try checkCancellation()
            let result=try guestObservation(generation)
            guard result["status"] as? String == "ok",result["no_auto_fwup"] as? String == "1",
                  let keys=result["keys"] as? [[String:Any]],keys.count<=1 else {
                throw VMEngineError.safety("Защита прошивки или сведения о ключе не подтверждены")
            }
            try requireSameUSB()
            if let failed=result["failedServices"] as? [String], !failed.isEmpty { throw VMEngineError.services(failed) }
            let tree=try qmp("human-monitor-command",["command-line":"info qtree"]) as? String ?? ""
            guard USBTransfer.matches(tree,connection:captured) else { throw VMEngineError.safety("QMP не подтверждает выбранное подключение ключа") }
            if keys.count==1,result["services"] as? Bool == true,result["managerReady"] as? Bool == true,result["hotplug"] as? Bool == true {
                update(["status":"running","phase":"ready","running":true,"message":"Менеджер доступен. Проверьте получение лицензии в 1С.","keyConnected":true,"usbTransition":"captured","safetyReasonCode":NSNull(),"keyModel":keys[0]["typename"] ?? "Sentinel HL","keyType":"Локальный USB","firmware":keys[0]["firmware"] ?? "","keyConnection":captured.descriptor,"lastError":NSNull()])
                return
            }
            guard Date()<deadline else { throw VMEngineError.message("Драйвер, ключ или менеджер лицензий не подтвердили готовность") }
            Thread.sleep(forTimeInterval:0.5)
        }
    }

    public func stop() throws {
        update(["status":"stopping","busy":true,"message":"Остановка раздачи и освобождение ключа"])
        do {
            try stopVM()
            capturedUSB=nil
            update(["status":"stopped","phase":"ready","ownership":"absent","busy":false,"running":false,"keyConnected":false,"usbReleased":true,"message":"Раздача остановлена","lastProbe":NSNull()])
        } catch {
            let observation = observeProcesses(runtime)
            update(["status":"error","ownership":observation.name,"busy":false,"running":observation.running,"usbReleased":NSNull(),"lastProbe":NSNull(),"message":error.localizedDescription,"lastError":error.localizedDescription])
            throw error
        }
    }

    public func emergencyStop() {
        try? requestCancellation()
        let observation = observeProcesses(runtime)
        switch observation {
        case .absent:
            update(["status":"stopped","ownership":"absent","busy":false,"running":false,"usbReleased":true,"lastProbe":NSNull()])
        case .unknown(let reason):
            update(["status":"error","ownership":"unknown","busy":false,"running":NSNull(),"usbReleased":NSNull(),"message":reason,"lastProbe":NSNull()])
        case .owned(let identity, _, _):
            try? identity.signal(SIGTERM)
            for _ in 0..<10 { if observeProcesses(runtime).isAbsent { break }; pause(0.1) }
            if !observeProcesses(runtime).isAbsent { try? identity.signal(SIGKILL) }
            let final = observeProcesses(runtime)
            update(["status":final.isAbsent ? "stopped":"error","ownership":final.name,"busy":false,"running":final.running,"usbReleased":final.isAbsent ? true : NSNull(),"lastProbe":NSNull()])
        }
    }

    private func requireAbsent() throws {
        switch observeProcesses(runtime) {
        case .absent: return
        case .owned: throw VMEngineError.message("Сначала остановите свою работающую VM")
        case .unknown(let reason): throw VMEngineError.safety("Нельзя подтвердить отсутствие VM: " + reason)
        }
    }

    private func stoppedCleanup() {
        stopQMPObserver()
        serviceObserver?.terminationHandler=nil; serviceObserver?.terminate(); serviceObserver=nil
        child=nil; ownedGeneration=nil;capturedUSB=nil
        update(["usbTransition":"released","keyConnected":false])
        try? fm.removeItem(at:runtime.appendingPathComponent("active-vm.json"))
    }

    private func stopVM() throws {
        // Establish ownership before terminating our SSH observer. During its
        // exit macOS can transiently withhold its path and process metadata.
        let observation = observeProcesses(runtime)
        guard case .owned(let identity, let generation, _) = observation else {
            if observation.isAbsent { stoppedCleanup(); return }
            if case .unknown(let reason) = observation {
                throw VMEngineError.message("Остановка не подтверждена: " + reason)
            }
            throw VMEngineError.message("Остановка не подтверждена: принадлежность VM неизвестна")
        }
        stopQMPObserver()
        child?.terminationHandler=nil
        serviceObserver?.terminationHandler=nil; serviceObserver?.terminate(); serviceObserver=nil
        update(["usbTransition":"releasing","keyConnected":NSNull(),"lastProbe":NSNull()])
        // Shutdown must not depend on engine/preparation log writes. Disk full
        // can disable SSH's temporary output too; QMP and audit-token escalation
        // remain available independently.
        if let generation {
            let folder = runtime.appendingPathComponent("generations/" + generation)
            if let shutdownGuest { shutdownGuest(folder) }
            else { _ = try? hostCommand("/usr/bin/ssh", sshOptions(folder) + ["sudo poweroff"], timeout:8) }
        }
        _ = try? qmp("system_powerdown", cancellable:false)
        for _ in 0..<40 {
            if observeProcesses(runtime).isAbsent { stoppedCleanup(); return }
            pause(0.5)
        }
        try? Data("Unclean guest shutdown; inspect on next start.\n".utf8).write(to:runtime.appendingPathComponent("dirty-shutdown"),options:.atomic)
        _ = try? qmp("quit", cancellable:false)
        pause(0.2)
        if !observeProcesses(runtime).isAbsent { try? identity.signal(SIGTERM); pause(0.5) }
        if !observeProcesses(runtime).isAbsent { try? identity.signal(SIGKILL); pause(0.2) }
        guard observeProcesses(runtime).isAbsent else {
            throw VMEngineError.message("Не удалось подтвердить остановку VM и освобождение USB")
        }
        stoppedCleanup()
    }

    private func ownPID() -> pid_t? { observeProcesses(runtime).identity?.pid }

    func checkPort(_ port: Int, datagram:Bool = false) throws {
        let fd=Darwin.socket(AF_INET,datagram ? SOCK_DGRAM:SOCK_STREAM,0);guard fd>=0 else {throw VMEngineError.message("Не удалось проверить локальный порт.")};defer{Darwin.close(fd)}
        // Match QEMU's listener: closed connections may remain in TIME_WAIT
        // after a normal stop without another listener owning the endpoint.
        var reuse:Int32=1
        guard datagram || setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&reuse,socklen_t(MemoryLayout<Int32>.size))==0 else {
            throw VMEngineError.message("Не удалось проверить локальный порт.")
        }
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=in_port_t(port).bigEndian;address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        guard result==0 else {throw VMEngineError.message("Локальный порт \(port) уже используется.")}
    }

    func qmp(_ command: String,_ arguments:[String:Any]=[:],cancellable:Bool=true,observe:Bool=false) throws -> Any {
        let deadline=ProcessInfo.processInfo.systemUptime + qmpTimeout
        func checkpoint() throws {
            if cancellable { try checkCancellation() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VMEngineError.qmp("Истёк срок ответа QMP") }
        }
        try checkpoint()
        if let qmpTransport {
            do { let result=try qmpTransport(command,arguments);try checkpoint();return result }
            catch let error as VMEngineError {
                if case .cancelled=error { throw error }
                throw VMEngineError.qmp(error.localizedDescription)
            }
            catch { throw VMEngineError.qmp(error.localizedDescription) }
        }
        qmpLock.lock();defer { qmpLock.unlock() }
        guard !qmpObservationLost else { throw VMEngineError.qmp("Прервано наблюдение канала QMP; требуется освобождение USB") }
        guard ownPID() != nil else { throw VMEngineError.qmp("VM недоступна") }
        let reused=observedQMP != nil
        let fd=observedQMP ?? Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else { throw VMEngineError.qmp("Не удалось создать канал QMP") }
        var completed=false,retained=reused
        defer {
            if reused && !completed {
                qmpObserver?.cancel();qmpObserver=nil;observedQMP=nil
                qmpReadBuffer.removeAll();qmpObservationLost=true
            } else if !retained { Darwin.close(fd) }
        }
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        var noSignal:Int32=1
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        func ready(_ events:Int16) throws {
            while true {
                try checkpoint()
                var descriptor=pollfd(fd:fd,events:events,revents:0)
                let available=Darwin.poll(&descriptor,1,50)
                if available>0 {
                    guard descriptor.revents & Int16(POLLERR|POLLNVAL) == 0 else { throw VMEngineError.qmp("Ошибка канала QMP") }
                    return
                }
                if available<0 && errno != EINTR { throw VMEngineError.qmp("Ошибка ожидания QMP") }
            }
        }
        if !reused {
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(qmpPath.path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else { throw VMEngineError.qmp("Слишком длинный путь QMP") }
        withUnsafeMutableBytes(of:&address.sun_path){ $0.copyBytes(from:bytes) }
        let connected=withUnsafePointer(to:&address){ $0.withMemoryRebound(to:sockaddr.self,capacity:1){ Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw VMEngineError.qmp("Канал управления VM недоступен") }
            try ready(Int16(POLLOUT))
            var error:Int32=0,length=socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length)==0,error==0 else { throw VMEngineError.qmp("Не удалось подключиться к QMP") }
        }
        }
        func receive() throws -> [String:Any] {
            var data=qmpReadBuffer,byte:UInt8=0
            qmpReadBuffer.removeAll()
            while data.count<2*1024*1024 {
                try ready(Int16(POLLIN))
                let count=Darwin.read(fd,&byte,1)
                if count<0 && (errno==EAGAIN || errno==EINTR) { continue }
                guard count==1 else { throw VMEngineError.qmp("VM закрыла канал QMP") }
                if byte==10 {
                    guard let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { throw VMEngineError.qmp("Некорректный ответ QMP") }
                    return object
                }
                data.append(byte)
            }
            throw VMEngineError.qmp("Слишком большой ответ QMP")
        }
        if !reused { _ = try receive() }
        var result:Any=[:]
        for (identifier,operation) in ["qmp_capabilities",command].enumerated() {
            if reused && identifier==0 { continue }
            let request:[String:Any]=["execute":operation,"arguments":identifier==0 ? [:]:arguments,"id":identifier]
            var payload=try JSONSerialization.data(withJSONObject:request);payload.append(10)
            try payload.withUnsafeBytes { buffer in
                var sent=0
                while sent<buffer.count {
                    try ready(Int16(POLLOUT))
                    let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:sent),buffer.count-sent)
                    if count<0 && (errno==EAGAIN || errno==EINTR) { continue }
                    guard count>0 else { throw VMEngineError.qmp("Ошибка отправки QMP") }
                    sent+=count
                }
            }
            while true {
                let response=try receive()
                guard response["id"] as? Int == identifier else { continue }
                if let error=response["error"] as? [String:Any] { throw VMEngineError.qmp("VM отклонила команду: \(error["desc"] as? String ?? operation)") }
                result=response["return"] ?? [:];break
            }
        }
        if observe && !reused { observeQMP(fd);retained=true }
        completed=true
        return result
    }
}
