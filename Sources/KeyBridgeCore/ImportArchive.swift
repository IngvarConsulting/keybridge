// SPDX-License-Identifier: MIT
import Foundation
import Darwin

public struct ImportCandidate: Sendable {
    public let file: URL
    public let displayName: String
    let revision:FileRevision?
    private let checkedKind:String?
    private let inspection:Data?
    init(file:URL,displayName:String,kind:String? = nil,result:[String:Any]? = nil,revision:FileRevision? = nil) throws {
        self.file=file;self.displayName=displayName;self.checkedKind=kind;self.revision=revision
        inspection=try result.map {try JSONSerialization.data(withJSONObject:$0)}
    }
    func requireUnchanged() throws {
        if let revision,FileRevision(file) != revision { throw BridgeError("Проверенный файл изменился. Выберите установщик или драйвер заново.") }
    }
    func validation(kind:String)throws->[String:Any]? {
        try requireUnchanged()
        guard kind==checkedKind,let inspection else {return nil}
        return try JSONSerialization.jsonObject(with:inspection) as? [String:Any]
    }
}

/// Only generated names are written to disk. Archive paths are labels, never
/// filesystem destinations. The source and its scripts are never modified/run.
public enum ImportArchive {
    public static func resolve(_ source: URL, kind: String, directory: URL,
                               cancelled: @escaping () -> Bool = { false }) throws -> [ImportCandidate] {
        guard ["installer", "driver"].contains(kind) else { throw BridgeError("Неизвестный тип компонента.") }
        try BridgePaths.preparePrivateDirectory(directory)
        let budget = ImportReadBudget(cancelled: cancelled)
        var candidates = [ImportCandidate]()
        var rejected = [String]()
        func accept(_ file: URL, label: String) throws {
            do {
                guard let before=FileRevision(file) else {throw BridgeError("Извлечённый файл недоступен")}
                let result=try ImportValidation.inspect(file, kind: kind, cancelled: cancelled)
                guard FileRevision(file)==before else {throw BridgeError("Файл изменился во время проверки. Выберите его заново.")}
                candidates.append(try ImportCandidate(file:file,displayName:label,kind:kind,result:result,revision:before))
            } catch {
                if cancelled() { throw VMEngineError.cancelled }
                rejected.append(error.localizedDescription)
                try? FileManager.default.removeItem(at: file)
            }
        }
        func explore(_ archive: URL, label: String, depth: Int) throws {
            guard depth <= 4 else { throw BridgeError("В архиве слишком много уровней вложенности. Выберите архив отдельного компонента.") }
            let reader = try ImportArchiveReader(archive)
            var paths = Set<String>()
            while let entry = try reader.next() {
                try budget.check()
                let path = try entry.safePath()
                guard paths.insert(path).inserted else { throw BridgeError("В архиве повторяются имена файлов. Скачайте дистрибутив заново.") }
                try budget.addEntry(entry.size)
                guard entry.isRegular || entry.isDirectory else { throw BridgeError("Архив содержит ссылки или специальные файлы. Выберите архив с обычными файлами компонентов.") }
                if entry.isDirectory { continue }
                let prefix = try reader.read(upTo: 512)
                try budget.consume(prefix.count)
                let component = kind == "installer" ? ImportValidation.isInstaller(prefix) : prefix.starts(with: Data("!<arch>\n".utf8))
                let nested = isArchive(prefix)
                let output = (component || nested) ? directory.appendingPathComponent(UUID().uuidString + (component ? (kind == "installer" ? ".run" : ".deb") : ".archive")) : nil
                var writer: FileHandle?
                if let output {
                    try budget.checkSpace(directory, bytes: max(0, entry.size))
                    guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw BridgeError("Не удалось сохранить файл из архива.") }
                    writer = try FileHandle(forWritingTo: output)
                }
                do {
                    if writer != nil { try budget.checkSpace(directory, bytes: Int64(prefix.count)) }
                    try writer?.write(contentsOf: prefix)
                    var total = Int64(prefix.count)
                    while true {
                        let bytes = try reader.read(upTo: 256 * 1024)
                        if bytes.isEmpty { break }
                        try budget.consume(bytes.count)
                        total += Int64(bytes.count)
                        if writer != nil { try budget.checkSpace(directory, bytes: Int64(bytes.count)) }
                        try writer?.write(contentsOf: bytes)
                    }
                    try writer?.close(); writer = nil
                    if entry.size >= 0 && total != entry.size { throw BridgeError("Архив скачан не полностью. Скачайте его заново.") }
                    if let output {
                        let name = label + " → " + path
                        if component { try accept(output, label: name) }
                        else {
                            defer { try? FileManager.default.removeItem(at: output) }
                            try explore(output, label: name, depth: depth + 1)
                        }
                    }
                } catch {
                    try? writer?.close()
                    if let output { try? FileManager.default.removeItem(at: output) }
                    throw error
                }
            }
        }
        do {
            let file = try ImportSnapshot.copy(source, to: directory, cancelled: cancelled)
            let prefix = try ImportValidation.prefix(file, count: 512)
            if prefix.starts(with: Data([0x7f, 0x45, 0x4c, 0x46])) || prefix.starts(with: Data("!<arch>\n".utf8)) {
                try accept(file, label: source.lastPathComponent)
            } else {
                defer { try? FileManager.default.removeItem(at: file) }
                try explore(file, label: source.lastPathComponent, depth: 0)
            }
            guard !candidates.isEmpty else {
                if let reason = rejected.first { throw BridgeError(reason) }
                throw BridgeError(kind == "installer" ? "В архиве нет установщика 1С для Linux x86-64. Выберите полную поставку с менеджером лицензий." : "В архиве нет DEB-пакета aksusbd для amd64. Скачайте драйвер HASP для Linux Debian/Ubuntu.")
            }
            // Vendor archives may contain ELF launcher helpers alongside their
            // .run installer. The suffix is only a discovery preference; every
            // candidate still needs ELF validation and the real Linux preflight.
            // Renamed ELF installers remain selectable when there is no .run.
            if kind == "installer" {
                let installers = candidates.filter { $0.displayName.lowercased().hasSuffix(".run") }
                if !installers.isEmpty {
                    let retained = Set(installers.map(\.file))
                    for candidate in candidates where !retained.contains(candidate.file) {
                        try? FileManager.default.removeItem(at: candidate.file)
                    }
                    return installers
                }
            }
            return candidates
        } catch {
            for candidate in candidates { try? FileManager.default.removeItem(at: candidate.file) }
            throw error
        }
    }

    private static func isArchive(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        return bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4b, 0x05, 0x06]) ||
            bytes.starts(with: [0x1f, 0x8b]) || bytes.starts(with: [0x42, 0x5a, 0x68]) ||
            bytes.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]) || bytes.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) ||
            (bytes.count >= 262 && Array(bytes[257..<262]) == Array("ustar".utf8))
    }
}

