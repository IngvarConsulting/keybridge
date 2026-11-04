// SPDX-License-Identifier: MIT
import Foundation
import Darwin
import CryptoKit

/// Selects a locally installed native client by capability, not a release allowlist.
/// Privileged configuration resolves the same root-owned installation; callers
/// never supply a configuration path to the helper.
public struct ClientInstallation {
    public let directory: URL
    var owner:uid_t = 0
    public var version: String { directory.lastPathComponent }
    public var executable: URL { directory.appendingPathComponent("1cv8") }
    public var configuration: URL { directory.appendingPathComponent("conf/nethasp.ini") }
    public func configurationDirectory() -> URL {directory.deletingLastPathComponent().appendingPathComponent("conf")}
    public func configurationFiles() -> [URL] {
        let folder=configurationDirectory()
        return [folder.appendingPathComponent("nethasp.ini"),folder.appendingPathComponent("rclic.cfg")]
    }
    public func configurationBackup(root:URL = URL(fileURLWithPath:"/Library/Application Support/KeyBridge-Configuration")) throws -> URL {
        let paths=configurationFiles().map(\.path).joined(separator:"\n")
        return root.appendingPathComponent("client-"+ConfigurationBackupMetadata.digest(Data(paths.utf8)))
    }
    public static let managedClientConfiguration=Data("ManagerAddress=127.0.0.1:15441\nBroadcastPort=\n".utf8)
    public static var managedConfigurations:[Data] {[managedConfiguration,managedClientConfiguration]}
    // Ignore comments and formatting, but do not assume unknown or additional
    // directives are equivalent to our configuration.
    static func configurationLines(_ data:Data) -> [String]? {
        guard let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) else {return nil}
        return text.replacingOccurrences(of:"\u{feff}",with:"").components(separatedBy:.newlines)
            .map {$0.trimmingCharacters(in:.whitespaces).lowercased()}
            .filter {!$0.isEmpty && !$0.hasPrefix(";") && !$0.hasPrefix("#")}
            .map {$0.components(separatedBy:"=").map {$0.trimmingCharacters(in:.whitespaces)}.joined(separator:"=")}
    }
    func configurationOverrides() throws -> [URL] {
        let root=directory.deletingLastPathComponent()
        let folders=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        var conflicts=[URL]()
        for folder in folders.sorted(by:{$0.path<$1.path}) where folder.lastPathComponent.range(of:"^[0-9]+(?:\\.[0-9]+)+$",options:.regularExpression) != nil {
            guard ["1cv8","1cv8c"].contains(where:{FileManager.default.isExecutableFile(atPath:folder.appendingPathComponent($0).path)}) else {continue}
            let conf=folder.appendingPathComponent("conf")
            var inspected=conf.appendingPathComponent("conf.cfg")
            do {
            guard Self.safeDirectory(folder,owner:owner) else {throw BridgeError("Не удалось проверить каталог версии 1С: " + folder.path)}
            for (name,expected) in zip(["nethasp.ini","rclic.cfg"],Self.managedConfigurations) {
                let file=conf.appendingPathComponent(name);var info=stat()
                inspected=file
                if lstat(file.path,&info) != 0 {
                    guard errno==ENOENT else {throw BridgeError("Не удалось проверить " + file.path)}
                    continue
                }
                guard Self.safeRegular(file,owner:owner) else {throw BridgeError("Небезопасный файл настройки: " + file.path)}
                if Self.configurationLines(try Data(contentsOf:file)) != Self.configurationLines(expected) {conflicts.append(file)}
            }
            let source=conf.appendingPathComponent("conf.cfg");var info=stat()
            inspected=source
            if lstat(source.path,&info)==0 {
                guard Self.safeRegular(source,owner:owner) else {throw BridgeError("Не удалось проверить " + source.path)}
                let data=try Data(contentsOf:source)
                guard let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) else {throw BridgeError("Не удалось прочитать " + source.path)}
                let locations=text.replacingOccurrences(of:"\u{feff}",with:"").components(separatedBy:.newlines).compactMap {line -> String? in
                    let parts=line.components(separatedBy:"=").map {$0.trimmingCharacters(in:.whitespaces)}
                    return parts.count==2 && parts[0].lowercased()=="conflocation" ? parts[1]:nil
                }
                if !locations.isEmpty {
                    let matches=locations.count==1 && locations[0].hasPrefix("/") && URL(fileURLWithPath:locations[0]).resolvingSymlinksInPath().path==configurationDirectory().resolvingSymlinksInPath().path
                    if !matches {conflicts.append(source)}
                }
            } else if errno != ENOENT {throw BridgeError("Не удалось проверить " + source.path)}
            } catch {conflicts.append(inspected)}
        }
        return conflicts
    }
    public static let root = URL(fileURLWithPath: "/opt/1cv8", isDirectory: true)
    public static let managedConfiguration = Data("""
    ; Managed by KeyBridge local pilot. Restore using the application.
    [NH_COMMON]
    NH_TCPIP=Enabled
    NH_IPX=Disabled
    NH_NETBIOS=Disabled
    [NH_TCPIP]
    NH_SERVER_ADDR=127.0.0.1
    NH_PORT_NUMBER=15441
    NH_TCPIP_METHOD=UDP
    NH_USE_BROADCAST=Disabled

    """.utf8)

    public static func discover(root: URL = root, owner: uid_t = 0) -> ClientInstallation? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return entries.filter { $0.lastPathComponent.range(of: "^[0-9]+(?:\\.[0-9]+)+$", options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .compactMap { folder -> ClientInstallation? in
                let candidate = ClientInstallation(directory: folder,owner:owner)
                guard safeRegular(candidate.executable, owner: owner), safeDirectory(folder, owner: owner),
                      FileManager.default.isExecutableFile(atPath: candidate.executable.path), supportsARM64(candidate.executable) else { return nil }
                return candidate
            }.first
    }

    public static func inspect() -> [String: Any] {
        inspect(discover())
    }
    public static func inspect(_ installation: ClientInstallation?) -> [String: Any] {
        guard let client = installation else { return ["clientState":"missing", "platformVersion":"", "platformPath":"", "clientRevision":"", "backupState":"missing", "backupAvailable":false] }
        var result: [String:Any] = ["platformVersion":client.version,"platformPath":client.executable.path]
        do {
            let targets=client.configurationFiles()
            var values=[Data?]()
            for target in targets {
                var info=stat()
                if lstat(target.path,&info) != 0 {
                    guard errno==ENOENT else {throw BridgeError("Не удалось проверить " + target.path)}
                    values.append(nil)
                } else {
                    guard Self.safeRegular(target,owner:client.owner) else {throw BridgeError("Небезопасный файл настройки: " + target.path)}
                    values.append(try Data(contentsOf:target))
                }
            }
            result["configurationDirectory"]=client.configurationDirectory().path
            result["configurationFiles"]=targets.map(\.path)
            result["clientState"]=values==managedConfigurations.map {Optional($0)} ? "configured" : values.allSatisfy {$0?.isEmpty != false} ? "unconfigured":"external"
            let revision=zip(targets,values).map {$0.path+":"+($1.map(ConfigurationBackupMetadata.digest) ?? "absent")}.joined(separator:"\n")
            let overrides=try client.configurationOverrides()
            result["clientRevision"]=ConfigurationBackupMetadata.digest(Data((revision+"\n"+overrides.map(\.path).joined(separator:"\n")).utf8))
            if !overrides.isEmpty {
                if overrides.contains(where:{$0.deletingLastPathComponent()==client.directory.appendingPathComponent("conf")}) {result["clientState"]="unknown"}
                result["configurationError"]="Использование общих настроек подтверждено не для всех версий. Проверьте отдельные настройки; KeyBridge их не изменяет:\n"+overrides.map(\.path).joined(separator:"\n")
            }
            let metadata=try client.configurationBackup().appendingPathComponent("metadata.json")
            var info=stat()
            if lstat(metadata.path,&info)==0 {result["backupState"]="available"}
            else {result["backupState"]=errno==ENOENT ? "missing":"unknown"}
        } catch {
            result["clientState"]="unknown";result["configurationError"]=error.localizedDescription
            result["backupState"]="unknown";result["clientRevision"]=""
        }
        result["backupAvailable"]=result["backupState"] as? String == "available"
        return result
    }

    static func safeRegular(_ url: URL, owner: uid_t) -> Bool { safe(url, type:S_IFREG, owner:owner) }
    static func safeDirectory(_ url: URL, owner: uid_t) -> Bool { safe(url, type:S_IFDIR, owner:owner) }
    private static func safe(_ url:URL,type:mode_t,owner:uid_t)->Bool {
        var info=stat()
        return lstat(url.path,&info)==0 && (info.st_mode&S_IFMT)==type && info.st_uid==owner && (info.st_mode&0o022)==0
    }
    static func supportsARM64(_ url:URL)->Bool {
        guard let file=try?FileHandle(forReadingFrom:url) else { return false }
        defer { try?file.close() }
        guard let data=try?file.read(upToCount:4096),data.count>=8 else { return false }
        func uint(_ at:Int,_ little:Bool)->UInt32 {
            let bytes=Array(data[at..<at+4]);return little ? bytes.reversed().reduce(0){($0<<8)|UInt32($1)} : bytes.reduce(0){($0<<8)|UInt32($1)}
        }
        if uint(0,false)==0xcffaedfe { return uint(4,true)==0x0100000c }
        let magic=uint(0,false)
        guard [UInt32(0xcafebabe),0xcafebabf,0xbebafeca,0xbfbafeca].contains(magic) else { return false }
        let little=magic==0xbebafeca || magic==0xbfbafeca,count=Int(uint(4,little)),stride=magic==0xcafebabf || magic==0xbfbafeca ? 32:20
        guard count>0,count<=64,8+count*stride<=data.count else { return false }
        return (0..<count).contains { uint(8+$0*stride,little)==0x0100000c }
    }
}

