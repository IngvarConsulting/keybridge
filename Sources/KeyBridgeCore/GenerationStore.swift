// SPDX-License-Identifier: MIT
import Foundation
import Darwin

struct PreparedGeneration {
    let id:String
    let folder:URL
    let manifest:[String:Any]
    let backend:String
}

struct GenerationStore {
    let runtime:URL
    private var currentURL:URL { runtime.appendingPathComponent("current.json") }
    private func regular(_ url:URL) throws {
        var info=stat()
        guard lstat(url.path,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_uid==getuid() else {
            throw BridgeError("Файл поколения отсутствует или небезопасен: " + url.lastPathComponent)
        }
    }
    func validate(_ record:[String:Any]) throws ->PreparedGeneration {
        guard let id=record["generation"] as? String,UUID(uuidString:id) != nil else { throw BridgeError("Указатель поколения повреждён") }
        let folder=runtime.appendingPathComponent("generations/"+id)
        var info=stat()
        guard lstat(folder.path,&info)==0,(info.st_mode&S_IFMT)==S_IFDIR,info.st_uid==getuid() else { throw BridgeError("Каталог поколения недоступен") }
        try regular(folder.appendingPathComponent("guest.json"))
        let guest=readObject(folder.appendingPathComponent("guest.json"))
        guard let backend=guest["backend"] as? String,["alpine","debian"].contains(backend),record["backend"] as? String == backend else {
            throw BridgeError("Backend поколения неизвестен; автоматический выбор Linux запрещён")
        }
        if backend == "alpine" {
            guard guest["memoryMiB"] as? Int == 128,guest["cpus"] as? Int == 1 else { throw BridgeError("Профиль Alpine не подтверждён") }
            for name in ["vmlinuz-virt","initramfs-virt"] { try regular(folder.appendingPathComponent(name)) }
        }
        for name in ["guest.qcow2","id_ed25519","known_hosts"] { try regular(folder.appendingPathComponent(name)) }
        let disk=try FileHandle(forReadingFrom:folder.appendingPathComponent("guest.qcow2"));defer{try?disk.close()}
        guard try disk.read(upToCount:4)==Data([0x51,0x46,0x49,0xfb]) else { throw BridgeError("Формат диска поколения не подтверждён") }
        return PreparedGeneration(id:id,folder:folder,manifest:record,backend:backend)
    }
    func current() throws ->PreparedGeneration {
        guard FileManager.default.fileExists(atPath:currentURL.path) else { throw BridgeError("Сначала подготовьте среду из своих установщиков") }
        try regular(currentURL)
        return try validate(readObject(currentURL))
    }
    func records()->[[String:Any]] {
        let current=readObject(currentURL),previous=readObject(runtime.appendingPathComponent("previous.json"))
        var all=(current["retained"] as? [[String:Any]] ?? [])+[current,previous]
        all += previous["retained"] as? [[String:Any]] ?? []
        var seen=Set<String>()
        return all.compactMap { item in
            guard let id=item["generation"] as? String,UUID(uuidString:id) != nil,seen.insert(id).inserted else { return nil }
            var record=item;record.removeValue(forKey:"retained");return record
        }
    }
    func presentation()->[String:Any] {
        let current=readObject(currentURL),previous=readObject(runtime.appendingPathComponent("previous.json"))
        return ["currentVersion":current["version"] as? String ?? "", "runtimeVersion":current["runtimeVersion"] as? String ?? "",
                "previousAvailable":previous["generation"] as? String != nil,"previousValid":(try?validate(previous)) != nil,
                "previousGeneration":previous["generation"] as? String ?? ""]
    }
    func summaries()->[[String:Any]] {
        let selected=readObject(currentURL)["generation"] as? String
        return records().map { record in
            let validated=try?validate(record)
            return ["generation":record["generation"] ?? "","version":record["version"] ?? "",
                    "selected":record["generation"] as? String == selected,"valid":validated != nil,
                    "backend":record["backend"] ?? "unknown"]
        }
    }
    /// Registry and selected generation share one atomic pointer. Descriptors
    /// may be retained even when invalid, but can never be selected as valid.
    func publish(_ record:[String:Any]) throws {
        _=try validate(record)
        let old=readObject(currentURL)
        var next=record
        next["retained"]=records().filter { $0["generation"] as? String != record["generation"] as? String }
        if !old.isEmpty { try writeObject(old,to:runtime.appendingPathComponent("previous.json")) }
        try writeObject(next,to:currentURL)
    }
    func rollback(_ requested:String?) throws ->PreparedGeneration {
        let previous=readObject(runtime.appendingPathComponent("previous.json"))["generation"] as? String
        guard let id=requested ?? previous,UUID(uuidString:id) != nil,
              let record=records().first(where:{$0["generation"] as? String == id}) else { throw BridgeError("Сохранённое поколение не выбрано") }
        return try validate(record)
    }
}
