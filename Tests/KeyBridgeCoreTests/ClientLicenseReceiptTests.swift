// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class ClientLicenseReceiptTests: XCTestCase {
    private let database = URL(fileURLWithPath: "/tmp/keybridge-unique-probe/ib")
    private let processID: Int32 = 321

    private func receipt() -> [String: Any] {
        let connection = "File=\"\(database.path)\";"
        return ["source": "platform-license-monitoring", "completed": true,
                "connectionString": connection,
                "licenses": [["connectionString": connection, "processID": "321",
                    "hardware": true, "managerAddress": "127.0.0.1", "managerPort": 15441,
                    "managerID": "fixture-manager-instance"]]]
    }

    func testCurrentClientHardwareReceiptDoesNotRequireNewIssuance() {
        // Monitoring observes held licenses, including a computer license reused
        // by this client. There are no aggregate counters in this receipt.
        XCTAssertTrue(LicenseEvidence.confirmsHardwareSource(receipt: receipt(), database: database, processID: processID))
    }

    func testDatabaseCreatedAfterItsURLWasConstructedMatchesReceipt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = folder.appendingPathComponent("ib")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var value = receipt()
        let connection = "File=\"\(database.path)\";"
        value["connectionString"] = connection
        var license = (value["licenses"] as! [[String: Any]])[0]
        license["connectionString"] = connection
        value["licenses"] = [license]
        XCTAssertTrue(LicenseEvidence.confirmsHardwareSource(receipt: value, database: database, processID: processID))
    }

    func testDifferentRecipientSourceOrManagerCannotConfirm() {
        let patches: [[String: Any]] = [
            ["processID": "320"], // A prior DESIGNER process in the same private base.
            ["processID": "0"],
            ["hardware": false],
            ["connectionString": "File=\"/tmp/another-probe/ib\";"],
            ["connectionString": "Srvr=\"127.0.0.1\";Ref=\"\(database.path)\";"],
            ["connectionString": "File=\"\(database.path)-suffix\";"],
            ["managerAddress": "192.0.2.5"],
            ["managerPort": 1544],
            ["managerID": ""]
        ]
        for patch in patches {
            var value = receipt()
            var license = (value["licenses"] as! [[String: Any]])[0]
            license.merge(patch) { _, new in new }
            value["licenses"] = [license]
            XCTAssertFalse(LicenseEvidence.confirmsHardwareSource(receipt: value, database: database, processID: processID), "\(patch)")
        }
    }

    func testMissingPartialAndForeignReceiptsRemainUnconfirmed() {
        for patch: [String: Any] in [
            ["completed": false], ["source": "manager-counters"], ["licenses": []],
            ["connectionString": "File=\"/tmp/another-probe/ib\";"],
            ["connectionString": "File=\"\(database.path)\";File=\"/tmp/another\";"],
            ["connectionString": "File=\"\(database.path)\";Srvr=\"server\";"]
        ] {
            var value = receipt(); value.merge(patch) { _, new in new }
            XCTAssertFalse(LicenseEvidence.confirmsHardwareSource(receipt: value, database: database, processID: processID))
        }
        XCTAssertFalse(LicenseEvidence.confirmsHardwareSource(receipt: [:], database: database, processID: processID))
        XCTAssertFalse(LicenseEvidence.confirmsHardwareSource(receipt: receipt(), database: database, processID: 0))
    }

    func testReceiptRoundTripsThroughJSONAndQuotedFilePath() throws {
        var value = receipt()
        let quoted = URL(fileURLWithPath: "/tmp/KeyBridge \"probe\"/ib")
        let connection = "File=\"/tmp/KeyBridge \"\"probe\"\"/ib\";"
        value["connectionString"] = connection
        var license = (value["licenses"] as! [[String: Any]])[0]
        license["connectionString"] = connection
        value["licenses"] = [license]
        let data = try JSONSerialization.data(withJSONObject: value)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(LicenseEvidence.confirmsHardwareSource(receipt: decoded, database: quoted, processID: processID))
    }
}
