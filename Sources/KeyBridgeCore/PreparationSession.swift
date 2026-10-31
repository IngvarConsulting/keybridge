// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// State is owned by the serialized engine. A heartbeat means the engine polled,
/// while lastOutputAt changes only when bytes were actually appended to the log.
final class PreparationSession {
    static let phases = ["verify", "linux", "import", "boot", "verify_imports", "dependencies", "driver", "firmware_guard", "manager_install", "manager_configure", "manager_ready", "alpine", "finalize"]
    private let progressURL: URL
    private let logURL: URL
    private let now: () -> TimeInterval
    private var markerParser = PreparationMarkerParser()
    private(set) var values: [String: Any]

    init(runtime: URL, now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) throws {
        self.now = now
        progressURL = runtime.appendingPathComponent("preparation.json")
        logURL = runtime.appendingPathComponent("logs/preparation.log")
        let timestamp = now()
        values = ["id": UUID().uuidString, "state": "running", "phase": "verify",
                  "startedAt": timestamp, "phaseStartedAt": timestamp, "updatedAt": timestamp]
        // Replacing the log starts exactly one new attempt. Completed attempts are
        // retained until this point; the full engine log is never truncated.
        try Data().write(to: logURL, options: .atomic)
        guard chmod(logURL.path, 0o600) == 0 else { throw BridgeError("Не удалось ограничить доступ к журналу подготовки") }
        try persist()
    }

    /// Only the newly established engine owner calls this, after the agent has
    /// acquired its exclusive runtime lock. Elapsed time alone is not evidence
    /// of abandonment. Preserve the attempt's output and original timings.
    static func recoverInterrupted(runtime: URL, now: TimeInterval = Date().timeIntervalSince1970) throws -> [String: Any]? {
        let path = runtime.appendingPathComponent("preparation.json")
        guard let input = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? input.close() }
        guard let data = try input.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024,
              var values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              values["state"] as? String == "running", let id = values["id"] as? String, UUID(uuidString: id) != nil else { return nil }
        let manifest = readObject(runtime.appendingPathComponent("current.json"))
        // A crash can occur after the atomic manifest commit but before the
        // terminal progress write. Its attempt identity proves that success.
        let committed = manifest["preparationID"] as? String == id
        values["state"] = committed ? "succeeded" : "failed"
        values["updatedAt"] = now
        values["finishedAt"] = now
        values["recoveryReason"] = committed ? "commit_recovered" : "agent_restarted"
        try writeObject(values, to: path)
        return values
    }

    @discardableResult func advance(to phase: String) throws -> Bool {
        guard values["state"] as? String == "running", let next = Self.phases.firstIndex(of: phase),
              let current = Self.phases.firstIndex(of: values["phase"] as? String ?? ""), next > current else { return false }
        values["phase"] = phase
        values["phaseStartedAt"] = now()
        values["updatedAt"] = now()
        try persist()
        return true
    }

    func record(_ bytes: Data, parseMarkers: Bool = true) throws {
        guard !bytes.isEmpty, values["state"] as? String == "running" else { return }
        try appendPrivateLog(bytes, to: logURL)
        let timestamp = now()
        values["lastOutputAt"] = timestamp
        values["updatedAt"] = timestamp
        if parseMarkers {
            for phase in markerParser.consume(bytes) { try advance(to: phase) }
        }
        try persist()
    }

    /// Called at a command boundary so an unterminated line cannot consume the
    /// next command's marker. A partial final marker still describes real output.
    func finishCommandOutput() throws {
        for phase in markerParser.finish() { try advance(to: phase) }
    }

    func heartbeat() throws {
        guard values["state"] as? String == "running" else { return }
        let timestamp = now()
        guard timestamp - (values["updatedAt"] as? TimeInterval ?? 0) >= 1 else { return }
        values["updatedAt"] = timestamp
        try persist()
    }

    func finish(_ state: String) throws {
        precondition(["succeeded", "failed", "cancelled"].contains(state))
        guard values["state"] as? String == "running" else { return }
        try finishCommandOutput()
        let timestamp = now()
        var terminal = values
        terminal["state"] = state
        terminal["updatedAt"] = timestamp
        terminal["finishedAt"] = timestamp
        // A failed atomic write must leave the in-memory session retryable.
        try writeObject(terminal, to: progressURL)
        values = terminal
    }

    private func persist() throws { try writeObject(values, to: progressURL) }
}

/// Bounded even when an installer writes an enormous line without a newline.
/// Protocol markers must occupy their own line; arbitrary output is not a phase.
struct PreparationMarkerParser {
    private var line = [UInt8]()
    private var overflow = false
    private let maximumLineBytes = 4096

    mutating func consume(_ bytes: Data) -> [String] {
        var phases = [String]()
        for byte in bytes {
            if byte == 10 || byte == 13 {
                if let phase = finishLine() { phases.append(phase) }
            } else if !overflow {
                if line.count < maximumLineBytes { line.append(byte) }
                else { line.removeAll(keepingCapacity: true); overflow = true }
            }
        }
        return phases
    }

    mutating func finish() -> [String] { finishLine().map { [$0] } ?? [] }

    private mutating func finishLine() -> String? {
        defer { line.removeAll(keepingCapacity: true); overflow = false }
        guard !overflow, let text = String(bytes: line, encoding: .utf8), text.hasPrefix("KEYBRIDGE_PHASE=") else { return nil }
        let raw = String(text.dropFirst("KEYBRIDGE_PHASE=".count)).trimmingCharacters(in: .whitespaces)
        let phase = raw == "imports" ? "boot" : raw == "manager_start" ? "manager_ready" : raw
        return PreparationSession.phases.contains(phase) ? phase : nil
    }
}

func appendPrivateLog(_ bytes: Data, to url: URL) throws {
    // O_NOFOLLOW avoids redirecting private subprocess output through a symlink.
    let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw BridgeError("Не удалось открыть локальный журнал: \(url.lastPathComponent)") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    guard fchmod(descriptor, 0o600) == 0 else { throw BridgeError("Не удалось ограничить доступ к локальному журналу") }
    try handle.write(contentsOf: bytes)
}
