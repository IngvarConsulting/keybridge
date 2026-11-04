// SPDX-License-Identifier: MIT
// This helper accepts no target paths, commands, versions or file contents.
import Foundation
import KeyBridgeCore
import Darwin

umask(0o077)

let client = ClientInstallation.discover()
let backupRoot = URL(fileURLWithPath: "/Library/Application Support/KeyBridge-Configuration")
func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(1) }
func securePath(_ url: URL, allowMissing: Bool = false) {
    var s = stat()
    if lstat(url.path, &s) != 0 { if allowMissing && errno == ENOENT { return }; fail("Недоступен путь \(url.path)") }
    if (s.st_mode & S_IFMT) == S_IFLNK || s.st_uid != 0 || (s.st_mode & 0o022) != 0 { fail("Небезопасные права пути \(url.path)") }
}
let action = CommandLine.arguments.dropFirst().first ?? "status"
if action == "status" || action == "inspect" {
    let state=ClientInstallation.inspect(client)
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
func secureParents(_ url:URL) {
    var parent=url.deletingLastPathComponent()
    while parent.path != "/" {securePath(parent);parent.deleteLastPathComponent()}
}
let selected=client!
let targets:[URL],backup:URL
do {targets=selected.configurationFiles();backup=try selected.configurationBackup()}
catch {fail(error.localizedDescription)}
for target in targets {secureParents(target);securePath(target,allowMissing:true)}
secureParents(backupRoot);securePath(backupRoot,allowMissing:true);securePath(backup,allowMissing:true)
let fm = FileManager.default
do {
    for directory in backup == backupRoot ? [backupRoot] : [backupRoot, backup] {
        var isDirectory:ObjCBool=false
        if fm.fileExists(atPath:directory.path,isDirectory:&isDirectory) {
            guard isDirectory.boolValue else { fail("Каталог резервной копии занят файлом") }
        } else {
            try fm.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o711])
        }
        // The app may stat known metadata, but cannot list or read backups.
        // Files retain root ownership and mode 0600 under the helper's umask.
        try fm.setAttributes([.posixPermissions:0o711],ofItemAtPath:directory.path)
    }
    let lockPath=backupRoot.appendingPathComponent("configuration.lock")
    let lockFD=open(lockPath.path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
    guard lockFD>=0,flock(lockFD,LOCK_EX)==0 else { fail("Настройки 1С заняты другой операцией") }
    defer { flock(lockFD,LOCK_UN);close(lockFD) }
    let transaction=ConfigurationTransaction(targets:targets,backup:backup,expected:ClientInstallation.managedConfigurations) {url,allowMissing in
        securePath(url,allowMissing:allowMissing)
    }
    print(try transaction.perform(action))
} catch { fail(error.localizedDescription) }
