// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

// A structurally valid fixture, deliberately not a bootable image.
func generationFixture(_ runtime:URL,id:String=UUID().uuidString) throws ->[String:Any] {
    let folder=runtime.appendingPathComponent("generations/"+id)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    try writeObject(["backend":"alpine","memoryMiB":128,"cpus":1],to:folder.appendingPathComponent("guest.json"))
    for name in ["vmlinuz-virt","initramfs-virt","id_ed25519","known_hosts"] {
        try Data("fixture".utf8).write(to:folder.appendingPathComponent(name))
    }
    try Data([0x51,0x46,0x49,0xfb]).write(to:folder.appendingPathComponent("guest.qcow2"))
    return ["generation":id,"backend":"alpine","memoryMiB":128,"cpus":1,"version":"fixture"]
}
final class GenerationStoreTests:XCTestCase {
    func testSnapshotKeepsPointerSafetyAndRevalidatesNextObservation() throws {
        let runtime=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer {try?FileManager.default.removeItem(at:runtime)}
        let store=GenerationStore(runtime:runtime),record=try generationFixture(runtime)
        try store.publish(record)
        XCTAssertNotNil(store.snapshot().current)
        let disk=try store.current().folder.appendingPathComponent("guest.qcow2")
        try Data("bad!".utf8).write(to:disk)
        XCTAssertNil(store.snapshot().current)
        XCTAssertEqual(store.snapshot().summaries.first?["valid"] as? Bool,false)
        try Data([0x51,0x46,0x49,0xfb]).write(to:disk)
        let pointer=runtime.appendingPathComponent("current.json"),other=runtime.appendingPathComponent("alias.json")
        try FileManager.default.moveItem(at:pointer,to:other)
        try FileManager.default.createSymbolicLink(at:pointer,withDestinationURL:other)
        XCTAssertNil(store.snapshot().current)
    }
    func testRollbackRetainsBothGenerationsAndRejectsDamagedTarget() throws {
        let runtime=URL(fileURLWithPath:"/tmp/kb-gen-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer { try?FileManager.default.removeItem(at:runtime) }
        let store=GenerationStore(runtime:runtime)
        let first=try generationFixture(runtime),second=try generationFixture(runtime)
        try store.publish(first);try store.publish(second)
        let rollback=try store.rollback()
        XCTAssertEqual(rollback.id,first["generation"] as? String)
        try store.publish(rollback.manifest)
        XCTAssertEqual(store.records().count,2)
        let secondFolder=try store.validate(second).folder
        try FileManager.default.removeItem(at:secondFolder.appendingPathComponent("guest.json"))
        XCTAssertThrowsError(try store.rollback())
        XCTAssertEqual(try store.current().id,rollback.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath:secondFolder.appendingPathComponent("guest.qcow2").path))
    }
    func testPointerCannotBlessIncompleteOrUnknownBackend() throws {
        let runtime=URL(fileURLWithPath:"/tmp/kb-gen-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer { try?FileManager.default.removeItem(at:runtime) }
        var record=try generationFixture(runtime)
        let store=GenerationStore(runtime:runtime)
        record["backend"]="unknown"
        XCTAssertThrowsError(try store.publish(record))
        XCTAssertFalse(FileManager.default.fileExists(atPath:runtime.appendingPathComponent("current.json").path))
    }
    func testFailedRollbackPublicationPreservesRetryTargetAndRetainedInstallations() throws {
        let runtime=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer {try?FileManager.default.removeItem(at:runtime)}
        var store=GenerationStore(runtime:runtime)
        let first=try generationFixture(runtime),second=try generationFixture(runtime),third=try generationFixture(runtime)
        try store.publish(first);try store.publish(second);try store.publish(third)
        let before=try Data(contentsOf:runtime.appendingPathComponent("current.json"))
        store.writeSelection={_,_ in throw BridgeError("injected atomic write failure")}
        XCTAssertThrowsError(try store.publish(store.rollback().manifest))
        XCTAssertEqual(try Data(contentsOf:runtime.appendingPathComponent("current.json")),before)
        XCTAssertEqual(try store.current().id,third["generation"] as? String)
        XCTAssertEqual(try store.rollback().id,second["generation"] as? String)
        XCTAssertEqual(store.records().count,3)
        let retry=GenerationStore(runtime:runtime)
        try retry.publish(retry.rollback().manifest)
        XCTAssertEqual(try retry.current().id,second["generation"] as? String)
        XCTAssertEqual(try retry.rollback().id,third["generation"] as? String)
        XCTAssertEqual(retry.records().count,3)
    }
    func testLegacySelectionMigratesTogetherAndIgnoresStalePreviousFile() throws {
        let runtime=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer {try?FileManager.default.removeItem(at:runtime)}
        let first=try generationFixture(runtime),second=try generationFixture(runtime)
        try writeObject(first,to:runtime.appendingPathComponent("previous.json"))
        try writeObject(second,to:runtime.appendingPathComponent("current.json"))
        let store=GenerationStore(runtime:runtime)
        try store.publish(store.rollback().manifest)
        XCTAssertEqual(try store.current().id,first["generation"] as? String)
        XCTAssertEqual(try store.rollback().id,second["generation"] as? String)
        try writeObject([:],to:runtime.appendingPathComponent("previous.json"))
        XCTAssertEqual(try store.rollback().id,second["generation"] as? String)
    }
    func testLegacyPreviousSymlinkAndUnsupportedDebianAreRejected() throws {
        let runtime=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer {try?FileManager.default.removeItem(at:runtime)}
        var record=try generationFixture(runtime)
        try writeObject(record,to:runtime.appendingPathComponent("current.json"))
        try FileManager.default.createSymbolicLink(at:runtime.appendingPathComponent("previous.json"),withDestinationURL:runtime.appendingPathComponent("current.json"))
        let store=GenerationStore(runtime:runtime)
        XCTAssertThrowsError(try store.rollback())
        record["backend"]="debian"
        let folder=runtime.appendingPathComponent("generations/"+(record["generation"] as! String))
        try writeObject(["backend":"debian"],to:folder.appendingPathComponent("guest.json"))
        XCTAssertThrowsError(try store.validate(record))
    }

}
