// SPDX-License-Identifier: MIT
import XCTest
import Foundation
import Darwin
@testable import KeyBridgeCore

final class ControlSupportTests: XCTestCase {
    private var sandbox: URL!
    private var runtime: URL { sandbox.appendingPathComponent("runtime", isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        sandbox = fm.temporaryDirectory.appendingPathComponent("KeyBridgeTests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let sandbox { try fm.removeItem(at: sandbox) }
    }

    func testImportRequestRoundTripPreservesPathsAndCannotBeReplayed() throws {
        let installer = sandbox.appendingPathComponent("my files/1C 'special' $(literal).run").path
        let driver = sandbox.appendingPathComponent("driver with spaces.deb").path
        let id = try CommandQueue.enqueue(["action": "prepare", "installer": installer, "driver": driver], runtime: runtime)
        XCTAssertNotNil(UUID(uuidString: id))

        let requests = try CommandQueue.take(runtime: runtime)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, id)
        XCTAssertEqual(requests.first?.1["action"] as? String, "prepare")
        XCTAssertEqual(requests.first?.1["installer"] as? String, installer)
        XCTAssertEqual(requests.first?.1["driver"] as? String, driver)
        XCTAssertTrue(try CommandQueue.take(runtime: runtime).isEmpty, "A consumed command must not execute twice after polling again.")
    }

    func testRequestsAndRuntimeArePrivateRegardlessOfDefaultPermissions() throws {
        try fm.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let id = try CommandQueue.enqueue(["action": "start"], runtime: runtime)
        XCTAssertEqual(try mode(runtime), 0o700)
        XCTAssertEqual(try mode(runtime.appendingPathComponent("requests")), 0o700)
        XCTAssertEqual(try mode(runtime.appendingPathComponent("requests/" + id + ".json")), 0o600)
    }

    func testStaleStartIsDiscardedInsteadOfReplayingAtNextLogin() throws {
        try BridgePaths.preparePrivateDirectory(runtime.appendingPathComponent("requests"))
        let staleID = UUID().uuidString
        try put(id: staleID, action: "start", created: Date().timeIntervalSince1970 - 600)
        let currentID = try CommandQueue.enqueue(["action": "stop"], runtime: runtime)

        let requests = try CommandQueue.take(runtime: runtime)
        XCTAssertEqual(requests.map(\.0), [currentID])
        XCTAssertFalse(fm.fileExists(atPath: requestURL(staleID).path), "A rejected stale request must not survive into another poll.")
        XCTAssertTrue(try CommandQueue.take(runtime: runtime).isEmpty)
    }

    func testQueuePreservesSubmissionOrderInsteadOfUUIDFilenameOrder() throws {
        try BridgePaths.preparePrivateDirectory(runtime.appendingPathComponent("requests"))
        let first = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
        let second = "00000000-0000-4000-8000-000000000000"
        let now = Date().timeIntervalSince1970
        try put(id: second, action: "stop", created: now - 1)
        try put(id: first, action: "start", created: now - 2)
        let requests = try CommandQueue.take(runtime: runtime)
        XCTAssertEqual(requests.map(\.0), [first, second], "Stop submitted after start must not be moved ahead by UUID sorting.")
    }

    func testSymlinkRequestIsNotReadOrRemovedAndTargetRemainsUntouched() throws {
        try BridgePaths.preparePrivateDirectory(runtime.appendingPathComponent("requests"))
        let id = UUID().uuidString
        let outside = sandbox.appendingPathComponent("outside-command.json")
        let original = try JSONSerialization.data(withJSONObject: ["action": "start", "requestID": id, "created": Date().timeIntervalSince1970])
        try original.write(to: outside)
        try fm.createSymbolicLink(at: requestURL(id), withDestinationURL: outside)

        XCTAssertTrue(try CommandQueue.take(runtime: runtime).isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: requestURL(id).path), outside.path)
    }

