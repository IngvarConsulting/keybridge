// SPDX-License-Identifier: MIT
import XCTest
import Darwin
@testable import KeyBridgeCore

final class ClientInstallationTests:XCTestCase {
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
    private func executable(_ root:URL,_ version:String,cpu:UInt32) throws {
        let directory=root.appendingPathComponent(version)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=directory.appendingPathComponent("1cv8")
        var data=Data([0xcf,0xfa,0xed,0xfe]);data.append(contentsOf:(0..<4).map{UInt8((cpu>>($0*8))&0xff)})
        try data.write(to:file);chmod(file.path,0o700)
    }
}
