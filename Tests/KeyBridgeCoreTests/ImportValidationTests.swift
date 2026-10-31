// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import KeyBridgeCore

final class ImportValidationTests: XCTestCase {
    func testContentsDetermineFormatRegardlessOfFilenameOrPayload() throws {
        try withFiles { installer, driver in
            var elf = header()
            elf.append(Data("different vendor packaging".utf8))
            try elf.write(to: installer)
            try Data("!<arch>\narbitrary package bytes".utf8).write(to: driver)
            try ImportValidation.check(installer: installer, driver: driver)
        }
    }

    func testRejectsOtherArchitectureWindowsAndTruncatedInstaller() throws {
        try withFiles { installer, driver in
            try Data("!<arch>\n".utf8).write(to: driver)
            var arm = header(); arm[18] = 183
            var elf32 = header(); elf32[4] = 1
            for bytes in [arm, elf32, Data("MZ windows executable".utf8), Data([0x7f, 0x45, 0x4c, 0x46])] {
                try bytes.write(to: installer)
                XCTAssertThrowsError(try ImportValidation.check(installer: installer, driver: driver))
            }
        }
    }

    func testRenamingNonArchiveToDebDoesNotPass() throws {
        try withFiles { installer, driver in
            try header().write(to: installer)
            try Data("<html>download error</html>".utf8).write(to: driver)
            XCTAssertThrowsError(try ImportValidation.check(installer: installer, driver: driver))
        }
    }

    private func header() -> Data {
        var elf = Data(repeating: 0, count: 64)
        elf.replaceSubrange(0..<7, with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1])
        elf[16] = 2; elf[18] = 62
        return elf
    }

    private func withFiles(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("renamed installer.run"), root.appendingPathComponent("renamed driver.deb"))
    }
}

extension ImportValidationTests {
    func testDriverMetadataAllowsFutureVersionAndRejectsWrongArchitectureOrPackage() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("kb-driver-"+UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(root);defer{try?FileManager.default.removeItem(at:root)}
        func package(_ name:String,_ architecture:String) throws ->URL {
            try Data("Package: \(name)\nArchitecture: \(architecture)\nVersion: 99.3-unknown-future\n".utf8).write(to:root.appendingPathComponent("control"))
            let archive=root.appendingPathComponent("control.tar")
            let result=try hostCommand("/usr/bin/tar",["-cf",archive.path,"-C",root.path,"control"])
            XCTAssertEqual(result.code,0)
            let bytes=try Data(contentsOf:archive)
            func field(_ s:String,_ width:Int)->String {s+String(repeating:" ",count:width-s.count)}
            let header=field("control.tar/",16)+field("0",12)+field("0",6)+field("0",6)+field("100644",8)+field(String(bytes.count),10)+"`\n"
            var deb=Data("!<arch>\n".utf8);deb.append(Data(header.utf8));deb.append(bytes)
            let file=root.appendingPathComponent("arbitrary-name.deb");try deb.write(to:file);return file
        }
        let future=try ImportValidation.inspect(package("aksusbd","amd64"),kind:"driver")
        XCTAssertEqual(future["valid"] as?Bool,true)
        XCTAssertEqual(future["version"] as?String,"99.3-unknown-future")
        XCTAssertEqual(future["validation"] as?String,"preliminary")
        XCTAssertThrowsError(try ImportValidation.inspect(package("aksusbd","arm64"),kind:"driver"))
        XCTAssertThrowsError(try ImportValidation.inspect(package("other","amd64"),kind:"driver"))
    }
}
