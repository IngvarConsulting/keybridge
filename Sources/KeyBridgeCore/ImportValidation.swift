// SPDX-License-Identifier: MIT
import Foundation

/// Content compatibility, not publisher authenticity. No user-supplied Linux
/// executable or package maintenance script is run by this native inspection.
public enum ImportValidation {
    static func check(installer: URL, driver: URL) throws {
        try checkInstaller(installer)
        guard try prefix(driver, count: 8) == Data("!<arch>\n".utf8) else {
            throw VMEngineError.message("Нужен DEB-пакет драйвера HASP для Linux amd64.")
        }
    }

    static func isInstaller(_ elf: Data) -> Bool {
        elf.count >= 64 && Array(elf[0..<7]) == [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1] &&
            [UInt8(0), 3].contains(elf[7]) && [UInt8(2), 3].contains(elf[16]) && elf[17] == 0 && elf[18] == 62 && elf[19] == 0
    }

    static func checkInstaller(_ installer: URL) throws {
        guard try isInstaller(prefix(installer, count: 64)) else {
            throw VMEngineError.message("Нужен Linux x86-64 установщик 1С в формате ELF (.run).")
        }
    }

    public static func inspect(_ file: URL, kind: String, cancelled: @escaping () -> Bool = { false }) throws -> [String:Any] {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw BridgeError("Выберите обычный непустой файл.") }
        if kind == "installer" {
            try checkInstaller(file)
            return ["valid":true,"kind":kind,"name":file.lastPathComponent,"validation":"preliminary","architecture":"x86_64", "message":"Формат Linux x86-64 подходит. Требуется проверка менеджера лицензий."]
        }
        guard kind == "driver", try prefix(file, count: 8) == Data("!<arch>\n".utf8) else { throw BridgeError("Нужен DEB-пакет драйвера HASP для Linux amd64.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keybridge-package-" + UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let budget = ImportReadBudget(cancelled: cancelled)
        let archives = try unpackDeb(file, size: size, directory: folder, budget: budget)
        let fields = try metadata(archives.control, budget: budget)
        guard fields["Package"] == "aksusbd" else { throw BridgeError("Выбран другой пакет. Нужен драйвер aksusbd для USB-ключа HASP.") }
        guard fields["Architecture"] == "amd64" else { throw BridgeError("Архитектура драйвера не подходит. Выберите пакет aksusbd для amd64.") }
        guard let version = fields["Version"], !version.isEmpty else { throw BridgeError("Метаданные драйвера повреждены. Скачайте DEB-пакет заново.") }
        try runtime(archives.data, budget: budget)
        return ["valid":true,"kind":kind,"name":file.lastPathComponent,"validation":"complete","architecture":"amd64","version":version,"message":"Проверены пакет aksusbd для amd64 и программы драйвера HASP."]
    }

    private static func unpackDeb(_ file: URL, size: Int, directory: URL, budget: ImportReadBudget) throws -> (control: URL, data: URL) {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try input.seek(toOffset: 8)
        var offset: UInt64 = 8
        var members = [String:URL]()
        while offset < UInt64(size) {
            try budget.check()
            guard offset + 60 <= UInt64(size), let header = try input.read(upToCount: 60), header.count == 60,
                  String(data: header.suffix(2), encoding: .ascii) == "`\n",
                  let text = String(data: header[48..<58], encoding: .ascii),
                  let length = UInt64(text.trimmingCharacters(in: .whitespaces)),
                  length <= UInt64(size), offset + 60 + length + (length % 2) <= UInt64(size) else { throw BridgeError("DEB-пакет повреждён или скачан не полностью.") }
            let name = String(decoding: header[0..<16], as: UTF8.self).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let role = name == "debian-binary" ? "format" : (name == "control.tar" || name.hasPrefix("control.tar.")) ? "control" : (name == "data.tar" || name.hasPrefix("data.tar.")) ? "data" : ""
            guard !role.isEmpty, members[role] == nil, length <= (role == "data" ? 2 * 1024 * 1024 * 1024 : 4 * 1024 * 1024) else { throw BridgeError("Структура DEB-пакета не подходит. Скачайте пакет aksusbd для amd64 заново.") }
            try budget.checkSpace(directory, bytes: Int64(length))
            let target = directory.appendingPathComponent(role)
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw BridgeError("Не удалось прочитать DEB-пакет.") }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            var remaining = length
            while remaining > 0 {
                guard let bytes = try input.read(upToCount: Int(min(remaining, 256 * 1024))), !bytes.isEmpty else { throw BridgeError("DEB-пакет скачан не полностью.") }
                try budget.consume(bytes.count)
                try budget.checkSpace(directory, bytes: Int64(bytes.count))
                try output.write(contentsOf: bytes)
                remaining -= UInt64(bytes.count)
            }
            try output.close()
            members[role] = target
            offset += 60 + length + length % 2
            try input.seek(toOffset: offset)
        }
        guard let format = members["format"], try Data(contentsOf: format) == Data("2.0\n".utf8),
              let control = members["control"], let data = members["data"] else { throw BridgeError("В файле нет полного DEB-пакета. Выберите пакет aksusbd для amd64.") }
        return (control, data)
    }

