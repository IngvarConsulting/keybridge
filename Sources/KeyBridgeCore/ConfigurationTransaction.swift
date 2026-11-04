// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// The caller holds the configuration and agent commit locks. Pending records
/// are reconciled against actual target bytes before another mutation.
public struct ConfigurationTransaction {
    let targets:[URL]
    let backup:URL
    let expectedFiles:[Data]
    let verifyPath:(URL,Bool)throws->Void
    var writeFile:(Data,URL,mode_t)throws->Void = {data,url,mode in
        try data.write(to:url,options:.atomic)
        guard chmod(url.path,mode)==0 else {throw BridgeError("Не удалось установить права файла " + url.lastPathComponent)}
    }
    public init(target:URL,backup:URL,expected:Data,verifyPath:@escaping(URL,Bool)throws->Void) {
        self.init(targets:[target],backup:backup,expected:[expected],verifyPath:verifyPath)
    }
    public init(targets:[URL],backup:URL,expected:[Data],verifyPath:@escaping(URL,Bool)throws->Void) {
        precondition(!targets.isEmpty && targets.count == expected.count && Set(targets).count == targets.count)
        self.targets=targets;self.backup=backup;self.expectedFiles=expected;self.verifyPath=verifyPath
    }
    private var metadata:URL {backup.appendingPathComponent("metadata.json")}
    private var pending:URL {backup.appendingPathComponent("pending.json")}
    private func contents(_ url:URL)throws->Data? {
        try verifyPath(url,true)
        var info=stat()
        guard lstat(url.path,&info)==0 else {
            if errno==ENOENT {return nil}
            throw BridgeError("Не удалось проверить файл " + url.lastPathComponent)
        }
        guard (info.st_mode&S_IFMT)==S_IFREG else {throw BridgeError("Путь не является обычным файлом: " + url.lastPathComponent)}
        return try Data(contentsOf:url)
    }
    private func actual() throws -> [Data?] { try targets.map { try contents($0) } }
    private var expected:[Data?] { expectedFiles.map { Optional($0) } }
    private func record(_ url:URL)throws->(data:Data,original:[Data?],restoring:Bool) {
        guard let data=try contents(url),let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw BridgeError("Копия настроек отсутствует или повреждена")
        }
        let entries:[[String:Any]]
        if targets.count == 1,object["schemaVersion"] as? Int == 1 { entries=[object] }
        else if object["schemaVersion"] as? Int == 2,let files=object["files"] as? [[String:Any]],files.count==targets.count { entries=files }
        else { throw BridgeError("Копия не содержит полный набор настроек 1С") }
        var originals=[Data?]()
        for (index,entry) in entries.enumerated() {
            let info=try ConfigurationBackupMetadata(entry,expectedDigest:ConfigurationBackupMetadata.digest(expectedFiles[index]),target:targets[index].path)
            let originalURL=backup.appendingPathComponent(info.originalFile)
            let original=info.existed ? try contents(originalURL) : nil
            try info.verifyOriginal(original);originals.append(original)
        }
        return (data,originals,object["operation"] as? String == "restore")
    }
    private func restoreBytes(_ originals:[Data?]) throws {
        // Preflight the whole set: a conflict in one file forbids writing either.
        let observed=try actual()
        guard observed.indices.allSatisfy({observed[$0]==originals[$0] || observed[$0]==expected[$0]}) else {
            throw BridgeError("Настройки изменены вне KeyBridge; автоматический возврат запрещён. Файлы и копии сохранены.")
        }
        for index in targets.indices where observed[index] != originals[index] {
            guard try contents(targets[index])==observed[index] else { throw BridgeError("Настройки изменены во время возврата") }
            if let original=originals[index] {try writeFile(original,targets[index],0o644)}
            else {try FileManager.default.removeItem(at:targets[index])}
        }
        guard try actual()==originals else {throw BridgeError("Результат возврата настроек не подтверждён")}
    }
    private func reconcile() throws {
        guard try contents(pending) != nil else {return}
        let saved=try record(pending),observed=try actual()
        if saved.restoring {
            try restoreBytes(saved.original)
        } else if observed==expected {
            try writeFile(saved.data,metadata,0o600)
        } else if observed != saved.original {
            // A known partial installation is undone. Foreign bytes block all
            // writes; the previous completed restore point remains intact.
            try restoreBytes(saved.original)
        }
        try FileManager.default.removeItem(at:pending)
    }
    private func install(over originals:[Data?]) throws {
        var entries=[[String:Any]]()
        for index in targets.indices {
            let name="original-"+UUID().uuidString+".ini"
            if let original=originals[index] {try writeFile(original,backup.appendingPathComponent(name),0o600)}
            entries.append(["schemaVersion":1,"existed":originals[index] != nil,"originalFile":name,
                "originalSHA256":ConfigurationBackupMetadata.digest(originals[index] ?? Data()),
                "installedSHA256":ConfigurationBackupMetadata.digest(expectedFiles[index]),"target":targets[index].path])
        }
        let object:[String:Any]=targets.count==1 ? entries[0] : ["schemaVersion":2,"files":entries]
        let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        try writeFile(data,pending,0o600)
        _=try record(pending)
        guard try actual()==originals else {throw BridgeError("Настройки изменены во время подготовки копии; запись отменена")}
        do {
            for index in targets.indices where originals[index] != expected[index] {
                guard try contents(targets[index])==originals[index] else {throw BridgeError("Настройки изменены во время записи")}
                try writeFile(expectedFiles[index],targets[index],0o644)
            }
            guard try actual()==expected else {throw BridgeError("Результат записи настроек не подтверждён")}
            try writeFile(data,metadata,0o600)
            try FileManager.default.removeItem(at:pending)
        } catch {
            try? reconcile()
            throw error
        }
    }
    public func perform(_ action:String)throws->String {
        guard ["apply","repair","restore"].contains(action) else {throw BridgeError("Неизвестное действие настройки")}
        try reconcile()
        let old=try actual()
        if action=="restore" {
            guard try contents(metadata) != nil else {throw BridgeError("Достоверная копия прежних настроек недоступна. Текущие настройки не изменены.")}
            let saved=try record(metadata)
            if old==saved.original {return "restored"}
            // A mixture is accepted only by an existing pending restore, never
            // as an unjournalled external modification of a completed pair.
            guard old==expected else {throw BridgeError("Настройки изменены вне приложения; автоматический возврат запрещён")}
            var object=try JSONSerialization.jsonObject(with:saved.data) as! [String:Any]
            object["operation"]="restore"
            try writeFile(JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),pending,0o600)
            try reconcile()
            return "restored"
        }
        if old==expected {return "configured"}
        if action=="apply" {
            if try contents(metadata) != nil {
                guard old == (try record(metadata)).original else {throw BridgeError("Настройки изменены; требуется явное исправление поиска")}
            } else if old.contains(where:{$0?.isEmpty == false}) {
                throw BridgeError("У 1С уже есть настройки поиска лицензии. Требуется явное исправление; файлы не изменены.")
            }
        }
        try install(over:old)
        return "configured"
    }
}