enum ImportSnapshot {
    static func copy(_ source: URL, to directory: URL, cancelled: @escaping () -> Bool) throws -> URL {
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw BridgeError("Не удалось открыть выбранный файл. Выберите обычный файл, а не ссылку.") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0 else { throw BridgeError("Выберите обычный непустой файл.") }
        let budget = ImportReadBudget(cancelled: cancelled)
        try budget.addEntry(before.st_size)
        try budget.checkSpace(directory, bytes: before.st_size)
        let target = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw BridgeError("Не удалось создать копию выбранного файла.") }
        let output = try FileHandle(forWritingTo: target)
        do {
            var copied: Int64 = 0
            while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try budget.consume(bytes.count)
                copied += Int64(bytes.count)
                guard copied <= before.st_size else { throw BridgeError("Файл изменился во время чтения. Дождитесь завершения скачивания и выберите его ещё раз.") }
                try budget.checkSpace(directory, bytes: Int64(bytes.count))
                try output.write(contentsOf: bytes)
            }
            try output.close()
            var after = stat()
            guard fstat(fd, &after) == 0, copied == before.st_size, after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw BridgeError("Файл изменился во время чтения. Выберите его ещё раз после завершения скачивания.") }
            return target
        } catch { try? output.close(); try? FileManager.default.removeItem(at: target); throw error }
    }
}

/// Resource limits are extraction safety bounds, not allowed product versions.
final class ImportReadBudget {
    private var bytes: Int64 = 0
    private var entries = 0
    private let deadline = Date().addingTimeInterval(600)
    private let cancelled: () -> Bool
    init(cancelled: @escaping () -> Bool = { false }) { self.cancelled = cancelled }
    func check() throws {
        if cancelled() { throw VMEngineError.cancelled }
        if Date() > deadline { throw BridgeError("Чтение архива заняло слишком много времени. Выберите архив отдельного компонента и повторите проверку.") }
    }
    func addEntry(_ size: Int64) throws {
        try check(); entries += 1
        guard entries <= 20000, size <= 8 * 1024 * 1024 * 1024 else { throw BridgeError("Архив слишком велик для проверки. Выберите архив отдельного компонента.") }
    }
    func consume(_ count: Int) throws {
        try check(); bytes += Int64(count)
        guard bytes <= 12 * 1024 * 1024 * 1024 else { throw BridgeError("Распакованный архив слишком велик. Выберите архив отдельного компонента.") }
    }
    func checkSpace(_ directory: URL, bytes: Int64) throws {
        guard try RuntimeResources.availableBytes(directory) >= bytes + 64 * 1024 * 1024 else { throw BridgeError("На Mac недостаточно места для распаковки. Освободите место и выберите файл ещё раз.") }
    }
}

