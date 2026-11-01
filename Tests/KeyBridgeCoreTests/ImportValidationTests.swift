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
