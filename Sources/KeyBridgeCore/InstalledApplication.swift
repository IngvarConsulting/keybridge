// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// Finder owns installation, replacement and removal. These read-only guards
/// prevent a loaded old controller from recreating data or restarting a VM
/// after its files have disappeared; they never install or remove anything.
public enum InstalledApplication {
    public static func requireCurrentBuild(executableDirectory: URL = BridgePaths.executableDirectory) throws {
        try requireCurrentBuild(executableDirectory:executableDirectory,expectedBuild:AgentIdentity.current)
    }
    static func requireCurrentBuild(executableDirectory: URL,expectedBuild: String?) throws {
        guard let expectedBuild,expectedBuild==AgentIdentity.fingerprint(executableDirectory:executableDirectory),
              FileManager.default.isExecutableFile(atPath:executableDirectory.appendingPathComponent("KeyBridgeAgent").path) else {
            throw BridgeError("Запущенная копия KeyBridge удалена или заменена. Закройте её и откройте установленное приложение из Finder.")
        }
    }
    public static func validateRuntime(_ runtime: URL) throws {
        try validateRuntime(runtime,observation:{ RuntimeOwnership.observation(runtime:runtime) },activePreparation:{
            guard let status=try? AgentIPC.exchange(runtime:runtime,message:["ipc":"status"]),
                  let pid=status["agentPID"] as? Int,pid>1,let path=AgentIdentity.processPath(Int32(pid)) else { return false }
            return isCurrentPreparation(status:status,pid:Int32(pid),path:path,executableDirectory:BridgePaths.executableDirectory)
        })
    }
    static func validateRuntime(_ runtime: URL,observation: () -> [String:Any],activePreparation: () -> Bool = { false }) throws {
        guard runtime.standardizedFileURL.path==runtime.resolvingSymlinksInPath().path else { throw BridgeError("Путь к данным KeyBridge содержит символическую ссылку. Проверьте папку данных; её содержимое не изменено.") }
        var info=stat()
        if lstat(runtime.path,&info)==0 {
            guard info.st_uid==getuid(),(info.st_mode&S_IFMT)==S_IFDIR else { throw BridgeError("Принадлежность папки данных KeyBridge не подтверждена. Данные не изменены.") }
        } else if errno != ENOENT { throw BridgeError("Не удалось прочитать папку данных KeyBridge. Проверьте доступ и повторите проверку.") }
        let intent=runtime.appendingPathComponent("intent.json")
        if try exists(intent) {
            try requireRegularOwnedFile(intent)
            guard let value=try? JSONDecoder().decode(DesiredRuntime.self,from:Data(contentsOf:intent)),[1,2].contains(value.schema),(0...100).contains(value.remaining) else {
                throw BridgeError("Сохранённые настройки KeyBridge повреждены или имеют неподдерживаемый формат. Восстановите папку данных из резервной копии и повторите проверку.")
            }
        }
        let current=readObject(runtime.appendingPathComponent("current.json"))
        for name in current.keys.contains("previous") ? ["current.json"] : ["current.json","previous.json"] {
            let path=runtime.appendingPathComponent(name)
            if try exists(path) {
                try requireRegularOwnedFile(path)
                let value=readObject(path)
                guard !value.isEmpty,(value["schema"] as? Int ?? 1)==1,
                      let generation=value["generation"] as? String,UUID(uuidString:generation) != nil else {
                    throw BridgeError("Сведения о компонентах KeyBridge повреждены. Восстановите папку данных из резервной копии и повторите проверку; сохранившиеся файлы не удалены.")
                }
            }
        }
        if !(try exists(runtime.appendingPathComponent("current.json"))) {
            // A first preparation launches its VM before publishing current.
            // Only the live, exact controller can attest to that in-progress
            // operation; a saved status file never grants this exception.
            if activePreparation() { return }
            let state=observation()
            guard state["ownership"] as? String == "absent",state["running"] as? Bool == false else {
                throw BridgeError("Сведения о программах для ключа отсутствуют, но остановка работы с ключом не подтверждена. Нажмите «Выключить» и повторите проверку перед новой подготовкой.")
            }
        }
    }
    static func isCurrentPreparation(status: [String:Any],pid: Int32,path: URL,executableDirectory: URL) -> Bool {
        status["busy"] as? Bool == true && status["operation"] as? String == "prepare"
            && AgentIdentity.matches(status:status,pid:pid,path:path,executableDirectory:executableDirectory)
    }
    private static func exists(_ path: URL) throws -> Bool {
        var info=stat()
        if lstat(path.path,&info)==0 { return true }
        guard errno==ENOENT else { throw BridgeError("Не удалось проверить файл \(path.lastPathComponent). Проверьте доступ к папке данных и повторите проверку; отсутствие файла не подтверждено.") }
        return false
    }
    private static func requireRegularOwnedFile(_ path: URL) throws {
        var info=stat()
        guard lstat(path.path,&info)==0,info.st_uid==getuid(),(info.st_mode&S_IFMT)==S_IFREG else {
            throw BridgeError("Файл данных KeyBridge не подтверждён: \(path.lastPathComponent). Проверьте папку данных; файл не изменён.")
        }
    }
    public struct ControllerIntegrity {
        private let runtime: URL
        private let executableDirectory: URL
        private let build: String?
        private let device: dev_t
        private let inode: ino_t
        private let hadIntent: Bool
        public init(runtime: URL,executableDirectory: URL = BridgePaths.executableDirectory) {
            self.runtime=runtime;self.executableDirectory=executableDirectory
            build=AgentIdentity.fingerprint(executableDirectory:executableDirectory)
            var info=stat();_=lstat(runtime.path,&info);device=info.st_dev;inode=info.st_ino
            hadIntent=FileManager.default.fileExists(atPath:runtime.appendingPathComponent("intent.json").path)
        }
        public var runtimeUnchanged: Bool {
            var info=stat()
            return lstat(runtime.path,&info)==0 && (info.st_mode&S_IFMT)==S_IFDIR && info.st_dev==device && info.st_ino==inode
                && (!hadIntent || FileManager.default.fileExists(atPath:runtime.appendingPathComponent("intent.json").path))
        }
        public var problem: String? {
            if !runtimeUnchanged { return "Данные KeyBridge удалены или заменены. Работа с ключом завершается. После подтверждённой остановки откройте приложение и подготовьте компоненты заново либо восстановите данные из резервной копии." }
            if build == nil || build != AgentIdentity.fingerprint(executableDirectory:executableDirectory) {
                return "Приложение KeyBridge удалено или заменено в Finder. Работа с ключом завершается. Откройте установленную копию KeyBridge; сохранённое выключение остаётся в силе."
            }
            return nil
        }
    }
}
