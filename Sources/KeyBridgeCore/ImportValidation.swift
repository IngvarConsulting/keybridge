// SPDX-License-Identifier: MIT
import Foundation

/// Inspect file contents without executing user-supplied Linux code on macOS.
/// Full package metadata is checked later inside the candidate VM, before USB capture.
public enum ImportValidation {
    static func check(installer: URL, driver: URL) throws {
        try checkInstaller(installer)
        guard try prefix(driver, count: 8) == Data("!<arch>\n".utf8) else {
            throw VMEngineError.message("Нужен DEB-пакет драйвера HASP для Linux amd64.")
        }
    }

    static func checkInstaller(_ installer: URL) throws {
        let elf = try prefix(installer, count: 64)
        guard elf.count == 64,
              Array(elf[0..<7]) == [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1],
              [UInt8(0), 3].contains(elf[7]),
              [UInt8(2), 3].contains(elf[16]), elf[17] == 0,
              elf[18] == 62, elf[19] == 0 else {
            throw VMEngineError.message("Нужен Linux x86-64 установщик 1С в формате ELF (.run).")
        }
    }

    public static func inspect(_ file: URL, kind: String) throws -> [String:Any] {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size=values.fileSize, size>0 else { throw BridgeError("Выберите обычный непустой файл.") }
        if kind == "installer" {
            try checkInstaller(file)
            return ["valid":true,"kind":kind,"name":file.lastPathComponent,"validation":"preliminary","architecture":"x86_64", "message":"Формат Linux x86-64 подходит. Наличие менеджера лицензий будет проверено при подготовке."]
        }
        guard kind == "driver",try prefix(file,count:8)==Data("!<arch>\n".utf8) else { throw BridgeError("Нужен DEB-пакет драйвера HASP для Linux amd64.") }
        let handle=try FileHandle(forReadingFrom:file);defer { try?handle.close() }
        try handle.seek(toOffset:8)
        var offset:UInt64=8
        var control:Data?
        while offset+60<=UInt64(size) {
            guard let header=try handle.read(upToCount:60),header.count==60,
                  String(data:header.suffix(2),encoding:.ascii)=="`\n",
                  let lengthText=String(data:header[48..<58],encoding:.ascii),let length=UInt64(lengthText.trimmingCharacters(in:.whitespaces)), length<=UInt64(size),offset+60+length<=UInt64(size) else { throw BridgeError("DEB-пакет повреждён или скачан не полностью.") }
            let name=String(decoding:header[0..<16],as:UTF8.self).trimmingCharacters(in:.whitespaces).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            if name=="control.tar" || name.hasPrefix("control.tar.") {
                guard length<=4*1024*1024 else { throw BridgeError("Метаданные DEB-пакета слишком велики.") }
                control=try handle.read(upToCount:Int(length));break
            }
            offset += 60+length+(length%2);try handle.seek(toOffset:offset)
        }
        guard let control else { throw BridgeError("В файле нет метаданных DEB-пакета. Выберите пакет aksusbd для amd64.") }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("keybridge-import-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(folder);defer{try?FileManager.default.removeItem(at:folder)}
        let archive=folder.appendingPathComponent("control.tar");try control.write(to:archive)
        let output=folder.appendingPathComponent("tar-output")
        func tar(_ args:[String]) throws -> HostCommandResult {
            try hostCommand("/usr/bin/tar",args,timeout:10,log:output,onPoll:{
                if let size=(try?FileManager.default.attributesOfItem(atPath:output.path)[.size]) as?NSNumber,size.int64Value>65536 {throw BridgeError("Метаданные пакета слишком велики.")}
            })
        }
        let list=try tar(["-tf",archive.path])
        guard list.code==0,!list.timedOut,let member=list.output.split(separator:"\n").first(where:{$0=="./control" || $0=="control"}) else { throw BridgeError("Не удалось прочитать метаданные драйвера. Скачайте пакет DEB заново.") }
        let result=try tar(["-xOf",archive.path,String(member)])
        guard result.code==0,!result.timedOut else { throw BridgeError("Не удалось прочитать метаданные драйвера.") }
        var fields=[String:String]()
        for line in result.output.split(separator:"\n") {
            let parts=line.split(separator:":",maxSplits:1)
            if parts.count==2 {fields[String(parts[0])]=String(parts[1]).trimmingCharacters(in:.whitespaces)}
        }
        guard fields["Package"]=="aksusbd" else { throw BridgeError("Выбран другой пакет. Нужен драйвер aksusbd для USB-ключа HASP.") }
        guard fields["Architecture"]=="amd64" else { throw BridgeError("Архитектура драйвера не подходит. Выберите пакет aksusbd для amd64.") }
        return ["valid":true,"kind":kind,"name":file.lastPathComponent,"validation":"preliminary","architecture":"amd64","version":fields["Version"] ?? "","message":"Пакет aksusbd для amd64 подходит. Полнота программ будет проверена при подготовке."]
    }

    private static func prefix(_ url: URL, count: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: count) ?? Data()
    }
}
