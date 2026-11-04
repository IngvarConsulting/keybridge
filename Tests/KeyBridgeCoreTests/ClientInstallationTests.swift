// SPDX-License-Identifier: MIT
import XCTest
import Darwin
@testable import KeyBridgeCore

final class ClientInstallationTests:XCTestCase {
    func testObservationDetectsChangedConfigurationAndRemovedClient() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("kb-observer-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(root);defer { try?FileManager.default.removeItem(at:root) }
        try executable(root,"9.1.1.1",cpu:0x0100000c)
        let conf=root.appendingPathComponent("conf")
        try FileManager.default.createDirectory(at:conf,withIntermediateDirectories:true)
        let target=conf.appendingPathComponent("nethasp.ini")
        try ClientInstallation.managedConfiguration.write(to:target)
        try ClientInstallation.managedClientConfiguration.write(to:conf.appendingPathComponent("rclic.cfg"))
        let observer=ClientObservation(root:root,owner:getuid())
        XCTAssertEqual(observer.read()["clientState"] as? String,"configured", String(describing: observer.read()))
        try Data("external settings".utf8).write(to:target,options:.atomic)
        XCTAssertEqual(observer.read()["clientState"] as? String,"external")
        try FileManager.default.removeItem(at:root.appendingPathComponent("9.1.1.1/1cv8"))
        XCTAssertEqual(observer.read()["clientState"] as? String,"missing")
    }
    func testChoosesNewestNativeClientByCapabilityWithoutReleaseAllowlist() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("kb-clients-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(root);defer{try?FileManager.default.removeItem(at:root)}
        try executable(root,"8.5.4.1878",cpu:0x0100000c)
        try executable(root,"9.12.45.6789",cpu:0x0100000c)
        try executable(root,"99.1.1.1",cpu:0x01000007)
        XCTAssertEqual(ClientInstallation.discover(root:root,owner:getuid())?.version,"9.12.45.6789")
        XCTAssertEqual(ClientInstallation.discover(root:root,owner:getuid())?.configuration.lastPathComponent,"nethasp.ini")
    }
    func testSymlinkAndWritableClientCannotBecomePrivilegedConfigurationTarget() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("kb-clients-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(root);defer{try?FileManager.default.removeItem(at:root)}
        try executable(root,"9.1.1.1",cpu:0x0100000c)
        chmod(root.appendingPathComponent("9.1.1.1/1cv8").path,0o777)
        XCTAssertNil(ClientInstallation.discover(root:root,owner:getuid()))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("99.1.1.1"),withDestinationURL:root.appendingPathComponent("9.1.1.1"))
        chmod(root.appendingPathComponent("9.1.1.1/1cv8").path,0o700)
        XCTAssertEqual(ClientInstallation.discover(root:root,owner:getuid())?.version,"9.1.1.1")
    }
    func testSharedPairHasOneRestorePointAndDetectsOverridesInOldAndThinClients() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("kb-shared-pair-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(root);defer {try?FileManager.default.removeItem(at:root)}
        let shared=root.appendingPathComponent("conf")
        try FileManager.default.createDirectory(at:shared,withIntermediateDirectories:true)
        var clients=[ClientInstallation]()
        for (version,cpu) in [("8.3.27.1",UInt32(0x01000007)),("8.5.4.1",UInt32(0x0100000c))] {
            try executable(root,version,cpu:cpu)
            let directory=root.appendingPathComponent(version)
            try FileManager.default.createDirectory(at:directory.appendingPathComponent("conf"),withIntermediateDirectories:true)
            try Data(("ConfLocation="+shared.path+"\n").utf8).write(to:directory.appendingPathComponent("conf/conf.cfg"))
            clients.append(ClientInstallation(directory:directory,owner:getuid()))
        }
        let files=clients[1].configurationFiles()
        XCTAssertEqual(files,clients[0].configurationFiles())
        XCTAssertEqual(try clients[0].configurationBackup(),try clients[1].configurationBackup())
        let backupBefore=try clients[1].configurationBackup()
        for (file,data) in zip(files,ClientInstallation.managedConfigurations) {try data.write(to:file)}
        let observer=ClientObservation(root:root,owner:getuid())
        XCTAssertEqual(observer.read()["clientState"] as? String,"configured", String(describing: observer.read()))
        let revision=observer.read()["clientRevision"] as? String
        let override=clients[0].configuration
        try Data("[NH_COMMON]\nNH_TCPIP=Disabled\n".utf8).write(to:override)
        XCTAssertEqual(observer.read()["clientState"] as? String,"configured", "Another version must not block the selected client")
        XCTAssertTrue((observer.read()["configurationError"] as? String ?? "").contains(override.path))
        XCTAssertNotEqual(observer.read()["clientRevision"] as? String,revision)
        // Existing equivalent overrides, including comments, require no mutation.
        try (Data("; unrelated comment\n".utf8)+ClientInstallation.managedConfiguration).write(to:override)
        XCTAssertEqual(observer.read()["clientState"] as? String,"configured", String(describing: observer.read()))
        try FileManager.default.moveItem(at:clients[0].executable,to:clients[0].directory.appendingPathComponent("1cv8c"))
        try Data("different settings".utf8).write(to:override)
        XCTAssertTrue((observer.read()["configurationError"] as? String ?? "").contains(override.path), "A thin-only old client must not be skipped")
        chmod(override.path,0o000)
        XCTAssertEqual(observer.read()["clientState"] as? String,"configured", "An unreadable file in another version must not stop the selected client")
        XCTAssertTrue((observer.read()["configurationError"] as? String ?? "").contains(override.path))
        chmod(override.path,0o644)
        try FileManager.default.removeItem(at:override)
        XCTAssertEqual(observer.read()["clientState"] as? String,"configured", String(describing: observer.read()))
        try Data("ConfLocation=/another/location\n".utf8).write(to:clients[0].directory.appendingPathComponent("conf/conf.cfg"))
        XCTAssertTrue((observer.read()["configurationError"] as? String ?? "").contains("conf.cfg"))
        try Data("different selected settings".utf8).write(to:clients[1].configuration)
        XCTAssertEqual(observer.read()["clientState"] as? String,"unknown", "Selected client overrides must prevent a false configured state")
        try FileManager.default.removeItem(at:clients[1].configuration)
        try FileManager.default.removeItem(at:files[1])
        XCTAssertEqual(try clients[1].configurationBackup(),backupBefore, "Deleting a file or replacing the selected version must not hide the shared restore point")
        XCTAssertFalse(FileManager.default.fileExists(atPath:clients[1].configuration.path))
    }
    private func executable(_ root:URL,_ version:String,cpu:UInt32) throws {
        let directory=root.appendingPathComponent(version)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=directory.appendingPathComponent("1cv8")
        var data=Data([0xcf,0xfa,0xed,0xfe]);data.append(contentsOf:(0..<4).map{UInt8((cpu>>($0*8))&0xff)})
        try data.write(to:file);chmod(file.path,0o700)
    }
}
