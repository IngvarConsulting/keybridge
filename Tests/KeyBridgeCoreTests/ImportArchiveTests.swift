// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import KeyBridgeCore

final class ImportArchiveTests: XCTestCase {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kb-import-tests-" + UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    func testDirectInputIsPrivateSnapshotAndDoesNotDependOnFilename() throws {
        try withFolder { root in
            let input = root.appendingPathComponent("renamed.data")
            let original = ImportFixture.elf()
            try original.write(to: input)
            let found = try ImportArchive.resolve(input, kind: "installer", directory: root.appendingPathComponent("result"))
            XCTAssertEqual(found.count, 1)
            XCTAssertNotEqual(found[0].file, input)
            try Data("changed source".utf8).write(to: input)
            XCTAssertEqual(try Data(contentsOf: found[0].file), original)
        }
    }

    func testNestedArchiveSelectsActualAMD64PackageAmongOtherArchitectures() throws {
        try withFolder { root in
            let nested = ImportFixture.tar([
                .init("pkg/renamed-a", data: ImportFixture.deb(architecture: "arm64")),
                .init("pkg/renamed-b", data: ImportFixture.deb()),
                .init("readme.txt", data: Data("Do not run scripts".utf8))
            ])
            let input = root.appendingPathComponent("distribution.tar")
            try ImportFixture.tar([.init("vendor/archive.tar", data: nested)]).write(to: input)
            let found = try ImportArchive.resolve(input, kind: "driver", directory: root.appendingPathComponent("result"))
            XCTAssertEqual(found.count, 1)
            XCTAssertTrue(found[0].displayName.hasSuffix("pkg/renamed-b"))
            let inspected = try ImportValidation.inspect(found[0].file, kind: "driver")
            XCTAssertEqual(inspected["validation"] as? String, "complete")
            XCTAssertEqual(inspected["version"] as? String, "99.3-unknown-future")
        }
    }

    func testRunInstallerIsSelectedWithoutELFLauncherHelper() throws {
        try withFolder { root in
            let input = root.appendingPathComponent("server64.zip")
            let directory = root.appendingPathComponent("result")
            let installer = ImportFixture.elf() + Data("actual installer".utf8)
            try ImportFixture.tar([
                .init("installAsRoot", data: ImportFixture.elf()),
                .init("setup-full.run", data: installer)
            ]).write(to: input)
            let found = try ImportArchive.resolve(input, kind: "installer", directory: directory)
            XCTAssertEqual(found.count, 1)
            XCTAssertTrue(found[0].displayName.hasSuffix("setup-full.run"))
            XCTAssertEqual(try Data(contentsOf: found[0].file), installer)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { $0.resolvingSymlinksInPath() }, [found[0].file.resolvingSymlinksInPath()])
        }
    }

    func testMultipleSuitableComponentsAreReturnedForExplicitSelection() throws {
        try withFolder { root in
            let input = root.appendingPathComponent("two.tar")
            try ImportFixture.tar([.init("one.run", data: ImportFixture.elf()), .init("two.run", data: ImportFixture.elf()), .init("installAsRoot", data: ImportFixture.elf())]).write(to: input)
            let found = try ImportArchive.resolve(input, kind: "installer", directory: root.appendingPathComponent("result"))
            XCTAssertEqual(found.count, 2)
            XCTAssertNotEqual(found[0].file, found[1].file)
        }
    }

    func testZipReadsContentsAndRejectsCorruptPayload() throws {
        try withFolder { root in
            let payload = ImportFixture.elf() + Data("unique-payload-for-checksum".utf8)
            try payload.write(to: root.appendingPathComponent("candidate"))
            let zip = root.appendingPathComponent("download.zip")
            let command = try hostCommand("/usr/bin/zip", ["-j", "-0", zip.path, root.appendingPathComponent("candidate").path])
            XCTAssertEqual(command.code, 0)
            XCTAssertEqual(try ImportArchive.resolve(zip, kind: "installer", directory: root.appendingPathComponent("valid")).count, 1)
            var bytes = try Data(contentsOf: zip)
            let position = try XCTUnwrap(bytes.range(of: Data("unique-payload-for-checksum".utf8))).lowerBound
            bytes[position] ^= 1
            try bytes.write(to: zip)
            XCTAssertThrowsError(try ImportArchive.resolve(zip, kind: "installer", directory: root.appendingPathComponent("corrupt")))
        }
    }

    func testRejectsTraversalLinksDuplicatesAndDeclaredOversizedMembers() throws {
        let invalid: [[ImportFixture.Member]] = [
            [.init("../outside.run", data: ImportFixture.elf())],
            [.init("/outside.run", data: ImportFixture.elf())],
            [.init("alias.run", type: "2", link: "../outside")],
            [.init("alias.run", type: "1", link: "target")],
            [.init("same", data: ImportFixture.elf()), .init("./same", data: ImportFixture.elf())],
            [.init("huge", declaredSize: 9 * 1024 * 1024 * 1024)]
        ]
        for members in invalid {
            try withFolder { root in
                let archive = root.appendingPathComponent("invalid.tar")
                try ImportFixture.tar(members).write(to: archive)
                XCTAssertThrowsError(try ImportArchive.resolve(archive, kind: "installer", directory: root.appendingPathComponent("out")))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.run").path))
            }
        }
    }

    func testTruncatedArchiveAndCancellationNeverReturnCandidate() throws {
        try withFolder { root in
            let archive = root.appendingPathComponent("truncated.tar")
            let full = ImportFixture.tar([.init("installer", data: ImportFixture.elf())])
            try full.prefix(540).write(to: archive)
            XCTAssertThrowsError(try ImportArchive.resolve(archive, kind: "installer", directory: root.appendingPathComponent("truncated")))
            try full.write(to: archive)
            XCTAssertThrowsError(try ImportArchive.resolve(archive, kind: "installer", directory: root.appendingPathComponent("cancelled"), cancelled: { true }))
        }
    }

    func testDriverRequiresFullActualExecutablePayloadWithoutVersionPinning() throws {
        try withFolder { root in
            let file = root.appendingPathComponent("driver.deb")
            try ImportFixture.deb().write(to: file)
            let valid = try ImportValidation.inspect(file, kind: "driver")
            XCTAssertEqual(valid["valid"] as? Bool, true)
            XCTAssertEqual(valid["version"] as? String, "99.3-unknown-future")
            XCTAssertEqual(valid["validation"] as? String, "complete")
            let invalid = [
                ImportFixture.deb(architecture: "arm64"),
                ImportFixture.deb(package: "different"),
                ImportFixture.deb(payload: []),
                ImportFixture.deb(payload: [.init("usr/sbin/aksusbd_x86_64", data: ImportFixture.elf(), mode: 0o755)]),
                ImportFixture.deb(payload: [.init("usr/sbin/aksusbd_x86_64", data: Data("not ELF".utf8), mode: 0o755), .init("usr/sbin/hasplmd_x86_64", data: ImportFixture.elf(), mode: 0o755)]),
                ImportFixture.deb(payload: [.init("usr/sbin/aksusbd_x86_64", data: ImportFixture.elf(), mode: 0o644), .init("usr/sbin/hasplmd_x86_64", data: ImportFixture.elf(), mode: 0o755)]),
                ImportFixture.deb(payload: [.init("usr/sbin/aksusbd_x86_64", type: "2", link: "other"), .init("usr/sbin/hasplmd_x86_64", data: ImportFixture.elf(), mode: 0o755)]),
                ImportFixture.deb(dataArchive: Data("broken compressed payload".utf8))
            ]
            for bytes in invalid {
                try bytes.write(to: file)
                XCTAssertThrowsError(try ImportValidation.inspect(file, kind: "driver"))
            }
            try ImportFixture.deb().dropLast(12).write(to: file)
            XCTAssertThrowsError(try ImportValidation.inspect(file, kind: "driver"))
        }
    }
}