struct ImportArchiveEntry {
    let path: String
    let size: Int64
    let mode: UInt32
    let link: String?
    var isRegular: Bool { mode & 0o170000 == 0o100000 && link == nil }
    var isDirectory: Bool { mode & 0o170000 == 0o040000 && link == nil }
    func safePath() throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !components.contains(".."), !components.isEmpty || isDirectory else { throw BridgeError("Архив содержит небезопасные пути. Скачайте дистрибутив заново.") }
        return components.joined(separator: "/")
    }
}

/// System libarchive is present on supported macOS versions. Dynamic binding
/// keeps the application self-contained without adding a package dependency.
final class ImportArchiveReader {
    private let api: ImportArchiveAPI
    private let archive: OpaquePointer
    init(_ file: URL) throws {
        api = try ImportArchiveAPI.shared.get()
        guard let archive = api.create() else { throw BridgeError("Не удалось открыть архив.") }
        self.archive = archive
        guard api.filters(archive) == 0, api.formats(archive) == 0,
              file.path.withCString({ api.open(archive, $0, 256 * 1024) }) == 0 else {
            _ = api.free(archive)
            throw BridgeError("Файл не является поддерживаемым ZIP/TAR-архивом или повреждён. Скачайте архив заново либо выберите файл компонента.")
        }
    }
    deinit { _ = api.free(archive) }
    func next() throws -> ImportArchiveEntry? {
        var entry: OpaquePointer?
        let code = api.next(archive, &entry)
        if code == 1 { return nil }
        guard code == 0, let entry, let raw = api.path(entry), let path = String(validatingUTF8: raw) else { throw BridgeError("Не удалось прочитать архив. Он повреждён, зашифрован или скачан не полностью.") }
        let link = api.symlink(entry) ?? api.hardlink(entry)
        return ImportArchiveEntry(path: path, size: api.size(entry), mode: api.mode(entry), link: link.map { String(cString: $0) })
    }
    func read(upTo count: Int) throws -> Data {
        var data = Data(count: count)
        let length = data.withUnsafeMutableBytes { api.read(archive, $0.baseAddress, count) }
        guard length >= 0 else { throw BridgeError("Данные в архиве повреждены или скачаны не полностью. Скачайте файл заново.") }
        data.count = length
        return data
    }
}

private final class ImportArchiveAPI {
    static let shared = Result { try ImportArchiveAPI() }
    private let library: UnsafeMutableRawPointer
    let create: @convention(c) () -> OpaquePointer?
    let filters: @convention(c) (OpaquePointer?) -> Int32
    let formats: @convention(c) (OpaquePointer?) -> Int32
    let open: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    let next: @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    let read: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    let free: @convention(c) (OpaquePointer?) -> Int32
    let path: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    let size: @convention(c) (OpaquePointer?) -> Int64
    let mode: @convention(c) (OpaquePointer?) -> UInt32
    let symlink: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    let hardlink: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private init() throws {
        guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw BridgeError("В macOS недоступен компонент чтения архивов.") }
        self.library = library
        func bind<T>(_ name: String, _: T.Type) throws -> T {
            guard let symbol = dlsym(library, name) else { throw BridgeError("В macOS недоступен компонент чтения архивов.") }
            return unsafeBitCast(symbol, to: T.self)
        }
        create = try bind("archive_read_new", type(of: create))
        filters = try bind("archive_read_support_filter_all", type(of: filters))
        formats = try bind("archive_read_support_format_all", type(of: formats))
        open = try bind("archive_read_open_filename", type(of: open))
        next = try bind("archive_read_next_header", type(of: next))
        read = try bind("archive_read_data", type(of: read))
        free = try bind("archive_read_free", type(of: free))
        path = try bind("archive_entry_pathname_utf8", type(of: path))
        size = try bind("archive_entry_size", type(of: size))
        mode = try bind("archive_entry_mode", type(of: mode))
        symlink = try bind("archive_entry_symlink", type(of: symlink))
        hardlink = try bind("archive_entry_hardlink", type(of: hardlink))
    }
    deinit { dlclose(library) }
}
