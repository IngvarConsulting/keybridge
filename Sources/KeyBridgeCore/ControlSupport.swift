// SPDX-License-Identifier: MIT
import Foundation
import CoreFoundation
import Darwin

public struct BridgeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum BridgePaths {
    public static var runtime: URL {
        if let custom = ProcessInfo.processInfo.environment["KEYBRIDGE_RUNTIME"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KeyBridge", isDirectory: true)
    }
    public static var executableDirectory: URL {
        // SMAppService may supply a relative BundleProgram as argv[0].
        // dyld knows the executable actually loaded, independently of launch cwd.
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        precondition(_NSGetExecutablePath(&path, &size) == 0, "Cannot resolve executable path")
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().deletingLastPathComponent()
    }
    public static var resources: URL { executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources") }
    public static var loginLaunchSupported: Bool {
        ApplicationCapabilities.loginLaunchSupported(executableDirectory: executableDirectory)
    }
    public static var platform: String { ClientInstallation.discover()?.executable.path ?? "/opt/1cv8/1cv8-not-installed" }
    public static var version: String { ClientInstallation.discover()?.version ?? "" }
    public static func preparePrivateDirectory(_ url: URL) throws {
        var s = stat()
        if lstat(url.path, &s) == 0 {
            guard s.st_uid == getuid(), (s.st_mode & S_IFMT) == S_IFDIR else { throw BridgeError("Небезопасный каталог данных приложения: \(url.path)") }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(url.path, 0o700) == 0 else { throw BridgeError("Не удалось ограничить доступ к данным приложения") }
    }
}

public enum ApplicationCapabilities {
    public static let autostartUnavailableMessage = "Автозапуск недоступен в этой сборке. Открывайте KeyBridge вручную."

    /// Helpers have no reliable Bundle.main; read their enclosing application.
    /// A missing, malformed or non-Boolean declaration never enables a feature.
    public static func loginLaunchSupported(executableDirectory: URL) -> Bool {
        let contents = executableDirectory.deletingLastPathComponent()
        guard executableDirectory.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = info["KeyBridgeLoginLaunchSupported"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    public static func requireLoginLaunch(_ enabled: Bool, supported: Bool = BridgePaths.loginLaunchSupported) throws {
        if enabled && !supported { throw BridgeError(autostartUnavailableMessage) }
    }
}

public func readObject(_ url: URL) -> [String: Any] {
    guard let d = try? Data(contentsOf: url), let v = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return v
}
public func writeObject(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    chmod(url.path, 0o600)
}
public func jsonText(_ object: [String: Any]) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}
public func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }

public struct HostCommandResult { public let code: Int32; public let output: String; public let timedOut: Bool; public let processID:Int32 }
public func hostCommand(_ executable: String, _ args: [String], timeout: TimeInterval = 60, log: URL? = nil, cancellation: URL? = nil, isCancelled: (() -> Bool)? = nil, onPoll: (() throws -> Void)? = nil) throws -> HostCommandResult {
    let temp = log ?? FileManager.default.temporaryDirectory.appendingPathComponent("keybridge-command-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: temp)
    let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
    p.standardInput = FileHandle.nullDevice; p.standardOutput = handle; p.standardError = handle
    try p.run()
    let until = Date().addingTimeInterval(timeout)
    var pollError:Error?
    while p.isRunning && Date() < until {
        do { try onPoll?() } catch { pollError=error;break }
        if isCancelled?() == true { break }
        if let cancellation, FileManager.default.fileExists(atPath: cancellation.path) { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    let timedOut = p.isRunning
    if timedOut { p.terminate(); Thread.sleep(forTimeInterval: 1); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    p.waitUntilExit(); try? handle.close()
    let output = (try? String(contentsOf: temp, encoding: .utf8)) ?? ""
    if log == nil { try? FileManager.default.removeItem(at: temp) }
    if let pollError { throw pollError }
    return HostCommandResult(code: p.terminationStatus, output: String(output.suffix(16000)), timedOut: timedOut, processID:p.processIdentifier)
}

public enum CommandQueue {
    public static func enqueue(_ request: [String: Any], runtime: URL) throws -> String {
        try BridgePaths.preparePrivateDirectory(runtime)
        let directory = runtime.appendingPathComponent("requests")
        try BridgePaths.preparePrivateDirectory(directory)
        let identifier = request["requestID"] as? String ?? UUID().uuidString
        guard UUID(uuidString:identifier) != nil else { throw BridgeError("Некорректный requestID") }
        var value = request; value["requestID"] = identifier; value["created"] = Date().timeIntervalSince1970
        try writeObject(value, to: directory.appendingPathComponent(identifier + ".json"))
        return identifier
    }
    public static func take(runtime: URL) throws -> [(String, [String: Any])] {
        let directory = runtime.appendingPathComponent("requests")
        try BridgePaths.preparePrivateDirectory(directory)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var results: [(String, [String: Any])] = []
        for url in urls where url.pathExtension == "json" {
            var s = stat()
            guard lstat(url.path, &s) == 0, s.st_uid == getuid(), (s.st_mode & S_IFMT) == S_IFREG, s.st_size < 16384 else { continue }
            let object = readObject(url)
            guard let id = object["requestID"] as? String, UUID(uuidString: id) != nil,
                  url.lastPathComponent == id + ".json",
                  let created = object["created"] as? Double, Date().timeIntervalSince1970 - created < 120 else { try FileManager.default.removeItem(at:url);continue }
            let received=runtime.appendingPathComponent("received")
            try BridgePaths.preparePrivateDirectory(received)
            try writeObject(object,to:received.appendingPathComponent(id+".json"))
            try FileManager.default.removeItem(at:url)
            results.append((id, object))
        }
        return results.sorted { ($0.1["created"] as? Double ?? 0) < ($1.1["created"] as? Double ?? 0) }
    }
}
