// SPDX-License-Identifier: MIT
// This helper accepts no target paths, commands, versions or file contents.
import Foundation
import CryptoKit
import KeyBridgeCore
import Darwin

let client = ClientInstallation.discover()
let target = client?.configuration ?? URL(fileURLWithPath:"/opt/1cv8/not-installed/conf/nethasp.ini")
let backupRoot = URL(fileURLWithPath: "/Library/Application Support/KeyBridge-Configuration")
// The first pilot stored a single version's backup directly in this directory.
// This branch only migrates that known location; it does not restrict new clients.
let legacyMetadata = backupRoot.appendingPathComponent("metadata.json")
let useLegacy = client?.version == "8.5.4.1878" && FileManager.default.fileExists(atPath:legacyMetadata.path)
let backup = useLegacy ? backupRoot : backupRoot.appendingPathComponent(client?.version ?? "missing")
let expected = ClientInstallation.managedConfiguration
func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(1) }
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func securePath(_ url: URL, allowMissing: Bool = false) {
    var s = stat()
    if lstat(url.path, &s) != 0 { if allowMissing && errno == ENOENT { return }; fail("Недоступен путь \(url.path)") }
    if (s.st_mode & S_IFMT) == S_IFLNK || s.st_uid != 0 || (s.st_mode & 0o022) != 0 { fail("Небезопасные права пути \(url.path)") }
}
let action = CommandLine.arguments.dropFirst().first ?? "status"
if action == "status" || action == "inspect" {
    var state=ClientInstallation.inspect()
    if let data=try?Data(contentsOf:target) {state["clientRevision"]=hash(data)}
    var backupInfo=stat()
    if lstat(backup.appendingPathComponent("metadata.json").path,&backupInfo)==0 {state["backupState"]="available"}
    else {state["backupState"]=errno==ENOENT ? "missing":"unknown"}
    state["backupAvailable"] = state["backupState"] as? String == "available"
    if action=="status" {print(state["clientState"] as? String ?? "unknown")}
    else {print(jsonText(state))}
    exit(0)
}
guard getuid() == 0, ["apply", "repair", "restore"].contains(action), CommandLine.arguments.count == 4, CommandLine.arguments[2] == "--lease" else { fail("Требуется системное разрешение; допустимы только apply, repair и restore") }
guard client != nil else { fail("Установите клиент 1С для macOS и повторите настройку.") }
// Authorization has completed. An empty FIFO is the agent's live, revocable
// permission. Commit and cancellation share flock; the agent closes its writer
// under this lock, so a late authorized helper cannot change configuration.
let lease=URL(fileURLWithPath:CommandLine.arguments[3]).standardizedFileURL
let leaseName=lease.deletingPathExtension().lastPathComponent
let leaseRuntime=lease.deletingLastPathComponent().deletingLastPathComponent()
guard lease.pathExtension=="fifo",UUID(uuidString:leaseName) != nil,lease.deletingLastPathComponent().lastPathComponent=="configuration" else { fail("Некорректный канал настройки") }
let permit=open(lease.path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
var permitInfo=stat()
guard permit>=0,fstat(permit,&permitInfo)==0,(permitInfo.st_mode&S_IFMT)==S_IFIFO,permitInfo.st_uid != 0,(permitInfo.st_mode&0o077)==0 else { fail("Небезопасный канал настройки") }
let commit=open(leaseRuntime.appendingPathComponent("commit.lock").path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
var commitInfo=stat()
guard commit>=0,fstat(commit,&commitInfo)==0,(commitInfo.st_mode&S_IFMT)==S_IFREG,commitInfo.st_uid==permitInfo.st_uid,(commitInfo.st_mode&0o077)==0 else { fail("Барьер настройки недоступен") }
var byte:UInt8=0
let deadline=Date().addingTimeInterval(25)
var granted=false
while Date()<deadline {
    let count=read(permit,&byte,1)
    if count<0 && errno==EAGAIN { granted=true;break }
    if count>0 { fail("Неизвестное разрешение настройки") }
    usleep(50_000)
}
guard granted,flock(commit,LOCK_EX)==0 else { fail("Настройка отменена или не подтверждена агентом") }
guard read(permit,&byte,1)<0,errno==EAGAIN else { fail("Настройка отменена до записи") }
// Hold commit until exit, including all backup and target writes.
for path in [ClientInstallation.root.deletingLastPathComponent(), ClientInstallation.root, target.deletingLastPathComponent().deletingLastPathComponent(), target.deletingLastPathComponent(), URL(fileURLWithPath:"/Library"), URL(fileURLWithPath:"/Library/Application Support")] {securePath(path)}
securePath(target, allowMissing: true); securePath(backupRoot, allowMissing:true); securePath(backup, allowMissing: true)
let fm = FileManager.default
do {
    try fm.createDirectory(at: backupRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    if backup != backupRoot {try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])}
    let lockPath=backup.appendingPathComponent("configuration.lock")
    let lockFD=open(lockPath.path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
    guard lockFD>=0,flock(lockFD,LOCK_EX)==0 else { fail("Настройки 1С заняты другой операцией") }
    defer { flock(lockFD,LOCK_UN);close(lockFD) }
    let metadata = backup.appendingPathComponent("metadata.json")
    let old:Data?
    if fm.fileExists(atPath:target.path) {old=try Data(contentsOf:target)} else {old=nil}
    if action == "repair" {
        if old == expected {print("configured");exit(0)}
        // Keep previous backup records and original bytes. Publish a new pointer
        // only after the complete replacement backup is durable.
        if fm.fileExists(atPath:metadata.path) {
            securePath(metadata)
            let retained=backup.appendingPathComponent("retained-"+UUID().uuidString+".json")
            try Data(contentsOf:metadata).write(to:retained,options:.atomic);chmod(retained.path,0o600)
        }
        let name="original-"+UUID().uuidString+".ini"
        if let old {try old.write(to:backup.appendingPathComponent(name),options:.atomic);chmod(backup.appendingPathComponent(name).path,0o600)}
        let info:[String:Any]=["existed":old != nil,"originalFile":name,"installedSHA256":hash(expected),"target":target.path]
        try JSONSerialization.data(withJSONObject:info).write(to:metadata,options:.atomic);chmod(metadata.path,0o600)
        try expected.write(to:target,options:.atomic);chmod(target.path,0o644)
        print("configured");exit(0)
    }
    if action == "apply" {
        if old == expected { print("configured"); exit(0) }
        if fm.fileExists(atPath: metadata.path) {
            securePath(metadata)
            let info = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any] ?? [:]
            let record=try ConfigurationBackupMetadata(info,expectedDigest:hash(expected),target:target.path)
            let existed=record.existed
            let original=backup.appendingPathComponent(record.originalFile)
            if existed { securePath(original) }
            let originalData = existed ? try Data(contentsOf: original) : nil
            guard info["installedSHA256"] as? String == hash(expected), old == originalData else {
                fail("Настройка изменена после подключения KeyBridge. Автоматическая перезапись запрещена.")
            }
            // Recover an interrupted apply only if the original target is intact.
            try expected.write(to: target, options: .atomic); chmod(target.path, 0o644)
            print("configured"); exit(0)
        }
        // Existing nonempty configuration needs a deliberate merge, not replacement.
        if let old, !old.isEmpty { fail("У версии 1С уже есть nethasp.ini. Сначала требуется согласовать его настройки; файл не изменён.") }
        let original=backup.appendingPathComponent("original.ini")
        if let old { try old.write(to: original, options: .atomic); chmod(original.path, 0o600) }
        let info: [String: Any] = ["existed": old != nil, "installedSHA256": hash(expected), "target":target.path]
        try JSONSerialization.data(withJSONObject: info).write(to: metadata, options: .atomic); chmod(metadata.path, 0o600)
        try expected.write(to: target, options: .atomic); chmod(target.path, 0o644)
        print("configured")
    } else {
        guard fm.fileExists(atPath: metadata.path) else {fail("Копия прежних настроек недоступна. Восстановите её из резервной копии Mac и повторите возврат; текущие настройки не изменены.")}
        securePath(metadata)
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any] ?? [:]
        let record=try ConfigurationBackupMetadata(info,expectedDigest:hash(expected),target:target.path)
        let existed=record.existed
        let original=backup.appendingPathComponent(record.originalFile)
        if existed { securePath(original) }
        let originalData = existed ? try Data(contentsOf: original) : nil
        if old == originalData {
            if existed { try fm.removeItem(at: original) }
            try fm.removeItem(at: metadata); print("restored-interrupted-apply"); exit(0)
        }
        guard old == expected else { fail("nethasp.ini изменён вне приложения; автоматический откат запрещён") }
        if existed { securePath(original); try Data(contentsOf: original).write(to: target, options: .atomic); chmod(target.path, 0o644); try fm.removeItem(at: original) }
        else { try fm.removeItem(at: target) }
        try fm.removeItem(at: metadata)
        print("restored")
    }
} catch { fail(error.localizedDescription) }