private enum ImportFixture {
    struct Member {
        let name: String
        let data: Data
        let mode: Int
        let type: String
        let link: String
        let declaredSize: Int?
        init(_ name: String, data: Data = Data(), mode: Int = 0o644, type: String = "0", link: String = "", declaredSize: Int? = nil) {
            self.name = name; self.data = data; self.mode = mode; self.type = type; self.link = link; self.declaredSize = declaredSize
        }
    }
    static func elf() -> Data {
        var data = Data(repeating: 0, count: 128)
        data.replaceSubrange(0..<7, with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1])
        data[16] = 2; data[18] = 62
        return data
    }
    static func tar(_ members: [Member]) -> Data {
        var archive = Data()
        for member in members {
            var header = Data(repeating: 0, count: 512)
            func set(_ offset: Int, _ length: Int, _ value: String) { header.replaceSubrange(offset..<(offset + min(length, value.utf8.count)), with: Array(value.utf8).prefix(length)) }
            func octal(_ offset: Int, _ length: Int, _ value: Int) { let text = String(value, radix: 8); set(offset, length, String(repeating: "0", count: max(0, length - text.count - 1)) + text + "\0") }
            set(0, 100, member.name); octal(100, 8, member.mode); octal(108, 8, 0); octal(116, 8, 0)
            octal(124, 12, member.declaredSize ?? member.data.count); octal(136, 12, 0)
            set(148, 8, "        "); set(156, 1, member.type); set(157, 100, member.link); set(257, 6, "ustar\0"); set(263, 2, "00")
            let sum = header.reduce(0) { $0 + Int($1) }; let checksum = String(sum, radix: 8)
            set(148, 8, String(repeating: "0", count: 6 - checksum.count) + checksum + "\0 ")
            archive.append(header); archive.append(member.data)
            archive.append(Data(repeating: 0, count: (512 - member.data.count % 512) % 512))
        }
        archive.append(Data(repeating: 0, count: 1024)); return archive
    }
    static func deb(package: String = "aksusbd", architecture: String = "amd64", payload: [Member]? = nil, dataArchive: Data? = nil) -> Data {
        let control = tar([.init("./control", data: Data("Package: \(package)\nArchitecture: \(architecture)\nVersion: 99.3-unknown-future\n".utf8))])
        let data = dataArchive ?? tar(payload ?? [.init("./usr/sbin/aksusbd_x86_64", data: elf(), mode: 0o755), .init("./usr/sbin/hasplmd_x86_64", data: elf(), mode: 0o755)])
        var result = Data("!<arch>\n".utf8)
        for (name, bytes) in [("debian-binary", Data("2.0\n".utf8)), ("control.tar", control), ("data.tar", data)] {
            func field(_ value: String, _ width: Int) -> String { value + String(repeating: " ", count: width - value.count) }
            let header = field(name + "/", 16) + field("0", 12) + field("0", 6) + field("0", 6) + field("100644", 8) + field(String(bytes.count), 10) + "`\n"
            result.append(Data(header.utf8)); result.append(bytes)
            if bytes.count % 2 != 0 { result.append(10) }
        }
        return result
    }
}
