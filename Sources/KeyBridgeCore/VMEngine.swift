// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Darwin

public enum VMEngineError: Error, LocalizedError {
    case message(String)
    case cancelled
    case safety(String)
    public var errorDescription: String? {
        switch self {
        case .message(let value), .safety(let value): return value
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
    var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    public var operationCancelled: (() -> Bool)?
    public var publicationBarrier: (((() throws -> Void)) throws -> Void)?
    public var usbChanged:(()->Void)?
    public var stateSink: (([String:Any]) -> Void)?
    public var hasConnectionContext:Bool { usbMonitor != nil || observeUSB != nil }
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
                    "busy": false, "running": ownPID() != nil, "message": message,
                    "lastError": succeeded ? NSNull() : message as Any])
        }
    }

    public func status() -> [String: Any] {
        var result = readJSON(statePath) ?? [:]
        if result.isEmpty { result = ["status":"unprepared", "message":"Добавьте свои установщики", "busy":false, "running":false] }
        let observation = observeProcesses(runtime)
        result["ownership"] = observation.name
        result["running"] = observation.identity != nil
        if case .unknown(let reason) = observation { result["ownershipError"] = reason }
        let generation=try? GenerationStore(runtime:runtime).current()
        result["prepared"] = generation != nil
        result["generations"] = GenerationStore(runtime:runtime).summaries()
        result.merge(GenerationStore(runtime:runtime).presentation()){_,new in new}
        result["cpus"] = generation?.backend == "debian" ? 2 : 1
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
            case "rollback": try rollback(request["generation"] as? String)
            case "stop": try stop()
            case "attach": try attach()
            case "health": try health()
            case "licenseEvidence": return try licenseEvidence(request["baseline"] as? [String:Any])
            case "resources": return try resourceUsage()
            default: throw VMEngineError.message("Неизвестное действие: \(action)")
            }
            return status()
        } catch {
            var failure: [String: Any] = ["status":"error", "busy":false, "message":error.localizedDescription, "lastError":error.localizedDescription, "running":ownPID() != nil]
            if action == "prepare", let phase = readJSON(runtime.appendingPathComponent("preparation.json"))?["phase"] as? String { failure["phase"] = phase }
            update(failure)
            throw error
        }
    }

    private func update(_ values: [String: Any]) {
        var state = readJSON(statePath) ?? [:]
        for (key, value) in values { state[key] = value }
        state["updatedAt"] = ISO8601DateFormatter().string(from:Date())
        state["prepared"] = (try? GenerationStore(runtime:runtime).current()) != nil
        state["endpoint"] = "127.0.0.1:\(Self.managerPort)"
        state["platformVersion"] = version
        state["guestOS"] = readJSON(manifestPath)?["backend"] ?? "unknown"
        state["memoryMiB"] = readJSON(manifestPath)?["memoryMiB"] ?? 128
        do { try writeJSON(state,to:statePath) }
        catch { state["persistenceError"]=error.localizedDescription; fputs("KeyBridge status: \(error.localizedDescription)\n",stderr) }
        // Publish only this observation; never overwrite the agent's newer proof
        // with a historical result re-read from disk.
        var patch=values
        patch["prepared"]=state["prepared"]
        patch["persistenceError"]=state["persistenceError"]
        stateSink?(patch)
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
                "stage_imports":"Не удалось проверить импортированные установщики",
                "stage_verify_imports":"Не удалось проверить установщики в Alpine",
                "invalid_driver_package":"Выбранный файл не является исправным DEB-пакетом",
                "wrong_driver_package":"Нужен пакет драйвера HASP с именем aksusbd",
                "wrong_driver_architecture":"Нужен драйвер HASP для Linux amd64",
                "missing_driver_runtime":"В DEB-пакете отсутствуют программы aksusbd и hasplmd",
                "invalid_platform_installer":"Не удалось прочитать сведения установщика 1С",
                "missing_license_manager":"В установщике 1С отсутствует компонент lic_manager",
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

    private func preservePreviousManifest() throws {
        if let previous = readJSON(manifestPath) {
            try writeJSON(previous, to:runtime.appendingPathComponent("previous.json"))
        }
    }

    private func currentGeneration() throws -> URL {
        try GenerationStore(runtime:runtime).current().folder
    }

    private func publishCurrent(_ body: () throws -> Void) throws {
        try checkCancellation()
        if let publicationBarrier { try publicationBarrier(body) }
        else { try body() }
    }

    private func rollback(_ requested:String?) throws {
        try requireAbsent()
        let selected=try GenerationStore(runtime:runtime).rollback(requested)
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
        for path in [qmpPath,pidPath] { try? fm.removeItem(at:path) }
        let network="user,id=lan,restrict=\(installing && !isAlpine(generation) ? "off" : "on"),hostfwd=tcp:127.0.0.1:\(Self.sshPort)-:22,hostfwd=tcp:127.0.0.1:\(Self.managerPort)-:1544"
        func disk(_ name: String)->String { generation.appendingPathComponent(name).path.replacingOccurrences(of:",",with:",,") }
        let alpine = isAlpine(generation)
        let runID = UUID().uuidString
        var args=["-name","keybridge-" + runID,"-L",resources.appendingPathComponent("runtime/share/qemu").path,"-machine","q35",
                  "-accel",alpine ? "tcg,thread=single,tb-size=16" : "tcg,thread=multi","-cpu","max","-smp",alpine ? "1" : "2","-m",alpine ? "128" : "1024",
                  "-nodefaults","-display","none","-monitor","none","-serial","file:\(runtime.appendingPathComponent("logs/serial.log").path)",
                  "-qmp","unix:\(qmpPath.path),server=on,wait=off","-pidfile",pidPath.path,
                  "-drive","file=\(disk("guest.qcow2")),if=virtio,format=qcow2,discard=unmap",
                  "-netdev",network,"-device","virtio-net-pci,netdev=lan","-device","qemu-xhci,id=xhci"]
        if alpine {
            for name in ["seed.iso", "imports.iso"] where installing && fm.fileExists(atPath:generation.appendingPathComponent(name).path) {
                args += ["-drive","file=\(disk(name)),if=ide,media=cdrom,readonly=on"]
            }
            args += ["-kernel",generation.appendingPathComponent("vmlinuz-virt").path,
                     "-initrd",generation.appendingPathComponent("initramfs-virt").path,
                     "-append","root=/dev/vda rootfstype=ext4 rw console=ttyS0 modules=virtio_pci,virtio_blk,ext4"]
        } else {
            args += ["-drive","file=\(disk("seed.iso")),if=ide,media=cdrom,readonly=on"]
            if installing && fm.fileExists(atPath:generation.appendingPathComponent("imports.iso").path) { args += ["-drive","file=\(disk("imports.iso")),if=ide,media=cdrom,readonly=on"] }
        }
        let log=runtime.appendingPathComponent("logs/qemu.log"); if !fm.fileExists(atPath:log.path) { fm.createFile(atPath:log.path,contents:nil) }
        let handle=try FileHandle(forWritingTo:log); try handle.seekToEnd()
        let process=Process();process.executableURL=binary;process.arguments=args;process.standardInput=FileHandle.nullDevice;process.standardOutput=handle;process.standardError=handle
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
        case .absent: capturedUSB=nil
        case .unknown(let reason): throw VMEngineError.safety("Владелец VM не установлен: " + reason)
        }
        let generation=try currentGeneration()
        update(["status":"starting","phase":"boot","busy":true,"running":false,"message":"Запуск Linux и менеджера лицензий","lastError":NSNull(),"lastProbe":NSNull()])
        do {
            try launch(generation,installing:false)
            try awaitSSH(generation,timeout:420)
            let services = isAlpine(generation) ? "sudo /usr/local/sbin/keybridge-services start" : "sudo systemctl start aksusbd hasplmd keybridge-rmlic"
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
        if let guestTransport { return try guestTransport(generation,command,input) }
        return try run("/usr/bin/ssh",sshOptions(generation)+[command],input:input,timeout:timeout)
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

    private func liveGeneration() throws -> URL {
        guard case .owned(_, let generation?, _) = observeProcesses(runtime) else {
            throw VMEngineError.message("Поколение работающей VM не подтверждено")
        }
        return runtime.appendingPathComponent("generations/" + generation)
    }

    private func currentUSBConnections() throws ->[USBConnection] {
        if let observeUSB { return try observeUSB() }
        if usbMonitor == nil { usbMonitor=try USBMonitor(resources:resources,changed:{ [weak self] in self?.usbChanged?() }) }
        return try usbMonitor!.snapshot()
    }

    private func attach() throws {
        do { try attachChecked() }
        catch let error as VMEngineError {
            if case .cancelled=error { throw error }
            if case .safety=error { try?stopVM() }
            throw error
        }
    }

    private func attachChecked() throws {
        guard ownPID() != nil else { throw VMEngineError.message("VM не запущена.") }
        let generation=try liveGeneration()
        let connections:[USBConnection]
        do {
            connections=try currentUSBConnections()
        } catch { throw VMEngineError.safety("Состояние USB неизвестно: "+error.localizedDescription) }
        guard connections.count<=1 else { update(["safetyReasonCode":"multiple-keys"]);throw VMEngineError.safety("Несколько HASP-ключей: раздача прекращена") }
        if let capturedUSB,connections.first != capturedUSB {
            self.capturedUSB=nil
            throw VMEngineError.safety("Подключение ключа изменилось; требуется новый запуск")
        }
        // Use this app's read-only checker, including readiness fixes, for existing VMs too.
        guard let guardScript=try?Data(contentsOf:resources.appendingPathComponent("guest/sentinel_guard.py")) else {
            update(["safetyReasonCode":"firmware-unknown"]);throw VMEngineError.safety("Проверка защиты прошивки недоступна")
        }
        let guardJSON:String
        do { guardJSON=try ssh(generation,"python3 - check-config",input:guardScript,timeout:55) }
        catch { update(["safetyReasonCode":"firmware-unknown"]);throw VMEngineError.safety("Защита прошивки неизвестна: "+error.localizedDescription) }
        guard let data=guardJSON.data(using:.utf8), let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], result["status"] as? String == "ok", result["no_auto_fwup"] as? String == "1" else { update(["safetyReasonCode":"firmware-unknown"]);throw VMEngineError.safety("Запрет обновления прошивки ключа не подтверждён; раздача прекращена.") }
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
        let script=try Data(contentsOf:resources.appendingPathComponent("guest/key_info.py"))
        let keyDeadline = Date().addingTimeInterval(20)
        var keys = [[String: Any]]()
        repeat {
            try checkCancellation()
            let keysJSON=try ssh(generation,"python3 -",input:script,timeout:15)
            guard let data=keysJSON.data(using:.utf8), let info=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let observed=info["keys"] as? [[String:Any]] else { throw VMEngineError.safety("Runtime вернул неизвестный ответ о ключе.") }
            guard observed.count <= 1 else { update(["safetyReasonCode":"multiple-keys"]);throw VMEngineError.safety("Runtime обнаружил несколько ключей; выбор неоднозначен.") }
            keys = observed
            if keys.count == 1 { break }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < keyDeadline
        guard keys.count == 1 else {
            throw VMEngineError.message("Linux не подтвердил захват выбранного ключа за отведённое время")
        }
        if isAlpine(generation) {
            _ = try ssh(generation,"for i in $(seq 1 30); do if sudo test -L /dev/aks/hasp/* && sudo grep -Eq '^(add|bind|change) ' /run/keybridge/usb-events.log; then exit 0; fi; sleep 0.5; done; exit 1",timeout:25)
        }
        if let capturedUSB {
            let observedTree=try qmp("human-monitor-command",["command-line":"info qtree"]) as? String ?? ""
            guard USBTransfer.matches(observedTree,connection:capturedUSB) else { throw VMEngineError.safety("QMP не подтверждает выбранное подключение ключа") }
        }
        guard let capturedUSB,try currentUSBConnections().first == capturedUSB else { throw VMEngineError.safety("Эпоха подключения ключа изменилась") }
        _ = try ssh(generation,"sudo /usr/local/bin/keybridge-rmlic-ready 30",timeout:45)
        update(["status":"running","phase":"ready","busy":false,"running":true,"message":"Менеджер доступен. Проверьте получение лицензии в 1С.","keyConnected":true,"usbTransition":"captured","safetyReasonCode":NSNull(),"keyModel":keys[0]["typename"] ?? "Sentinel HL","keyType":"Локальный USB","firmware":keys[0]["firmware"] ?? "","keyConnection":capturedUSB.descriptor,"lastError":NSNull()])
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
        switch observeProcesses(runtime) {
        case .absent:
            update(["running":false,"busy":false,"status":"stopped","ownership":"absent","message":"Раздача остановлена","keyConnected":false]); return
        case .owned:
            let generation=try liveGeneration()
            if isAlpine(generation) {
                _ = try ssh(generation,"pidof rmlic >/dev/null && pidof hasplmd_x86_64 >/dev/null && pidof aksusbd_x86_64 >/dev/null",timeout:15)
            }
            try attach()
        case .unknown(let reason):
            update(["status":"error","ownership":"unknown","busy":false,"keyConnected":NSNull()])
            throw VMEngineError.safety("Состояние VM неизвестно: " + reason)
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
            update(["status":"error","ownership":observation.name,"busy":false,"running":observation.identity != nil,"usbReleased":NSNull(),"lastProbe":NSNull(),"message":error.localizedDescription,"lastError":error.localizedDescription])
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
            update(["status":"error","ownership":"unknown","busy":false,"usbReleased":NSNull(),"message":reason,"lastProbe":NSNull()])
        case .owned(let identity, _, _):
            try? identity.signal(SIGTERM)
            for _ in 0..<10 { if observeProcesses(runtime).isAbsent { break }; pause(0.1) }
            if !observeProcesses(runtime).isAbsent { try? identity.signal(SIGKILL) }
            let final = observeProcesses(runtime)
            update(["status":final.isAbsent ? "stopped":"error","ownership":final.name,"busy":false,"running":final.identity != nil,"usbReleased":final.isAbsent ? true : NSNull(),"lastProbe":NSNull()])
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
        child=nil; ownedGeneration=nil;capturedUSB=nil
        update(["usbTransition":"released","keyConnected":false])
        try? fm.removeItem(at:runtime.appendingPathComponent("active-vm.json"))
    }

    private func stopVM() throws {
        let observation = observeProcesses(runtime)
        guard case .owned(let identity, let generation, _) = observation else {
            if observation.isAbsent { stoppedCleanup(); return }
            throw VMEngineError.message("Остановка не подтверждена: принадлежность VM неизвестна")
        }
        update(["usbTransition":"releasing","keyConnected":NSNull(),"lastProbe":NSNull()])
        // Shutdown must not depend on engine/preparation log writes. Disk full
        // can disable SSH's temporary output too; QMP and audit-token escalation
        // remain available independently.
        if let generation {
            let folder = runtime.appendingPathComponent("generations/" + generation)
            if let shutdownGuest { shutdownGuest(folder) }
            else { _ = try? hostCommand("/usr/bin/ssh", sshOptions(folder) + ["sudo poweroff"], timeout:8) }
        }
        _ = try? qmp("system_powerdown")
        for _ in 0..<40 {
            if observeProcesses(runtime).isAbsent { stoppedCleanup(); return }
            pause(0.5)
        }
        try? Data("Unclean guest shutdown; inspect on next start.\n".utf8).write(to:runtime.appendingPathComponent("dirty-shutdown"),options:.atomic)
        _ = try? qmp("quit")
        pause(0.2)
        if !observeProcesses(runtime).isAbsent { try? identity.signal(SIGTERM); pause(0.5) }
        if !observeProcesses(runtime).isAbsent { try? identity.signal(SIGKILL); pause(0.2) }
        guard observeProcesses(runtime).isAbsent else {
            throw VMEngineError.message("Не удалось подтвердить остановку VM и освобождение USB")
        }
        stoppedCleanup()
    }

    private func ownPID() -> pid_t? { observeProcesses(runtime).identity?.pid }

    private func checkPort(_ port: Int) throws {
        let fd=Darwin.socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else {throw VMEngineError.message("Не удалось проверить локальный порт.")};defer{Darwin.close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=in_port_t(port).bigEndian;address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        guard result==0 else {throw VMEngineError.message("Локальный порт \(port) уже используется.")}
    }

    private func qmp(_ command: String,_ arguments:[String:Any]=[:]) throws -> Any {
        if let qmpTransport { return try qmpTransport(command, arguments) }
        guard ownPID() != nil else {throw VMEngineError.message("VM недоступна.")}
        let fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else {throw VMEngineError.message("Не удалось создать канал QMP.")};defer{Darwin.close(fd)}
        var seconds=timeval(tv_sec:8,tv_usec:0);setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&seconds,socklen_t(MemoryLayout<timeval>.size));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&seconds,socklen_t(MemoryLayout<timeval>.size))
        var noSignal:Int32=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(qmpPath.path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else {throw VMEngineError.message("Слишком длинный путь QMP.")}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard connected==0 else {throw VMEngineError.message("Канал управления VM недоступен.")}
        func receive() throws -> [String:Any] {
            var data=Data();var byte:UInt8=0
            while data.count<2*1024*1024 {
                guard Darwin.read(fd,&byte,1)==1 else {throw VMEngineError.message("VM не отвечает на команду управления.")}
                if byte==10 { return (try JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:] };data.append(byte)
            }
            throw VMEngineError.message("Слишком большой ответ QMP.")
        }
        _ = try receive()
        var result:Any=[:]
        for (identifier,operation) in ["qmp_capabilities",command].enumerated() {
            let request:[String:Any]=["execute":operation,"arguments":identifier==0 ? [:]:arguments,"id":identifier]
            var payload=try JSONSerialization.data(withJSONObject:request);payload.append(10)
            try payload.withUnsafeBytes { buffer in
                var sent=0
                while sent<buffer.count { let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:sent),buffer.count-sent);guard count>0 else {throw VMEngineError.message("Ошибка отправки команды VM.")};sent+=count }
            }
            while true {
                let response=try receive()
                guard response["id"] as? Int==identifier else {continue}
                if let error=response["error"] as? [String:Any] {throw VMEngineError.message("VM отклонила команду: \(error["desc"] as? String ?? operation)")}
                result=response["return"] ?? [:];break
            }
        }
        return result
    }

}
