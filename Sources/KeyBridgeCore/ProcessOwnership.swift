// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// The kernel validates pidversion when signalling this token; PID reuse cannot
/// redirect an escalation to a different process. No bare kill(pid) is used here.
struct ProcessIdentity: Codable, Equatable {
    let audit: [UInt32]
    let executable: String
    var pid: pid_t { pid_t(audit[5]) }

    static func capture(_ pid: pid_t) throws -> ProcessIdentity {
        var port: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else {
            throw BridgeError("Не удалось подтвердить идентичность процесса \(pid)")
        }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw BridgeError("Audit token процесса недоступен") }
        let words = withUnsafeBytes(of: token) { Array($0.bindMemory(to: UInt32.self)) }
        guard words.count == 8, words[5] == UInt32(pid), words[1] == getuid() else {
            throw BridgeError("Процесс не принадлежит текущему пользователю")
        }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath_audittoken(&token, &path, UInt32(path.count)) > 0 else {
            throw BridgeError("Исполняемый файл процесса не подтверждён")
        }
        return ProcessIdentity(audit: words, executable: String(cString: path))
    }

    func signal(_ signal: Int32) throws {
        guard audit.count == 8, audit[1] == getuid(), audit[5] > 1 else {
            throw BridgeError("Повреждённая идентичность процесса")
        }
        var token = audit_token_t(val: (audit[0], audit[1], audit[2], audit[3], audit[4], audit[5], audit[6], audit[7]))
        // Dynamic lookup keeps older supported macOS installations fail-closed
        // if this kernel-validated API is unavailable.
        typealias Signal = @convention(c) (UnsafeMutablePointer<audit_token_t>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_signal_with_audittoken") else {
            throw BridgeError("Безопасное завершение процесса недоступно в этой macOS")
        }
        let call = unsafeBitCast(symbol, to: Signal.self)
        guard call(&token, signal) == 0 || errno == ESRCH else {
            throw BridgeError("Не удалось завершить подтверждённый процесс: \(String(cString: strerror(errno)))")
        }
    }
}

struct ProcessSnapshot {
    let identity: ProcessIdentity
    let arguments: [String]
}

enum VMOwnership {
    case absent
    case owned(ProcessIdentity, generation: String?, runID: String?)
    case unknown(String)
    var identity: ProcessIdentity? { if case .owned(let id, _, _) = self { return id }; return nil }
    var isAbsent: Bool { if case .absent = self { return true }; return false }
    var name: String { switch self { case .absent: return "absent"; case .owned: return "owned"; case .unknown: return "unknown" } }
}

/// Kernel process names remain readable when a running executable's vnode no
/// longer has a pathname (for example, an updater replaced the node binary).
/// They only filter unrelated candidates; they never establish VM ownership.
struct KernelProcessSummary {
    let pid:pid_t
    let uid:uid_t
    let status:UInt32
    let name:String
    let command:String
}

