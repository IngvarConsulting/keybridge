// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class EvidenceAndResourcesTests:XCTestCase {
    func testRotationResetMissingAndChangedPrefixInvalidateContinuity() {
        let source:[String:Any]=["name":"fixture","inode":UInt64(123),"bytes":4096,"digest":"wholeOriginal","baselineDigest":"wholeOriginal"]
        let before:[String:Any]=["available":true,"sources":[source]]
        XCTAssertTrue(LicenseEvidence.continuous(before:before,after:before))
        for patch:[String:Any] in [["inode":UInt64(124)],["bytes":10],["baselineDigest":"replacement"],["baselineDigest":NSNull()]] {
            var changed=source;changed.merge(patch){_,n in n}
            XCTAssertFalse(LicenseEvidence.continuous(before:before,after:["available":true,"sources":[changed]]))
        }
        XCTAssertFalse(LicenseEvidence.continuous(before:before,after:["available":true,"sources":[]]))
        XCTAssertFalse(LicenseEvidence.continuous(before:["available":false],after:before))
    }
    func testQMPMustConfirmExactCapturedDeviceNotVendorMatch() {
        let connection=USBConnection(bus:3,address:7,epoch:"fixture")
        let tree="""
        dev: usb-host, id "physical_hasp"
          hostbus = 3 (0x3)
          hostaddr = 7 (0x7)
          attached
        dev: other
          hostbus = 4 (0x4)
        """
        XCTAssertTrue(USBTransfer.matches(tree,connection:connection))
        XCTAssertFalse(USBTransfer.matches(tree,connection:USBConnection(bus:4,address:7,epoch:"fixture")))
        XCTAssertFalse(USBTransfer.matches(tree.replacingOccurrences(of:"attached",with:""),connection:connection))
    }
    func testPhysicalDiskUsageDoesNotFollowSymlinksOrConfuseSparseSize() throws {
        let root=URL(fileURLWithPath:"/tmp/kb-res-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(root);defer{try?FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("sparse")
        FileManager.default.createFile(atPath:file.path,contents:Data([1]))
        let handle=try FileHandle(forWritingTo:file);try handle.truncate(atOffset:16*1024*1024);try handle.close()
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("outside"),withDestinationURL:URL(fileURLWithPath:"/Users"))
        let usage=RuntimeResources.bytes(root)
        XCTAssertEqual(usage["logicalBytes"] as? Int64,16*1024*1024)
        XCTAssertLessThan(try XCTUnwrap(usage["allocatedBytes"] as? Int64),16*1024*1024)
    }
}

extension EvidenceAndResourcesTests {
    func testResourcesKeepPreviousRetainedAndCandidatesDistinctAndReadVirtualCapacity() throws {
        let root=URL(fileURLWithPath:"/tmp/kb-res-roles-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(root);defer{try?FileManager.default.removeItem(at:root)}
        let store=GenerationStore(runtime:root)
        let first=try generationFixture(root),second=try generationFixture(root),third=try generationFixture(root),candidate=try generationFixture(root)
        try store.publish(first);try store.publish(second);try store.publish(third)
        var qcow=Data(repeating:0,count:72);qcow.replaceSubrange(0..<8,with:[0x51,0x46,0x49,0xfb,0,0,0,3])
        let capacity=UInt64(5)*1024*1024*1024
        qcow.replaceSubrange(24..<32,with:(0..<8).map {UInt8((capacity>>((7-$0)*8))&0xff)})
        try qcow.write(to:store.current().folder.appendingPathComponent("guest.qcow2"))
        let usage=RuntimeResources.disk(runtime:root,resources:root)
        let records=try XCTUnwrap(usage["generations"] as? [[String:Any]])
        func role(_ record:[String:Any])->String? {records.first{$0["generation"] as?String==record["generation"] as?String}?["role"] as?String}
        XCTAssertEqual(role(third),"selected");XCTAssertEqual(role(second),"previous");XCTAssertEqual(role(first),"retained");XCTAssertEqual(role(candidate),"candidate")
        XCTAssertEqual(usage["virtualDiskBytes"] as?Int64,Int64(capacity))
        XCTAssertEqual(store.presentation()["previousValid"] as?Bool,true)
        try FileManager.default.removeItem(at:store.validate(second).folder.appendingPathComponent("known_hosts"))
        XCTAssertEqual(store.presentation()["previousAvailable"] as?Bool,true)
        XCTAssertEqual(store.presentation()["previousValid"] as?Bool,false)
    }
}
