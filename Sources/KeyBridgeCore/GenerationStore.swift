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
    var writeSelection: ([String:Any],URL) throws -> Void = { try writeObject($0,to:$1) }
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
        guard let backend=guest["backend"] as? String,backend == "alpine",record["backend"] as? String == backend else {
            throw BridgeError("Backend поколения неизвестен; автоматический выбор Linux запрещён")
        }
        guard guest["memoryMiB"] as? Int == 128,guest["cpus"] as? Int == 1 else { throw BridgeError("Профиль Alpine не подтверждён") }
        for name in ["vmlinuz-virt","initramfs-virt"] { try regular(folder.appendingPathComponent(name)) }
        for name in ["guest.qcow2","id_ed25519","known_hosts"] { try regular(folder.appendingPathComponent(name)) }
        let disk=try FileHandle(forReadingFrom:folder.appendingPathComponent("guest.qcow2"));defer{try?disk.close()}
        guard try disk.read(upToCount:4)==Data([0x51,0x46,0x49,0xfb]) else { throw BridgeError("Формат диска поколения не подтверждён") }
        return PreparedGeneration(id:id,folder:folder,manifest:record,backend:backend)
    }
    private func readRecord(_ url:URL) throws ->[String:Any] {
        try regular(url)
        guard let record=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any],
              let id=record["generation"] as? String,UUID(uuidString:id) != nil else {throw BridgeError("Указатель поколения повреждён")}
        return record
    }
    private func selection() throws ->(current:[String:Any],previous:[String:Any]) {
        guard FileManager.default.fileExists(atPath:currentURL.path) else {return ([:],[:])}
        let current=try readRecord(currentURL)
        if let value=current["previous"] {
            if value is NSNull {return (current,[:])}
            guard let previous=value as? [String:Any] else {throw BridgeError("Указатель предыдущего поколения повреждён")}
            return (current,previous)
        }
        // Read the old two-file layout only until the first atomic migration.
        let legacy=runtime.appendingPathComponent("previous.json")
        return (current,FileManager.default.fileExists(atPath:legacy.path) ? try readRecord(legacy) : [:])
    }
    private func descriptor(_ record:[String:Any])->[String:Any] {
        var record=record;record.removeValue(forKey:"retained");record.removeValue(forKey:"previous");return record
    }
    func current() throws ->PreparedGeneration {
        guard FileManager.default.fileExists(atPath:currentURL.path) else { throw BridgeError("Сначала подготовьте среду из своих установщиков") }
        return try validate(readRecord(currentURL))
    }
    /// A single read-only observation. Validation is shared within this call,
    /// never across operations or before a later destructive action.
    func snapshot()->(current:PreparedGeneration?,summaries:[[String:Any]],presentation:[String:Any]) {
        let pair=(try? selection()) ?? (current:[:],previous:[:])
        let current=pair.current,previous=pair.previous
        var checked=[String:PreparedGeneration](),invalid=Set<String>()
        func inspect(_ record:[String:Any])->PreparedGeneration? {
            let key=(record["generation"] as? String ?? "")+":"+(record["backend"] as? String ?? "")
            if let value=checked[key] { return value }
            if invalid.contains(key) { return nil }
            guard let value=try?validate(record) else { invalid.insert(key);return nil }
            checked[key]=value;return value
        }
        let selected:PreparedGeneration?
        do { try regular(currentURL);selected=inspect(current) } catch { selected=nil }
        let previousValid=inspect(previous) != nil && previous["generation"] as? String != current["generation"] as? String
        let all=(current["retained"] as? [[String:Any]] ?? [])+[current,previous]+(previous["retained"] as? [[String:Any]] ?? [])
        var seen=Set<String>()
        let summaries:[[String:Any]]=all.compactMap { record in
            guard let id=record["generation"] as? String,UUID(uuidString:id) != nil,seen.insert(id).inserted else {return nil}
            return ["generation":id,"version":record["version"] ?? "","selected":id==current["generation"] as? String,
                    "valid":inspect(record) != nil,"backend":record["backend"] ?? "unknown"]
        }
        let presentation:[String:Any]=["currentVersion":current["version"] as? String ?? "","runtimeVersion":current["runtimeVersion"] as? String ?? "",
            "previousAvailable":previous["generation"] as? String != nil,"previousValid":previousValid,"previousGeneration":previous["generation"] as? String ?? ""]
        return (selected,summaries,presentation)
    }
    func records()->[[String:Any]] {
        let pair=(try? selection()) ?? (current:[:],previous:[:])
        let current=pair.current,previous=pair.previous
        var all=(current["retained"] as? [[String:Any]] ?? [])+[current,previous]
        all += previous["retained"] as? [[String:Any]] ?? []
        var seen=Set<String>()
        return all.compactMap { item in
            guard let id=item["generation"] as? String,UUID(uuidString:id) != nil,seen.insert(id).inserted else { return nil }
            return descriptor(item)
        }
    }
    func presentation()->[String:Any] {
        let pair=(try? selection()) ?? (current:[:],previous:[:])
        let current=pair.current,previous=pair.previous
        return ["currentVersion":current["version"] as? String ?? "", "runtimeVersion":current["runtimeVersion"] as? String ?? "",
                "previousAvailable":previous["generation"] as? String != nil,"previousValid":(try?validate(previous)) != nil && previous["generation"] as? String != current["generation"] as? String,
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
        let pair=try selection()
        if pair.current["generation"] as? String == record["generation"] as? String {return}
        var next=descriptor(record)
        next["retained"]=records().filter { $0["generation"] as? String != record["generation"] as? String }
        next["previous"]=pair.current.isEmpty ? NSNull() : descriptor(pair.current) as Any
        // Selection and its rollback target become visible in the same rename.
        try writeSelection(next,currentURL)
    }
    func rollback() throws ->PreparedGeneration {
        let pair=try selection()
        guard !pair.previous.isEmpty,
              pair.previous["generation"] as? String != pair.current["generation"] as? String else {
            throw BridgeError("Предыдущая установка недоступна; подготовьте её заново")
        }
        return try validate(pair.previous)
    }
}
