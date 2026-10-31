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
    func testRollbackRetainsBothGenerationsAndRejectsDamagedTarget() throws {
        let runtime=URL(fileURLWithPath:"/tmp/kb-gen-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(runtime)
        defer { try?FileManager.default.removeItem(at:runtime) }
        let store=GenerationStore(runtime:runtime)
        let first=try generationFixture(runtime),second=try generationFixture(runtime)
        try store.publish(first);try store.publish(second)
        let rollback=try store.rollback(nil)
        XCTAssertEqual(rollback.id,first["generation"] as? String)
        try store.publish(rollback.manifest)
        XCTAssertEqual(store.records().count,2)
        let secondFolder=try store.validate(second).folder
        try FileManager.default.removeItem(at:secondFolder.appendingPathComponent("guest.json"))
        XCTAssertThrowsError(try store.rollback(second["generation"] as? String))
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
}
