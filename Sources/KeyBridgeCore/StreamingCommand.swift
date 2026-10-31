// SPDX-License-Identifier: MIT
import Foundation
import Darwin

struct StreamingCommandResult {
    let status: Int32
    let output: String
}

/// A regular-file spool prevents child stdout/stderr pipe deadlocks. Its separate
/// reader follows the current offset, forwarding each byte once while the child
/// is alive. Memory is bounded independently of the command's full diagnostic log.
enum StreamingCommand {
    static let maximumResultBytes = 2 * 1024 * 1024

    static func run(_ executable: String, _ arguments: [String], directory: URL,
                    input: Data? = nil, timeout: TimeInterval = 60,
                    cancellation: () -> Bool = { false },
                    output: (Data) throws -> Void,
                    heartbeat: () throws -> Void = {}) throws -> StreamingCommandResult {
        let fm = FileManager.default
        let spool = directory.appendingPathComponent("command-\(UUID().uuidString).log")
        let inputURL = directory.appendingPathComponent("input-\(UUID().uuidString)")
        guard fm.createFile(atPath: spool.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw BridgeError("Не удалось создать журнал команды") }
        defer { try? fm.removeItem(at: spool); try? fm.removeItem(at: inputURL) }
        let writer = try FileHandle(forWritingTo: spool)
        let reader = try FileHandle(forReadingFrom: spool)
        defer { try? reader.close(); try? writer.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = writer
        process.standardError = writer
        var source: FileHandle?
        defer { try? source?.close() }
        if let input {
            guard fm.createFile(atPath: inputURL.path, contents: input, attributes: [.posixPermissions: 0o600]) else { throw BridgeError("Не удалось передать данные команде") }
            source = try FileHandle(forReadingFrom: inputURL)
            process.standardInput = source
        } else { process.standardInput = FileHandle.nullDevice }

        var tail = Data()
        func drain(maximumBytes: Int, bestEffortOutput: Bool = false) throws -> Int {
            var read = 0
            while read < maximumBytes {
                guard let chunk = try reader.read(upToCount: min(64 * 1024, maximumBytes - read)), !chunk.isEmpty else { break }
                read += chunk.count
                do { try output(chunk) }
                catch { if !bestEffortOutput { throw error } }
                tail.append(chunk)
                if tail.count > maximumResultBytes { tail.removeFirst(tail.count - maximumResultBytes) }
            }
            return read
        }
        func stopChild() {
            guard process.isRunning else { return }
            process.terminate()
            let grace = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        if cancellation() { throw VMEngineError.cancelled }
        try process.run()
        defer { stopChild() }
        do {
            let deadline = Date().addingTimeInterval(timeout)
            var interruption: VMEngineError?
            while process.isRunning {
                try heartbeat()
                _ = try drain(maximumBytes: 1024 * 1024)
                if cancellation() { interruption = .cancelled; break }
                if Date() > deadline { interruption = .message("Время ожидания операции истекло: \(URL(fileURLWithPath: executable).lastPathComponent)"); break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if interruption != nil { stopChild() }
            process.waitUntilExit()
            // Drain after exit on ALL paths, including cancellation and timeout.
            while try drain(maximumBytes: 1024 * 1024) > 0 { try heartbeat() }
            if let interruption { throw interruption }
            if cancellation() { throw VMEngineError.cancelled }
            // A truncated tail can start in the middle of a UTF-8 scalar.
            return StreamingCommandResult(status: process.terminationStatus, output: String(decoding: tail, as: UTF8.self))
        } catch {
            stopChild()
            // Progress persistence can fail while the diagnostic log is still
            // writable. Forward the remaining unread bytes without retrying a
            // chunk whose callback may already have appended it, and preserve
            // the original error even if a later progress callback also fails.
            while let count = try? drain(maximumBytes: 1024 * 1024, bestEffortOutput: true), count > 0 {}
            throw error
        }
    }
}
