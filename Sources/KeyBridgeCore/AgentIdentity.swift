// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Darwin

/// Captured once by the agent so replacing its .app cannot relabel an old
/// running process as the newly installed build.
public enum AgentIdentity {
    private static let digests=FileDigestCache()
    public static let current = fingerprint(executableDirectory: BridgePaths.executableDirectory)

    public static func fingerprint(executableDirectory: URL) -> String? {
        let inventory = executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources/build-inventory.json")
        let agent = executableDirectory.appendingPathComponent("KeyBridgeAgent")
        return digests.digest(FileManager.default.fileExists(atPath: inventory.path) ? inventory : agent)
    }

    public static func processPath(_ pid: Int32) -> URL? {
        guard pid > 1, kill(pid, 0) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }

    private static func applicationIdentifier(executableDirectory: URL) -> String? {
        guard executableDirectory.lastPathComponent == "MacOS" else { return nil }
        let contents = executableDirectory.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        return identifier
    }

    public static func isAgentExecutable(_ path: URL, executableDirectory: URL = BridgePaths.executableDirectory) -> Bool {
        guard path.lastPathComponent == "KeyBridgeAgent",
              let expected = applicationIdentifier(executableDirectory: executableDirectory) else { return false }
        return applicationIdentifier(executableDirectory: path.deletingLastPathComponent()) == expected
    }

    public static func matches(status: [String: Any], pid: Int32, path: URL, executableDirectory: URL) -> Bool {
        guard path == executableDirectory.appendingPathComponent("KeyBridgeAgent").resolvingSymlinksInPath(),
              let expected = fingerprint(executableDirectory: executableDirectory) else { return false }
        return status["agentPID"] as? Int == Int(pid) && status["agentIdentity"] as? String == expected
    }

    public static let restartMessage = "Продолжает работать прежняя копия KeyBridge. Выберите «Выключить и выйти», затем снова откройте установленное приложение. Подготовленные программы сохранятся."
}
