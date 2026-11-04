// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class AgentIdentityTests: XCTestCase {
    func testAgentMustBelongToExactCurrentApplicationIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyBridgeIdentityTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, _ identifier: Any) throws -> URL {
            let executables = root.appendingPathComponent(name + ".app/Contents/MacOS")
            try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
            let info = executables.deletingLastPathComponent().appendingPathComponent("Info.plist")
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0).write(to: info)
            return executables
        }
        let current = try app("Current", "pro.keybridge.unique-test")
        let old = try app("Old", "pro.keybridge.unique-test")
        let other = try app("Other", "pro.keybridge.unique-test.other")
        let malformed = try app("Malformed", 123)
        XCTAssertTrue(AgentIdentity.isAgentExecutable(old.appendingPathComponent("KeyBridgeAgent"), executableDirectory: current))
        XCTAssertFalse(AgentIdentity.isAgentExecutable(other.appendingPathComponent("KeyBridgeAgent"), executableDirectory: current))
        XCTAssertFalse(AgentIdentity.isAgentExecutable(current.appendingPathComponent("Unrelated"), executableDirectory: current))
        XCTAssertFalse(AgentIdentity.isAgentExecutable(malformed.appendingPathComponent("KeyBridgeAgent"), executableDirectory: current))
        XCTAssertFalse(AgentIdentity.isAgentExecutable(old.appendingPathComponent("KeyBridgeAgent"), executableDirectory: root))
    }

    func testSamePathOldBuildAndOtherPIDCannotCountAsCurrentAgent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyBridgeIdentityTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executables = root.appendingPathComponent("KeyBridge.app/Contents/MacOS")
        let resources = root.appendingPathComponent("KeyBridge.app/Contents/Resources")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let inventory = resources.appendingPathComponent("build-inventory.json")
        try Data("old build".utf8).write(to: inventory)
        let old = try XCTUnwrap(AgentIdentity.fingerprint(executableDirectory: executables))
        let path = executables.appendingPathComponent("KeyBridgeAgent")
        let status: [String: Any] = ["agentIdentity": old, "agentPID": 123]
        XCTAssertTrue(AgentIdentity.matches(status: status, pid: 123, path: path, executableDirectory: executables))
        XCTAssertFalse(AgentIdentity.matches(status: status, pid: 456, path: path, executableDirectory: executables))
        XCTAssertFalse(AgentIdentity.matches(status: [:], pid: 123, path: path, executableDirectory: executables))
        try Data("new build".utf8).write(to: inventory)
        XCTAssertFalse(AgentIdentity.matches(status: status, pid: 123, path: path, executableDirectory: executables))
        XCTAssertFalse(AgentIdentity.matches(status: status, pid: 123, path: root.appendingPathComponent("other/KeyBridgeAgent"), executableDirectory: executables))
    }
}