struct HostProcessInspector {
    static func executablePath(_ pid:pid_t)->String? {
        var bytes=[CChar](repeating:0,count:4096)
        guard proc_pidpath(pid,&bytes,UInt32(bytes.count))>0 else {return nil}
        return String(cString:bytes)
    }
    static func kernelSummary(_ pid:pid_t)->KernelProcessSummary? {
        var info=proc_bsdinfo()
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))==Int32(MemoryLayout<proc_bsdinfo>.size) else {return nil}
        func string<T>(_ tuple:inout T)->String {
            withUnsafeBytes(of:&tuple) { bytes in String(decoding:bytes.prefix(while:{$0 != 0}),as:UTF8.self) }
        }
        return KernelProcessSummary(pid:pid_t(info.pbi_pid),uid:info.pbi_uid,status:info.pbi_status,name:string(&info.pbi_name),command:string(&info.pbi_comm))
    }
    static func isQEMUCandidate(_ pid:pid_t,
                                path:(pid_t)->String?=executablePath,
                                summary:(pid_t)->KernelProcessSummary?=kernelSummary) throws ->Bool {
        if let value=path(pid) {return URL(fileURLWithPath:value).lastPathComponent=="qemu-system-x86_64"}
        if let info=summary(pid),info.pid==pid,info.uid==getuid() {
            // SZOMB: the process has exited and cannot retain an active USB VM.
            if info.status==UInt32(SZOMB) {return false}
            // Fail closed for QEMU, empty/contradictory names or unknown status.
            // Neither argv[0] nor a writable PID/status file is used as evidence.
            if [UInt32(SIDL),UInt32(SRUN),UInt32(SSLEEP),UInt32(SSTOP)].contains(info.status),
               !info.name.isEmpty,!info.command.isEmpty,info.name.hasPrefix(info.command),
               !info.name.lowercased().hasPrefix("qemu"),!info.command.lowercased().hasPrefix("qemu") {return false}
        }
        if kill(pid,0) != 0 && errno==ESRCH {return false}
        throw BridgeError("Не удалось проверить возможный процесс QEMU \(pid)")
    }
    static func arguments(_ pid: pid_t) throws -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 4 * 1024 * 1024 else {
            throw BridgeError("Аргументы процесса недоступны")
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { throw BridgeError("Аргументы процесса изменились") }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 32768 else { throw BridgeError("Неизвестный формат аргументов процесса") }
        var offset = 4
        while offset < size && bytes[offset] != 0 { offset += 1 } // executable path
        while offset < size && bytes[offset] == 0 { offset += 1 }
        var result = [String]()
        for _ in 0..<argc {
            let start = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            guard offset < size else { throw BridgeError("Неполный снимок аргументов процесса") }
            result.append(String(decoding: bytes[start..<offset], as: UTF8.self)); offset += 1
        }
        return result
    }

    static func processes(runtime:URL) throws -> [ProcessSnapshot] {
        var capacity = max(1024, Int(proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)) / MemoryLayout<pid_t>.size + 128)
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { throw BridgeError("Не удалось перечислить процессы пользователя") }
            if Int(bytes) >= pids.count * MemoryLayout<pid_t>.size { capacity *= 2; continue }
            var result = [ProcessSnapshot]()
            for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
                guard try isQEMUCandidate(pid) else {continue}
                let args:[String]
                do { args=try arguments(pid) }
                catch { if kill(pid,0) != 0 && errno==ESRCH { continue };throw error }
                let endpoint="unix:\(runtime.appendingPathComponent("qmp.sock").path),server=on,wait=off"
                guard args.indices.contains(where:{args[$0]=="-qmp" && $0+1<args.count && args[$0+1]==endpoint}) else { continue }
                let id = try ProcessIdentity.capture(pid)
                guard try arguments(pid)==args,try ProcessIdentity.capture(pid) == id else { throw BridgeError("Идентичность QEMU изменилась") }
                result.append(ProcessSnapshot(identity: id, arguments: args))
            }
            return result
        }
        throw BridgeError("Список процессов не удалось получить целиком")
    }

    static func classify(_ processes: [ProcessSnapshot], runtime: URL) -> VMOwnership {
        let endpoint = "unix:\(runtime.appendingPathComponent("qmp.sock").path),server=on,wait=off"
        let matches = processes.filter { process in
            let args = process.arguments
            return args.indices.contains { args[$0] == "-qmp" && $0 + 1 < args.count && args[$0 + 1] == endpoint }
        }
        guard matches.count <= 1 else { return .unknown("Найдено несколько VM одного runtime") }
        guard let process = matches.first else { return .absent }
        guard process.identity.audit.count == 8,
              process.identity.audit[1] == getuid(),
              URL(fileURLWithPath: process.identity.executable).lastPathComponent == "qemu-system-x86_64" else {
            return .unknown("Идентичность исполняемого файла QEMU не подтверждена")
        }
        let diskPrefix = "file=" + runtime.appendingPathComponent("generations").path.replacingOccurrences(of: ",", with: ",,") + "/"
        guard process.arguments.contains(where: { $0.hasPrefix(diskPrefix) && $0.contains("/guest.qcow2,") }) else {
            return .unknown("QMP-путь занят процессом без подтверждённого диска поколения")
        }
        let disk = process.arguments.first { $0.hasPrefix(diskPrefix) } ?? ""
        let generation = String(disk.dropFirst(diskPrefix.count).prefix(while: { $0 != "/" }))
        guard UUID(uuidString: generation) != nil else { return .unknown("Поколение процесса не распознано") }
        let nameIndex = process.arguments.firstIndex(of: "-name")
        let name = nameIndex.flatMap { $0 + 1 < process.arguments.count ? process.arguments[$0 + 1] : nil }
        let runID = name.flatMap { $0.hasPrefix("keybridge-") ? String($0.dropFirst(10)) : nil }
        return .owned(process.identity, generation: generation, runID: runID.flatMap { UUID(uuidString: $0) != nil ? $0 : nil })
    }

    static func observe(runtime: URL) -> VMOwnership {
        do { return classify(try processes(runtime:runtime), runtime: runtime) }
        catch { return .unknown(error.localizedDescription) }
    }
}

/// Read-only live inventory for the app's cold-start state. Missing persisted
/// status or manifest files are not evidence that no VM exists.
public enum RuntimeOwnership {
    public static func observation(runtime:URL)->[String:Any] {
        switch HostProcessInspector.observe(runtime:runtime) {
        case .absent:return ["ownership":"absent","running":false]
        case .owned(_,let generation,let run):return ["ownership":"owned","running":true,"generation":generation ?? "","runID":run ?? ""]
        case .unknown(let reason):return ["ownership":"unknown","running":NSNull(),"ownershipError":reason]
        }
    }
}

/// Safety action and persistence are independent: a failed auxiliary write must
/// never bypass stop. Callers receive both failures instead of a fake success.
public enum StopTransaction {
    public static func perform(persist: () throws -> Void, stop: () throws -> Void) -> [String] {
        var errors = [String]()
        do { try persist() } catch { errors.append("Намерение остановки не сохранено: " + error.localizedDescription) }
        do { try stop() } catch { errors.append("Остановка не подтверждена: " + error.localizedDescription) }
        return errors
    }
}