    private static func metadata(_ archive: URL, budget: ImportReadBudget) throws -> [String:String] {
        let reader = try ImportArchiveReader(archive)
        var control: Data?
        var paths = Set<String>()
        while let entry = try reader.next() {
            let path = try entry.safePath()
            try budget.addEntry(entry.size)
            guard paths.insert(path).inserted, entry.isDirectory || entry.isRegular else { throw BridgeError("Метаданные DEB-пакета повреждены.") }
            if entry.isDirectory { continue }
            var data = Data()
            var length: Int64 = 0
            while true {
                let bytes = try reader.read(upTo: 64 * 1024)
                if bytes.isEmpty { break }
                try budget.consume(bytes.count)
                length += Int64(bytes.count)
                guard length <= 4 * 1024 * 1024 else { throw BridgeError("Метаданные пакета слишком велики.") }
                if path == "control" {
                    guard length <= 65536 else { throw BridgeError("Метаданные пакета слишком велики.") }
                    data.append(bytes)
                }
            }
            guard length == entry.size else { throw BridgeError("Метаданные DEB-пакета скачаны не полностью.") }
            if path == "control" { control = data }
        }
        guard let control, let text = String(data: control, encoding: .utf8) else { throw BridgeError("Не удалось прочитать метаданные драйвера. Скачайте DEB-пакет заново.") }
        var fields = [String:String]()
        for line in text.split(separator: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fields[key] == nil else { throw BridgeError("В метаданных драйвера повторяются поля. Скачайте DEB-пакет заново.") }
            fields[key] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fields
    }

    private static func runtime(_ archive: URL, budget: ImportReadBudget) throws {
        let reader = try ImportArchiveReader(archive)
        let required: Set<String> = ["usr/sbin/aksusbd_x86_64", "usr/sbin/hasplmd_x86_64"]
        var found = Set<String>(), paths = Set<String>()
        while let entry = try reader.next() {
            let path = try entry.safePath()
            try budget.addEntry(entry.size)
            guard paths.insert(path).inserted else { throw BridgeError("В драйвере повторяются имена файлов. Скачайте DEB-пакет заново.") }
            if let link = entry.link {
                // Other package links may be relative, but cannot escape its root.
                guard !link.hasPrefix("/"), !link.contains("\\"), !link.split(separator: "/").contains(".."), !required.contains(path) else { throw BridgeError("Драйвер содержит неподходящие ссылки вместо программ. Выберите другой DEB-пакет aksusbd.") }
                continue
            }
            guard entry.isRegular || entry.isDirectory else { throw BridgeError("Драйвер содержит специальные файлы. Выберите другой DEB-пакет aksusbd.") }
            if entry.isDirectory { continue }
            var prefix = Data(), length: Int64 = 0
            while true {
                let bytes = try reader.read(upTo: 256 * 1024)
                if bytes.isEmpty { break }
                try budget.consume(bytes.count)
                if prefix.count < 64 { prefix.append(bytes.prefix(64 - prefix.count)) }
                length += Int64(bytes.count)
            }
            guard length == entry.size else { throw BridgeError("Программы драйвера скачаны не полностью. Скачайте DEB-пакет заново.") }
            if required.contains(path) {
                guard entry.mode & 0o111 != 0, isInstaller(prefix) else { throw BridgeError("В драйвере нет исполняемых программ HASP для Linux x86-64. Выберите другой пакет aksusbd для amd64.") }
                found.insert(path)
            }
        }
        guard found == required else { throw BridgeError("В пакете отсутствуют программы драйвера HASP. Выберите полный DEB-пакет aksusbd для amd64.") }
    }

    static func prefix(_ url: URL, count: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: count) ?? Data()
    }
}