    func testPrivateDirectoryRejectsSymlinkWithoutChangingTargetPermissions() throws {
        let outside = sandbox.appendingPathComponent("external", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let link = sandbox.appendingPathComponent("linked-runtime")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try BridgePaths.preparePrivateDirectory(link))
        XCTAssertEqual(try mode(outside), 0o755)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), outside.path)
    }

    func testSymlinkQueueDirectoryCannotRedirectCommandWrites() throws {
        try BridgePaths.preparePrivateDirectory(runtime)
        let outside = sandbox.appendingPathComponent("external-queue", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: runtime.appendingPathComponent("requests"), withDestinationURL: outside)

        XCTAssertThrowsError(try CommandQueue.enqueue(["action": "start"], runtime: runtime))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testMismatchedRequestIdentityAndOversizedInputAreNotExecuted() throws {
        try BridgePaths.preparePrivateDirectory(runtime.appendingPathComponent("requests"))
        let mismatchID = UUID().uuidString
        try writeObject(["action": "start", "requestID": UUID().uuidString, "created": Date().timeIntervalSince1970], to: requestURL(mismatchID))
        let oversizedID = UUID().uuidString
        try writeObject(["action": "start", "requestID": oversizedID, "created": Date().timeIntervalSince1970, "padding": String(repeating: "x", count: 20_000)], to: requestURL(oversizedID))

        XCTAssertTrue(try CommandQueue.take(runtime: runtime).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: requestURL(mismatchID).path))
    }

    func testUnpreparedEngineCannotClaimReadinessOrLicenseProof() throws {
        let engine = VMEngine(runtime: runtime, resources: sandbox.appendingPathComponent("absent-resources"))
        let status = engine.status()
        XCTAssertEqual(status["status"] as? String, "unprepared")
        XCTAssertEqual(status["prepared"] as? Bool, false)
        XCTAssertEqual(status["running"] as? Bool, false)
        XCTAssertNil(status["lastProbe"])
        XCTAssertFalse(fm.fileExists(atPath: runtime.path), "A read-only status call must not initialize or launch anything.")

        XCTAssertThrowsError(try engine.perform(["action": "start"]))
        let failed = engine.status()
        XCTAssertEqual(failed["running"] as? Bool, false)
        XCTAssertEqual(failed["prepared"] as? Bool, false)
        XCTAssertNil(failed["lastProbe"])
        XCTAssertFalse(fm.fileExists(atPath: runtime.appendingPathComponent("qemu.pid").path))
        XCTAssertFalse(fm.fileExists(atPath: runtime.appendingPathComponent("current.json").path))
    }

    func testRejectedReplacementPreservesAcceptedGenerationAndData() throws {
        try BridgePaths.preparePrivateDirectory(runtime)
        let acceptedID = UUID().uuidString
        let generation = runtime.appendingPathComponent("generations/" + acceptedID)
        try fm.createDirectory(at: generation, withIntermediateDirectories: true)
        let sentinel = generation.appendingPathComponent("retained-user-data")
        let contents = Data("Existing local user environment".utf8)
        try contents.write(to: sentinel)
        let manifest = runtime.appendingPathComponent("current.json")
        try writeObject(try generationFixture(runtime,id:acceptedID), to: manifest)
        let previous = try Data(contentsOf: manifest)
        let engine = VMEngine(runtime: runtime, resources: sandbox.appendingPathComponent("absent-resources"))

        XCTAssertThrowsError(try engine.perform(["action": "prepare", "installer": sandbox.appendingPathComponent("missing.run").path, "driver": sandbox.appendingPathComponent("missing.deb").path]))
        XCTAssertEqual(try Data(contentsOf: manifest), previous)
        XCTAssertEqual(try Data(contentsOf: sentinel), contents)
        XCTAssertEqual(engine.status()["prepared"] as? Bool, true)
        XCTAssertEqual(engine.status()["running"] as? Bool, false)
    }

    func testCancellationDoesNotPromoteUnacceptedGeneration() throws {
        try BridgePaths.preparePrivateDirectory(runtime)
        let candidate = runtime.appendingPathComponent("generations/" + UUID().uuidString)
        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data("Incomplete VM data".utf8).write(to: candidate.appendingPathComponent("candidate-marker"))
        let engine = VMEngine(runtime: runtime, resources: sandbox.appendingPathComponent("absent-resources"))

        try engine.requestCancellation()
        XCTAssertTrue(fm.fileExists(atPath: runtime.appendingPathComponent("cancel.request").path))
        let state = engine.status()
        XCTAssertEqual(state["prepared"] as? Bool, false)
        XCTAssertEqual(state["running"] as? Bool, false)
        XCTAssertNil(state["lastProbe"])
        XCTAssertFalse(fm.fileExists(atPath: runtime.appendingPathComponent("current.json").path))
        XCTAssertFalse(fm.fileExists(atPath: runtime.appendingPathComponent("qemu.pid").path))
    }

    private func put(id: String, action: String, created: TimeInterval) throws {
        try writeObject(["requestID": id, "action": action, "created": created], to: requestURL(id))
    }
    private func requestURL(_ id: String) -> URL { runtime.appendingPathComponent("requests/" + id + ".json") }
    private func mode(_ url: URL) throws -> Int {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