/// Cache file contents, never authority to change them. Privileged writes and
/// explicit client actions still discover and validate the installation afresh.
public final class ClientObservation {
    private let lock=NSLock()
    private let root:URL
    private let owner:uid_t
    private var signature:String?
    private var value=[String:Any]()
    public init(root:URL = ClientInstallation.root, owner:uid_t = 0) { self.root=root;self.owner=owner }
    public func read(force:Bool = false)->[String:Any] {
        lock.lock();defer { lock.unlock() }
        let backup=URL(fileURLWithPath:"/Library/Application Support/KeyBridge-Configuration")
        let folders=(try?FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []
        var paths=[root,backup,backup.appendingPathComponent("metadata.json")]
        for folder in folders {
            paths += [folder,folder.appendingPathComponent("1cv8"),folder.appendingPathComponent("1cv8c"),folder.appendingPathComponent("conf"),folder.appendingPathComponent("conf/conf.cfg"),folder.appendingPathComponent("conf/nethasp.ini"),folder.appendingPathComponent("conf/rclic.cfg"),backup.appendingPathComponent(folder.lastPathComponent+"/metadata.json")]
        }
        if let selected=ClientInstallation.discover(root:root,owner:owner) {
            let targets=selected.configurationFiles();paths += targets;paths += targets.map { $0.deletingLastPathComponent() }
            if let directory=try?selected.configurationBackup() {paths += [directory,directory.appendingPathComponent("metadata.json")]}
        }
        let next=paths.sorted{$0.path<$1.path}.map { path -> String in
            var s=stat()
            guard lstat(path.path,&s)==0 else {return path.path+":missing:\(errno)"}
            return "\(path.path):\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_uid):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
        }.joined(separator:"\n")
        if force || next != signature {
            value=ClientInstallation.inspect(ClientInstallation.discover(root:root,owner:owner));signature=next
        }
        return value
    }
}
