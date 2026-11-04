// SPDX-License-Identifier: MIT
import XCTest
import Darwin
@testable import KeyBridgeCore

final class USBSafetyTests:XCTestCase {
    var runtime:URL!,engine:VMEngine!,alive=true,attached=false,adds=0
    var guardReply="{\"status\":\"ok\",\"no_auto_fwup\":\"1\"}"
    var connections=[USBConnection(bus:2,address:1,epoch:"first")]
    var guestCalls=0
    var failedServices=[String]()
    var commands=[String]()
    override func setUpWithError() throws {
        runtime=URL(fileURLWithPath:"/tmp/kb-usb-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        let record=try generationFixture(runtime)
        try GenerationStore(runtime:runtime).publish(record)
        let resources=runtime.appendingPathComponent("resources/guest")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        try Data("guard-fixture".utf8).write(to:resources.appendingPathComponent("sentinel_guard.py"))
        try Data("key-fixture".utf8).write(to:resources.appendingPathComponent("key_info.py"))
        try Data("ready-fixture".utf8).write(to:resources.appendingPathComponent("alpine_ready.py"))
        try Data("health-fixture".utf8).write(to:resources.appendingPathComponent("health.py"))
        try Data("service-fixture".utf8).write(to:resources.appendingPathComponent("alpine_service.sh"))
        let id=ProcessIdentity(audit:[0,getuid(),getgid(),getuid(),getgid(),999999,0,1],executable:"/fixture/qemu-system-x86_64")
        engine=VMEngine(runtime:runtime,resources:resources.deletingLastPathComponent())
        engine.observeProcesses={ _ in self.alive ? .owned(id,generation:record["generation"] as? String,runID:UUID().uuidString) : .absent }
        engine.observeUSB={ self.connections }
        engine.shutdownGuest={_ in}
        engine.pause={_ in}
        engine.guestTransport={_,command,input in
            self.commands.append(command)
            if command.contains("restart-service") { self.failedServices=[] }
            self.guestCalls+=1
            if let input,String(decoding:input,as:UTF8.self).contains("health-fixture") {
                guard let data=self.guardReply.data(using:.utf8),var value=(try?JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return self.guardReply }
                value.merge(["keys":[["typename":"fixture","islocal":"1"]],"services":true,"managerReady":true,"hotplug":true,"failedServices":self.failedServices]) {_,new in new}
                return jsonText(value)
            }
            if input==Data("guard-fixture".utf8) { return self.guardReply }
            if input==Data("key-fixture".utf8) { return "{\"keys\":[{\"typename\":\"fixture\",\"islocal\":\"1\"}]}" }
            return ""
        }
        engine.qmpTransport={command,_ in
            if command=="system_powerdown" || command=="quit" { self.alive=false;self.attached=false }
            if command=="device_del" { self.attached=false }
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
    func testUnknownOwnershipDoesNotClaimStoppedAndPreservesReason() throws {
        engine.observeProcesses = { _ in .unknown("native-observation-unavailable") }
        let status = engine.status()
        XCTAssertTrue(status["running"] is NSNull)
        XCTAssertEqual(status["ownershipError"] as? String, "native-observation-unavailable")
        XCTAssertThrowsError(try engine.stop()) { error in
            XCTAssertTrue(error.localizedDescription.contains("native-observation-unavailable"))
        }
        XCTAssertTrue(alive)
    }
    func testSteadyHealthUsesOneGuestRequestAndNeverRecaptures() throws {
        _=try engine.perform(["action":"attach"])
        guestCalls=0
        _=try engine.perform(["action":"health"])
        XCTAssertEqual(guestCalls,1)
        XCTAssertEqual(adds,1)
        XCTAssertTrue(attached)
        XCTAssertEqual(engine.status()["keyConnected"] as? Bool,true)
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
        _=try engine.perform(["action":"health"])
        XCTAssertTrue(alive);XCTAssertEqual(adds,2)
    }
    func testNoPhysicalKeyWaitsWithoutRestartingOrClaimingReady() throws {
        connections=[]
        _=try engine.perform(["action":"health"])
        XCTAssertTrue(alive);XCTAssertEqual(adds,0)
        XCTAssertEqual(engine.status()["status"] as? String,"waiting-key")
        XCTAssertEqual(engine.status()["keyConnected"] as? Bool,false)
    }
    func testPhysicalRemovalReleasesCaptureWithoutStoppingVM() throws {
        _=try engine.perform(["action":"attach"])
        connections=[]
        _=try engine.perform(["action":"health"])
        XCTAssertTrue(alive);XCTAssertFalse(attached);XCTAssertEqual(adds,1)
        XCTAssertEqual(engine.status()["status"] as? String,"waiting-key")
    }
    func testSSHFailureRetainsConfirmedTransferAndRecoveryNeverRecaptures() throws {
        _=try engine.perform(["action":"attach"])
        let working=engine.guestTransport
        engine.guestTransport={_,_,_ in throw BridgeError("SSH unavailable")}
        XCTAssertThrowsError(try engine.perform(["action":"health"])) { error in
            guard case VMEngineError.channel=error else { return XCTFail("Expected channel loss: \(error)") }
        }
        XCTAssertTrue(alive);XCTAssertTrue(attached);XCTAssertEqual(adds,1)
        engine.guestTransport=working
        _=try engine.perform(["action":"recover-channel"])
        XCTAssertTrue(alive);XCTAssertEqual(adds,1)
    }
    func testOnlyFailedServiceIsRecoveredWithoutVMRestart() throws {
        _=try engine.perform(["action":"attach"])
        failedServices=["rmlic"]
        XCTAssertThrowsError(try engine.perform(["action":"health"])) { error in
            guard case VMEngineError.services(["rmlic"])=error else { return XCTFail("Expected service failure") }
        }
        commands=[]
        _=try engine.perform(["action":"recover-services","services":["rmlic"]])
        XCTAssertEqual(commands.filter{$0.contains("restart-service")},["sudo sh -s -- restart-service rmlic"])
        XCTAssertTrue(alive);XCTAssertEqual(adds,1)
    }
    func testInspectAbsentReadsUSBButNeverStartsOrContactsGuest() throws {
        alive=false
        let result=try engine.perform(["action":"inspect"])
        XCTAssertEqual(result["physicalKeyCount"] as? Int,1)
        XCTAssertEqual(result["protection"] as? String,"unknown")
        XCTAssertEqual(guestCalls,0);XCTAssertEqual(adds,0)
    }
    func testInspectLiveDoesNotCaptureKey() throws {
        _=try engine.perform(["action":"inspect"])
        XCTAssertEqual(adds,0);XCTAssertTrue(alive)
    }
    func testQMPHonorsCancellationButShutdownIgnoresOldCancellation() throws {
        engine.operationCancelled={true}
        XCTAssertThrowsError(try engine.qmp("query-status")) { error in
            guard case VMEngineError.cancelled=error else { return XCTFail("Expected cancellation") }
        }
        try engine.stop()
        XCTAssertFalse(alive)
    }
    func testQMPAbsoluteDeadlineIncludesInjectedTransport() throws {
        engine.qmpTimeout=0.01
        engine.qmpTransport={_,_ in Thread.sleep(forTimeInterval:0.02);return [:]}
        XCTAssertThrowsError(try engine.qmp("query-status")) { error in
            guard case VMEngineError.qmp=error else { return XCTFail("Expected bounded QMP timeout") }
        }
    }

    func testPortCheckRejectsListenerButAcceptsItsClosedConnection() throws {
        let server = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(client) }
        var reuse: Int32 = 1
        XCTAssertEqual(setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)), 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(server, $0, &length)
        } }, 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertEqual(Darwin.listen(server, 1), 0)
        XCTAssertThrowsError(try engine.checkPort(port))
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(client, $0, length)
        } }, 0)
        let peer = Darwin.accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        Darwin.close(peer)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(client, &byte, 1), 0)
        Darwin.shutdown(client, SHUT_WR)
        Darwin.close(server)
        XCTAssertNoThrow(try engine.checkPort(port))
    }

    func testOccupiedUDPPortIsRejectedEvenWhenTCPPortIsFree() throws {
        let fd=Darwin.socket(AF_INET,SOCK_DGRAM,0)
        XCTAssertGreaterThanOrEqual(fd,0);defer {Darwin.close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family=sa_family_t(AF_INET);address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
        XCTAssertEqual(withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}},0)
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&size)}},0)
        let port=Int(UInt16(bigEndian:address.sin_port))
        XCTAssertNoThrow(try engine.checkPort(port))
        XCTAssertThrowsError(try engine.checkPort(port,datagram:true))
    }

    func testUnrelatedQMPEventsCannotExtendTheAbsoluteDeadline() throws {
        let server=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        XCTAssertGreaterThanOrEqual(server,0)
        defer { Darwin.close(server) }
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(runtime.appendingPathComponent("qmp.sock").path.utf8)+[0]
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(server,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        XCTAssertEqual(bound,0);XCTAssertEqual(Darwin.listen(server,1),0)
        let ended=expectation(description:"QMP peer finished")
        DispatchQueue.global().async {
            let peer=Darwin.accept(server,nil,nil)
            defer { if peer>=0 { Darwin.close(peer) };ended.fulfill() }
            guard peer>=0 else { return }
            var noSignal:Int32=1
            setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
            let event=Data("{\"event\":\"unrelated\"}\n".utf8)
            for _ in 0..<100 {
                let count=event.withUnsafeBytes{Darwin.write(peer,$0.baseAddress,$0.count)}
                if count<=0 { break }
                Thread.sleep(forTimeInterval:0.005)
            }
        }
        engine.qmpTransport=nil;engine.qmpTimeout=0.1
        let started=Date()
        XCTAssertThrowsError(try engine.qmp("query-status")) { error in
            guard case VMEngineError.qmp=error else { return XCTFail("Expected QMP timeout") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started),0.5)
        wait(for:[ended],timeout:2)
    }

    func testProtectionChangedWhileArmingCannotReachFirstCapture() throws {
        engine.subscribeRuntimeChanges={_ in self.guardReply="{\"status\":\"ok\",\"no_auto_fwup\":\"0\"}"}
        XCTAssertThrowsError(try engine.perform(["action":"attach"])) { error in
            guard case VMEngineError.safety=error else { return XCTFail("Expected protection refusal") }
        }
        XCTAssertEqual(adds,0);XCTAssertFalse(alive)
    }
    func testProtectionChangedWhileRearmingCannotPublishHealthyTransfer() throws {
        _=try engine.perform(["action":"attach"])
        engine.subscribeRuntimeChanges={_ in self.guardReply="{\"status\":\"ok\",\"no_auto_fwup\":\"0\"}"}
        XCTAssertThrowsError(try engine.perform(["action":"health"])) { error in
            guard case VMEngineError.safety=error else { return XCTFail("Expected protection refusal") }
        }
        XCTAssertEqual(adds,1);XCTAssertFalse(alive)
    }
    func testQMPClosureDuringSubscriptionHandshakeCannotBeLost() throws {
        try checkQMPSubscription(expectedStop:false,closeImmediately:true)
    }
    func testPersistentQMPReusesConnectionAndReportsIdleEOF() throws {
        try checkQMPSubscription(expectedStop:false)
    }
    func testExpectedStopSuppressesQMPObserverCallback() throws {
        try checkQMPSubscription(expectedStop:true)
    }
    private func checkQMPSubscription(expectedStop:Bool,closeImmediately:Bool=false) throws {
        let server=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        XCTAssertGreaterThanOrEqual(server,0)
        defer { Darwin.close(server) }
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(runtime.appendingPathComponent("qmp.sock").path.utf8)+[0]
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(server,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        XCTAssertEqual(bound,0);XCTAssertEqual(Darwin.listen(server,1),0)
        let ended=expectation(description:"QMP peer ended")
        let changed=expectation(description:"QMP observation changed")
        changed.isInverted=expectedStop
        let closePeer=DispatchSemaphore(value:0)
        engine.runtimeChanged={changed.fulfill()}
        DispatchQueue.global().async {
            let peer=Darwin.accept(server,nil,nil)
            defer { if peer>=0 { Darwin.close(peer) };ended.fulfill() }
            guard peer>=0 else { return }
            var noSignal:Int32=1
            setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
            var timeout=timeval(tv_sec:2,tv_usec:0)
            setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
            func send(_ object:[String:Any]) {
                var data=try!JSONSerialization.data(withJSONObject:object);data.append(10)
                _=data.withUnsafeBytes{Darwin.write(peer,$0.baseAddress,$0.count)}
            }
            send(["QMP":[:]])
            for _ in 0..<((expectedStop || closeImmediately) ? 2:3) {
                var line=Data(),byte:UInt8=0
                while Darwin.read(peer,&byte,1)==1 {
                    if byte==10 {break};line.append(byte)
                }
                guard let request=(try?JSONSerialization.jsonObject(with:line)) as? [String:Any] else { return }
                send(["id":request["id"]!,"return":[:]])
            }
            if !closeImmediately { _=closePeer.wait(timeout:.now()+2) }
        }
        engine.qmpTransport=nil
        _=try engine.qmp("query-status",observe:true)
        if expectedStop {
            alive=false
            try engine.stop()
        } else if !closeImmediately {
            // This command must use the already negotiated socket: the fixture
            // accepts exactly one connection and expects no second handshake.
            _=try engine.qmp("query-status")
        }
        closePeer.signal()
        wait(for:[ended,changed],timeout:expectedStop ? 0.3:2)
        if !expectedStop {
            XCTAssertThrowsError(try engine.qmp("query-status")) { error in
                guard case VMEngineError.qmp=error else { return XCTFail("Expected lost-channel refusal") }
            }
        }
    }

}
