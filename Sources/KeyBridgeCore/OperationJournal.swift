// SPDX-License-Identifier: MIT
import Foundation
import Darwin

public struct OperationToken: Equatable {
    public let id: String
    public let action: String
    fileprivate let epoch: UInt64
}

/// Admission, cancellation and publication share one linearization lock.
/// A receipt is only receipt; a terminal response belongs to its request ID.
public final class OperationJournal {
    private let lock = NSRecursiveLock()
    private let runtime: URL
    private var epoch: UInt64 = 0
    private var active: OperationToken?
    private var configurationWriter:Int32 = -1
    private var commitFD:Int32 = -1
    public private(set) var persistenceError: String?

    public init(runtime: URL) {
        self.runtime = runtime
        commitFD=open(runtime.appendingPathComponent("commit.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
    }
    deinit { if configurationWriter>=0 {close(configurationWriter)};if commitFD>=0 {close(commitFD)} }
    private func commitLock() throws {
        guard commitFD>=0,flock(commitFD,LOCK_EX)==0 else { throw BridgeError("Барьер настроек недоступен") }
    }
    private func revokeConfiguration() {
        if configurationWriter>=0 { close(configurationWriter);configurationWriter = -1 }
    }
    public func grantConfiguration(_ token:OperationToken,fifo:URL) throws {
        try publish(token) {
            if configurationWriter>=0 { return }
            try commitLock();defer{flock(commitFD,LOCK_UN)}
            let fd=open(fifo.path,O_WRONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
            if fd<0 && errno==ENXIO { return } // OS authorization still pending.
            guard fd>=0 else { throw BridgeError("Разрешение настройки недоступно") }
            var info=stat()
            guard fstat(fd,&info)==0,(info.st_mode&S_IFMT)==S_IFIFO,info.st_uid==getuid() else { close(fd);throw BridgeError("Небезопасный канал настройки") }
            configurationWriter=fd
        }
    }
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        // Root helper holds this same lock only during its short commit, after
        // authorization. Closing the empty FIFO revokes permission in-kernel,
        // even on full disk or agent death. No persistent revoke flag is needed.
        if configurationWriter>=0 {
            if (try?commitLock()) != nil { revokeConfiguration();flock(commitFD,LOCK_UN) }
            else { revokeConfiguration() }
        }
        epoch &+= 1
    }
    public func begin(id: String, action: String, safety: Bool = false) throws -> OperationToken {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw BridgeError("Контроллер занят другой операцией") }
        let token = OperationToken(id:id,action:action,epoch:epoch)
        persistenceError = nil
        do { try record(token, state:"executing") }
        catch {
            persistenceError = error.localizedDescription
            if !safety { throw error }
        }
        active = token
        return token
    }
    public func receiveSafety(id:String,action:String) throws {
        lock.lock();defer{lock.unlock()}
        try record(OperationToken(id:id,action:action,epoch:epoch),state:"accepted")
    }
    public func recordResponse(id:String,action:String,response:[String:Any]) throws {
        lock.lock();defer{lock.unlock()}
        try record(OperationToken(id:id,action:action,epoch:epoch),state:"finished",response:response)
    }
    public func isCurrent(_ token: OperationToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active == token && token.epoch == epoch
    }
    public func publish<T>(_ token: OperationToken, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active == token, epoch == token.epoch else { throw VMEngineError.cancelled }
        return try body()
    }
    public func finish(_ token: OperationToken, response: [String:Any]) {
        lock.lock(); defer { lock.unlock() }
        do { try record(token, state:"finished", response:response) }
        catch { persistenceError = error.localizedDescription }
        if active == token {
            if configurationWriter>=0 {
                if (try?commitLock()) != nil { revokeConfiguration();flock(commitFD,LOCK_UN) }
                else { revokeConfiguration() }
            }
            active = nil
        }
    }
    private func record(_ token:OperationToken,state:String,response:[String:Any]?=nil) throws {
        let folder=runtime.appendingPathComponent("operations")
        try BridgePaths.preparePrivateDirectory(folder)
        var value:[String:Any] = ["requestID":token.id,"action":token.action,"state":state,"updated":Date().timeIntervalSince1970]
        if let response { value["response"]=response }
        // Periodic reconciliation has unique tokens but only its latest record
        // needs retention. User requests keep individual durable outcomes.
        let destination=token.action == "reconcile" ? runtime.appendingPathComponent("reconciliation.json") : folder.appendingPathComponent(token.id + ".json")
        try writeObject(value,to:destination)
    }
    /// No replay of an effect whose completion is unknown. Intent reconciliation
    /// may independently restore work; it never re-executes the lost request.
    public func recover() -> [String:[String:Any]] {
        lock.lock(); defer { lock.unlock() }
        var recovered=[String:[String:Any]]()
        for name in ["received","operations"] {
            let folder=runtime.appendingPathComponent(name)
            for url in (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? [] where url.pathExtension == "json" {
                let value=readObject(url)
                guard let id=value["requestID"] as? String,UUID(uuidString:id) != nil else { continue }
                if value["state"] as? String == "finished", let response=value["response"] as? [String:Any] { recovered[id]=response;continue }
                let existing=readObject(runtime.appendingPathComponent("operations/"+id+".json"))
                if let response=existing["response"] as? [String:Any] { recovered[id]=response;continue }
                let terminal=readObject(runtime.appendingPathComponent("results/"+id+".json"))
                if !terminal.isEmpty { recovered[id]=terminal;continue }
                let response:[String:Any] = ["ok":false,"resultState":"unknown","error":"Агент был перезапущен; результат операции не подтверждён. Проверьте состояние."]
                recovered[id]=response
                let token=OperationToken(id:id,action:value["action"] as? String ?? "unknown",epoch:epoch)
                try? record(token,state:"finished",response:response)
            }
        }
        return recovered
    }
}

public struct DesiredRuntime: Codable, Equatable {
    public var schema = 1
    public var want = false
    public var autoInhibit = false
    public var autostart = false
    public var remaining = 3
    public var sessionID = ""
    public var revision: UInt64 = 0
}

public final class IntentStore {
    private let lock=NSRecursiveLock()
    private let runtime:URL
    private var current:DesiredRuntime
    var writeData:(Data,URL)throws->Void = { try $0.write(to:$1,options:.atomic) }
    public var value:DesiredRuntime { lock.lock();defer{lock.unlock()};return current }
    public init(runtime:URL) throws {
        self.runtime=runtime
        let path=runtime.appendingPathComponent("intent.json")
        if FileManager.default.fileExists(atPath:path.path) {
            current=try JSONDecoder().decode(DesiredRuntime.self,from:Data(contentsOf:path))
            guard current.schema == 1, (0...100).contains(current.remaining) else { throw BridgeError("Сохранённое намерение повреждено") }
        } else {
            let desired=readObject(runtime.appendingPathComponent("desired.json"))
            let preferences=readObject(runtime.appendingPathComponent("preferences.json"))
            current=DesiredRuntime()
            current.autostart=preferences["autostart"] as? Bool ?? false
            if let running=desired["running"] as? Bool { current.want=running;current.autoInhibit = !running }
            else if FileManager.default.fileExists(atPath:runtime.appendingPathComponent("desired.json").path) { current.autoInhibit=true }
            // Preserve originals before migration; runtime data never enters Git.
            for name in ["desired.json","preferences.json"] {
                let source=runtime.appendingPathComponent(name),backup=runtime.appendingPathComponent(name+".before-intent")
                if FileManager.default.fileExists(atPath:source.path),!FileManager.default.fileExists(atPath:backup.path) { try FileManager.default.copyItem(at:source,to:backup) }
            }
            try persist(current)
        }
    }
    private func persist(_ value:DesiredRuntime) throws {
        try BridgePaths.preparePrivateDirectory(runtime)
        try writeData(JSONEncoder().encode(value),runtime.appendingPathComponent("intent.json"))
    }
    public func update(_ change:(inout DesiredRuntime)->Void) throws {
        lock.lock();defer{lock.unlock()}
        var next=current; change(&next);next.revision &+= 1
        try persist(next);current=next
    }
    public func start() throws { try update { $0.want=true;$0.autoInhibit=false;$0.remaining=3 } }
    public func stop() throws { try update { $0.want=false;$0.autoInhibit=true } }
    public func prepare() throws { try update { $0.want=false } }
    public func hold() throws { try update { $0.autoInhibit=true } }
    public func consumeAttempt() throws {
        try update { $0.remaining=max(0,$0.remaining-1) }
    }
    public func setAutostart(_ enabled:Bool) throws {
        try update { $0.autostart=enabled;if enabled { $0.autoInhibit=false } }
    }
}

/// In-memory status/results remain available over IPC when disk writes fail.
public final class RuntimeSnapshot {
    private let lock=NSLock()
    private var state:[String:Any]=[:]
    private var responses:[String:[String:Any]]=[:]
    private var responseOrder=[String]()
    public init() {}
    public func patch(_ patch:[String:Any]) { lock.lock();defer{lock.unlock()};state.merge(patch){_,n in n} }
    public func replace(_ value:[String:Any]) { lock.lock();defer{lock.unlock()};state=value }
    public func status()->[String:Any] { lock.lock();defer{lock.unlock()};return state }
    public func result(_ id:String)->[String:Any] { lock.lock();defer{lock.unlock()};return responses[id] ?? [:] }
    public func complete(_ id:String,_ response:[String:Any]) {
        lock.lock();defer{lock.unlock()}
        if responses[id]==nil { responseOrder.append(id) }
        responses[id]=response
        while responseOrder.count>256 { responses.removeValue(forKey:responseOrder.removeFirst()) }
    }
}
