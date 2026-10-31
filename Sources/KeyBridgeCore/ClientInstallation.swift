// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// Selects a locally installed native client by capability, not a release allowlist.
/// Privileged configuration resolves the same root-owned installation; callers
/// never supply a configuration path to the helper.
public struct ClientInstallation {
    public let directory: URL
    public var version: String { directory.lastPathComponent }
    public var executable: URL { directory.appendingPathComponent("1cv8") }
    public var configuration: URL { directory.appendingPathComponent("conf/nethasp.ini") }
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
                let candidate = ClientInstallation(directory: folder)
                guard safeRegular(candidate.executable, owner: owner), safeDirectory(folder, owner: owner),
                      FileManager.default.isExecutableFile(atPath: candidate.executable.path), supportsARM64(candidate.executable) else { return nil }
                return candidate
            }.first
    }

    public static func inspect() -> [String: Any] {
        guard let client = discover() else { return ["clientState":"missing", "platformVersion":"", "platformPath":""] }
        var result: [String:Any] = ["platformVersion":client.version,"platformPath":client.executable.path]
        if !FileManager.default.fileExists(atPath: client.configuration.path) { result["clientState"]="unconfigured" }
        else if let data = try? Data(contentsOf: client.configuration) { result["clientState"]=data == managedConfiguration ? "configured" : data.isEmpty ? "unconfigured" : "external" }
        else { result["clientState"]="unknown" }
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
