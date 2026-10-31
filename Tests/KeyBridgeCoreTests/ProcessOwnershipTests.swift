// SPDX-License-Identifier: MIT
import XCTest
import Foundation
import Darwin
@testable import KeyBridgeCore

final class ProcessOwnershipTests: XCTestCase {
    var runtime: URL!
    override func setUpWithError() throws {
        runtime = FileManager.default.temporaryDirectory.appendingPathComponent("KeyBridgeOwnership-" + UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: runtime) }

    private func identity(_ pid: UInt32 = 123456) -> ProcessIdentity {
        ProcessIdentity(audit: [0,getuid(),getgid(),getuid(),getgid(),pid,0,1], executable: "/test/qemu-system-x86_64")
    }
    private func snapshot(_ folder: URL, generation: String = UUID().uuidString) -> ProcessSnapshot {
        ProcessSnapshot(identity: identity(), arguments: ["qemu-system-x86_64", "-name", "keybridge-" + UUID().uuidString,
            "-qmp", "unix:\(folder.appendingPathComponent("qmp.sock").path),server=on,wait=off",
            "-drive", "file=\(folder.appendingPathComponent("generations/" + generation + "/guest.qcow2").path),if=virtio"])
    }
    func testInventoryFindsOwnedVMWithoutAnyPIDOrMetadataFiles() {
        let generation = UUID().uuidString
        let observed = HostProcessInspector.classify([snapshot(runtime,generation:generation)], runtime: runtime)
        guard case .owned(_, let found, let run) = observed else { return XCTFail("Missing PID file is not absence") }
        XCTAssertEqual(found,generation); XCTAssertNotNil(run)
    }
    func testOtherRuntimeDoesNotBecomeOurProcessAndAmbiguityIsUnknown() {
        XCTAssertTrue(HostProcessInspector.classify([snapshot(runtime.appendingPathComponent("other"))],runtime:runtime).isAbsent)
        XCTAssertEqual(HostProcessInspector.classify([snapshot(runtime),snapshot(runtime)],runtime:runtime).name,"unknown")
    }
    func testStopStillRunsWhenIntentWriteFailsAndReportsBothErrors() {
        var stopped = false
        let errors = StopTransaction.perform(persist: { throw BridgeError("disk full") }, stop: { stopped = true; throw BridgeError("USB unknown") })
        XCTAssertTrue(stopped); XCTAssertEqual(errors.count,2)
        XCTAssertTrue(errors.joined().contains("disk full")); XCTAssertTrue(errors.joined().contains("USB unknown"))
    }
    func testUnknownOwnershipCannotClaimStoppedOrLaunchAnotherVM() throws {
        let engine = VMEngine(runtime:runtime,resources:runtime.appendingPathComponent("none"))
        engine.observeProcesses = { _ in .unknown("inventory unavailable") }
        XCTAssertThrowsError(try engine.stop())
        XCTAssertEqual(engine.status()["ownership"] as? String,"unknown")
        XCTAssertNotEqual(engine.status()["status"] as? String,"stopped")
        XCTAssertNotEqual(engine.status()["usbReleased"] as? Bool,true)
        XCTAssertThrowsError(try engine.perform(["action":"start"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:runtime.appendingPathComponent("qemu.pid").path))
    }
    func testEscalationDoesNotDependOnDirtyShutdownMarkerWrite() throws {
        try FileManager.default.createDirectory(at:runtime.appendingPathComponent("dirty-shutdown"),withIntermediateDirectories:false)
        let engine = VMEngine(runtime:runtime,resources:runtime.appendingPathComponent("none"))
        var stopped = false
        var quit = false
        engine.observeProcesses = { _ in stopped ? .absent : .owned(self.identity(),generation:nil,runID:nil) }
        engine.pause = { _ in }
        engine.qmpTransport = { command,_ in
            if command == "quit" { quit = true; stopped = true }
            return [:]
        }
        try engine.stop()
        XCTAssertTrue(quit); XCTAssertEqual(engine.status()["usbReleased"] as? Bool,true)
    }
    func testKernelRejectsDifferentPIDVersionWithoutSignallingLiveChild() throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath:"/bin/sleep"); child.arguments = ["20"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let actual = try ProcessIdentity.capture(child.processIdentifier)
        var words = actual.audit; words[7] &+= 1
        let stale = ProcessIdentity(audit:words,executable:actual.executable)
        try stale.signal(SIGTERM) // ESRCH for this identity, not a signal to its PID.
        Thread.sleep(forTimeInterval:0.05)
        XCTAssertTrue(child.isRunning)
        try actual.signal(SIGTERM)
        child.waitUntilExit()
        XCTAssertNotEqual(child.terminationStatus,0)
    }
}

extension ProcessOwnershipTests {
    func testUnlinkedUnrelatedExecutableDoesNotBlockEmptyRuntimeButQEMUStaysUnknown() throws {
        // A live process whose executable was replaced has no proc_pidpath,
        // while the kernel still supplies its identity and executable name.
        let pid=getpid()
        let noPath:(pid_t)->String?={_ in nil}
        let node=KernelProcessSummary(pid:pid,uid:getuid(),status:UInt32(SSLEEP),name:"node",command:"node")
        XCTAssertFalse(try HostProcessInspector.isQEMUCandidate(pid,path:noPath,summary:{_ in node}))
        let qemu=KernelProcessSummary(pid:pid,uid:getuid(),status:UInt32(SSLEEP),name:"qemu-system-x86_64",command:"qemu-system-x86")
        XCTAssertThrowsError(try HostProcessInspector.isQEMUCandidate(pid,path:noPath,summary:{_ in qemu}))
        XCTAssertThrowsError(try HostProcessInspector.isQEMUCandidate(pid,path:noPath,summary:{_ in nil}))
        let contradictory=KernelProcessSummary(pid:pid,uid:getuid(),status:UInt32(SSLEEP),name:"node",command:"qemu-system-x86")
        XCTAssertThrowsError(try HostProcessInspector.isQEMUCandidate(pid,path:noPath,summary:{_ in contradictory}))
        let empty=KernelProcessSummary(pid:pid,uid:getuid(),status:UInt32(SSLEEP),name:"",command:"")
        XCTAssertThrowsError(try HostProcessInspector.isQEMUCandidate(pid,path:noPath,summary:{_ in empty}))
        let otherPID=KernelProcessSummary(pid:pid+1,uid:getuid(),status:UInt32(SSLEEP),name:"node",command:"node")
        XCTAssertThrowsError(try HostProcessInspector.isQEMUCandidate(pid,path:noPath,summary:{_ in otherPID}))
    }
    func testExitedQEMUIsNotALiveCandidateAndReadableQEMUStillNeedsOwnership() throws {
        let pid=getpid()
        let zombie=KernelProcessSummary(pid:pid,uid:getuid(),status:UInt32(SZOMB),name:"qemu-system-x86_64",command:"qemu-system-x86")
        XCTAssertFalse(try HostProcessInspector.isQEMUCandidate(pid,path:{_ in nil},summary:{_ in zombie}))
        XCTAssertTrue(try HostProcessInspector.isQEMUCandidate(pid,path:{_ in "/app/qemu-system-x86_64"},summary:{_ in nil}))
        XCTAssertEqual(HostProcessInspector.classify([snapshot(runtime),snapshot(runtime)],runtime:runtime).name,"unknown")
    }
}
