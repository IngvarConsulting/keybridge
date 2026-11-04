// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class ConfigurationTransactionTests:XCTestCase {
    var root:URL!
    var target:URL {root.appendingPathComponent("nethasp.ini")}
    var backup:URL {root.appendingPathComponent("backup")}
    let expected=Data("managed".utf8)
    let first=Data("settings A".utf8),second=Data("settings B".utf8),foreign=Data("settings C".utf8)
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {try FileManager.default.removeItem(at:root)}
    func transaction()->ConfigurationTransaction {ConfigurationTransaction(target:target,backup:backup,expected:expected,verifyPath:{_,_ in})}
    func testApplyRejectsExternalSettingsAndVerifiedAbsenceCanBeRestored() throws {
        try first.write(to:target)
        XCTAssertThrowsError(try transaction().perform("apply"))
        XCTAssertEqual(try Data(contentsOf:target),first)
        XCTAssertFalse(FileManager.default.fileExists(atPath:backup.appendingPathComponent("metadata.json").path))
        try FileManager.default.removeItem(at:target)
        XCTAssertEqual(try transaction().perform("apply"),"configured")
        XCTAssertEqual(try Data(contentsOf:target),expected)
        XCTAssertEqual(try transaction().perform("restore"),"restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func testLatestSuccessfulRepairRestoresExternalSettingsAndBlocksLaterConflict() throws {
        try first.write(to:target)
        XCTAssertEqual(try transaction().perform("repair"),"configured")
        try second.write(to:target)
        XCTAssertEqual(try transaction().perform("repair"),"configured")
        try foreign.write(to:target)
        XCTAssertThrowsError(try transaction().perform("restore"))
        XCTAssertEqual(try Data(contentsOf:target),foreign)
        try expected.write(to:target)
        XCTAssertEqual(try transaction().perform("restore"),"restored")
        XCTAssertEqual(try Data(contentsOf:target),second)
        XCTAssertEqual(try transaction().perform("restore"),"restored")
    }
    func testFailedTargetWritePreservesLastSuccessfulRestorePoint() throws {
        try first.write(to:target);_=try transaction().perform("repair")
        let before=try Data(contentsOf:backup.appendingPathComponent("metadata.json"))
        try second.write(to:target)
        var failing=transaction();let writer=failing.writeFile
        failing.writeFile={data,url,mode in
            if url==self.target {throw BridgeError("injected target write failure")}
            try writer(data,url,mode)
        }
        XCTAssertThrowsError(try failing.perform("repair"))
        XCTAssertEqual(try Data(contentsOf:target),second)
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("metadata.json")),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:backup.appendingPathComponent("pending.json").path))
        XCTAssertThrowsError(try transaction().perform("restore"))
        XCTAssertEqual(try Data(contentsOf:target),second)
    }
    func testCrashBeforeTargetWriteDiscardsAttemptWithoutReplacingSuccessfulPoint() throws {
        try first.write(to:target);_=try transaction().perform("repair")
        let before=try Data(contentsOf:backup.appendingPathComponent("metadata.json"))
        try second.write(to:target)
        var failing=transaction();let writer=failing.writeFile
        failing.writeFile={data,url,mode in
            try writer(data,url,mode)
            if url.lastPathComponent=="pending.json" {throw BridgeError("crash after pending publication")}
        }
        XCTAssertThrowsError(try failing.perform("repair"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.appendingPathComponent("pending.json").path))
        XCTAssertThrowsError(try transaction().perform("restore"))
        XCTAssertEqual(try Data(contentsOf:target),second)
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("metadata.json")),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:backup.appendingPathComponent("pending.json").path))
    }
    func testCrashAfterTargetWriteReconcilesBeforeRestore() throws {
        try first.write(to:target);_=try transaction().perform("repair")
        try second.write(to:target)
        var failing=transaction();let writer=failing.writeFile
        failing.writeFile={data,url,mode in
            if url.lastPathComponent=="metadata.json" {throw BridgeError("injected publication failure")}
            try writer(data,url,mode)
        }
        XCTAssertThrowsError(try failing.perform("repair"))
        XCTAssertEqual(try Data(contentsOf:target),expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.appendingPathComponent("pending.json").path))
        XCTAssertEqual(try transaction().perform("restore"),"restored")
        XCTAssertEqual(try Data(contentsOf:target),second)
    }
    func testUnknownEffectWithForeignBytesBlocksWritesAndKeepsPending() throws {
        try first.write(to:target);_=try transaction().perform("repair")
        let before=try Data(contentsOf:backup.appendingPathComponent("metadata.json"))
        try second.write(to:target)
        var failing=transaction();let writer=failing.writeFile
        failing.writeFile={data,url,mode in
            if url==self.target {try self.foreign.write(to:url);throw BridgeError("unknown write effect")}
            try writer(data,url,mode)
        }
        XCTAssertThrowsError(try failing.perform("repair"))
        for action in ["repair","apply","restore"] {XCTAssertThrowsError(try transaction().perform(action))}
        XCTAssertEqual(try Data(contentsOf:target),foreign)
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("metadata.json")),before)
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.appendingPathComponent("pending.json").path))
    }
    func testDamagedOriginalCannotBeRestored() throws {
        try first.write(to:target);_=try transaction().perform("repair")
        let metadata=readObject(backup.appendingPathComponent("metadata.json"))
        try foreign.write(to:backup.appendingPathComponent(metadata["originalFile"] as! String))
        XCTAssertThrowsError(try transaction().perform("restore"))
        XCTAssertEqual(try Data(contentsOf:target),expected)
    }
    func testMissingAndEmptyOriginalRemainDistinctAndRepeatedApplyIsNoOp() throws {
        for original in [nil,Data()] as [Data?] {
            if let original {try original.write(to:target)}
            _=try transaction().perform("repair")
            let before=try Data(contentsOf:backup.appendingPathComponent("metadata.json"))
            _=try transaction().perform("apply")
            XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("metadata.json")),before)
            _=try transaction().perform("restore")
            XCTAssertEqual(try? Data(contentsOf:target),original)
        }
    }
    func testBackupFailureNeverChangesTargetOrLastSuccessfulPoint() throws {
        try first.write(to:target);_=try transaction().perform("repair")
        let before=try Data(contentsOf:backup.appendingPathComponent("metadata.json"))
        try second.write(to:target)
        var failing=transaction()
        failing.writeFile={_,_,_ in throw BridgeError("injected backup failure")}
        XCTAssertThrowsError(try failing.perform("repair"))
        XCTAssertEqual(try Data(contentsOf:target),second)
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("metadata.json")),before)
    }
    var secondTarget:URL {root.appendingPathComponent("rclic.cfg")}
    func pair()->ConfigurationTransaction {
        ConfigurationTransaction(targets:[target,secondTarget],backup:backup,expected:[expected,expected],verifyPath:{_,_ in})
    }
    func testSecondFileFailureRollsBackWholeAttemptWithoutReplacingCheckpoint() throws {
        try first.write(to:target);try second.write(to:secondTarget)
        _=try pair().perform("repair")
        let checkpoint=try Data(contentsOf:backup.appendingPathComponent("metadata.json"))
        try second.write(to:target);try first.write(to:secondTarget)
        var failing=pair();let write=failing.writeFile
        failing.writeFile={data,url,mode in
            if url==self.secondTarget && data==self.expected {throw BridgeError("second target failed")}
            try write(data,url,mode)
        }
        XCTAssertThrowsError(try failing.perform("repair"))
        XCTAssertEqual(try Data(contentsOf:target),second)
        XCTAssertEqual(try Data(contentsOf:secondTarget),first)
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("metadata.json")),checkpoint)
    }
    func testInterruptedPairRestoreResumesAndPreservesAbsenceVersusEmpty() throws {
        try Data().write(to:target)
        _=try pair().perform("apply")
        var failing=pair();let write=failing.writeFile
        failing.writeFile={data,url,mode in
            try write(data,url,mode)
            if url==self.target {throw BridgeError("crash after first restore")}
        }
        XCTAssertThrowsError(try failing.perform("restore"))
        XCTAssertEqual(try Data(contentsOf:target),Data())
        XCTAssertEqual(try Data(contentsOf:secondTarget),expected)
        XCTAssertEqual(try pair().perform("restore"),"restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath:secondTarget.path))
    }
    func testForeignSecondFileAndDamagedSecondBackupForbidWritingFirstFile() throws {
        try first.write(to:target);try second.write(to:secondTarget)
        _=try pair().perform("repair")
        try foreign.write(to:secondTarget)
        XCTAssertThrowsError(try pair().perform("restore"))
        XCTAssertEqual(try Data(contentsOf:target),expected)
        try expected.write(to:secondTarget)
        let files=readObject(backup.appendingPathComponent("metadata.json"))["files"] as! [[String:Any]]
        try foreign.write(to:backup.appendingPathComponent(files[1]["originalFile"] as! String))
        XCTAssertThrowsError(try pair().perform("restore"))
        XCTAssertEqual(try Data(contentsOf:target),expected)
        XCTAssertEqual(try Data(contentsOf:secondTarget),expected)
    }
    func testCompletedPairWithFailedPublicationIsReconciledBeforeRestore() throws {
        try first.write(to:target);try second.write(to:secondTarget)
        var failing=pair();let write=failing.writeFile
        failing.writeFile={data,url,mode in
            if url.lastPathComponent=="metadata.json" {throw BridgeError("publication failed")}
            try write(data,url,mode)
        }
        XCTAssertThrowsError(try failing.perform("repair"))
        XCTAssertEqual(try Data(contentsOf:target),expected)
        XCTAssertEqual(try Data(contentsOf:secondTarget),expected)
        _=try pair().perform("restore")
        XCTAssertEqual(try Data(contentsOf:target),first)
        XCTAssertEqual(try Data(contentsOf:secondTarget),second)
    }

}
