// SPDX-License-Identifier: MIT
import XCTest
import Darwin
@testable import KeyBridgeCore

final class USBSafetyTests:XCTestCase {
    var runtime:URL!,engine:VMEngine!,alive=true,attached=false,adds=0
    var guardReply="{\"status\":\"ok\",\"no_auto_fwup\":\"1\"}"
    var connections=[USBConnection(bus:2,address:1,epoch:"first")]
    override func setUpWithError() throws {
        runtime=URL(fileURLWithPath:"/tmp/kb-usb-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        let record=try generationFixture(runtime)
        try GenerationStore(runtime:runtime).publish(record)
        let resources=runtime.appendingPathComponent("resources/guest")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        try Data("guard-fixture".utf8).write(to:resources.appendingPathComponent("sentinel_guard.py"))
        try Data("key-fixture".utf8).write(to:resources.appendingPathComponent("key_info.py"))
        let id=ProcessIdentity(audit:[0,getuid(),getgid(),getuid(),getgid(),999999,0,1],executable:"/fixture/qemu-system-x86_64")
        engine=VMEngine(runtime:runtime,resources:resources.deletingLastPathComponent())
        engine.observeProcesses={ _ in self.alive ? .owned(id,generation:record["generation"] as? String,runID:UUID().uuidString) : .absent }
        engine.observeUSB={ self.connections }
        engine.shutdownGuest={_ in}
        engine.pause={_ in}
        engine.guestTransport={_,_,input in
            if input==Data("guard-fixture".utf8) { return self.guardReply }
            if input==Data("key-fixture".utf8) { return "{\"keys\":[{\"typename\":\"fixture\",\"islocal\":\"1\"}]}" }
            return ""
        }
        engine.qmpTransport={command,_ in
            if command=="system_powerdown" || command=="quit" { self.alive=false;self.attached=false }
            if command=="device_add" { self.attached=true;self.adds+=1 }
            if command=="human-monitor-command" {
                return self.attached ? "dev: usb-host, id \"physical_hasp\"\n  hostbus = 2 (0x2)\n  hostaddr = 1 (0x1)\n  attached\n" : ""
            }
            return [:]
        }
    }
    override func tearDownWithError() throws {
        engine.observeUSB=nil;engine.observeProcesses={_ in .absent};engine.guestTransport=nil;engine.qmpTransport=nil
        engine=nil;try FileManager.default.removeItem(at:runtime)
    }
    func testUnsafeGuardBeforeCaptureCannotRequestUSB() throws {
        guardReply="{\"status\":\"ok\",\"no_auto_fwup\":\"0\"}"
        XCTAssertThrowsError(try engine.perform(["action":"attach"]))
        XCTAssertEqual(adds,0);XCTAssertFalse(alive)
    }
    func testUnknownGuardAfterCaptureStopsExistingTransfer() throws {
        _=try engine.perform(["action":"attach"])
        XCTAssertTrue(attached);XCTAssertEqual(adds,1)
        guardReply="invalid reply"
        XCTAssertThrowsError(try engine.perform(["action":"health"]))
        XCTAssertFalse(alive);XCTAssertFalse(attached)
        XCTAssertEqual(engine.status()["ownership"] as? String,"absent")
    }
    func testSecondKeyAfterCaptureStopsInsteadOfChoosingByVendor() throws {
        _=try engine.perform(["action":"attach"])
        connections.append(USBConnection(bus:2,address:2,epoch:"second"))
        XCTAssertThrowsError(try engine.perform(["action":"health"]))
        XCTAssertFalse(alive);XCTAssertEqual(adds,1)
    }
    func testReusedBusAddressWithNewEpochCannotKeepOldCapture() throws {
        _=try engine.perform(["action":"attach"])
        connections=[USBConnection(bus:2,address:1,epoch:"replacement")]
        XCTAssertThrowsError(try engine.perform(["action":"health"]))
        XCTAssertFalse(alive);XCTAssertEqual(adds,1)
    }
    func testNoPhysicalKeyWaitsWithoutRestartingOrClaimingReady() throws {
        connections=[]
        _=try engine.perform(["action":"health"])
        XCTAssertTrue(alive);XCTAssertEqual(adds,0)
        XCTAssertEqual(engine.status()["status"] as? String,"waiting-key")
        XCTAssertEqual(engine.status()["keyConnected"] as? Bool,false)
    }
}
