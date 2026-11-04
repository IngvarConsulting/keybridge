// SPDX-License-Identifier: MIT
import Foundation

public enum LicenseEvidence {
    /// A receipt is produced inside the probing client, while its license is
    /// still held. Manager totals and timestamps are deliberately not evidence.
    public static func confirmsHardwareSource(receipt: [String: Any], database: URL, processID: Int32) -> Bool {
        guard processID > 0,
              receipt["source"] as? String == "platform-license-monitoring",
              receipt["completed"] as? Bool == true,
              let connection = receipt["connectionString"] as? String,
              matchesPrivateDatabase(connection, database: database),
              let licenses = receipt["licenses"] as? [[String: Any]] else { return false }
        return licenses.contains { license in
            guard license["hardware"] as? Bool == true,
                  license["processID"] as? String == String(processID),
                  license["managerAddress"] as? String == "127.0.0.1",
                  license["managerPort"] as? Int == 15441,
                  let managerID = license["managerID"] as? String, !managerID.isEmpty,
                  let recipient = license["connectionString"] as? String else { return false }
            return matchesPrivateDatabase(recipient, database: database)
        }
    }

    private static func matchesPrivateDatabase(_ connection: String, database: URL) -> Bool {
        // Only a file-base connection is accepted. A server address, another
        // base, or a path merely occurring inside a different value cannot match.
        let pattern = #"^\s*File\s*=\s*"((?:[^"]|"")*)"\s*;?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: connection, range: NSRange(connection.startIndex..., in: connection)),
              let range = Range(match.range(at: 1), in: connection) else { return false }
        let path = String(connection[range]).replacingOccurrences(of: "\"\"", with: "\"")
        guard path.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            == database.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Creating the private base is part of the probe. Its failure must remain
    /// an observed result, rather than being replaced by an old-proof warning.
    public static func creationFailure(exitCode: Int32, timedOut: Bool, context: [String: Any]) -> [String: Any]? {
        guard timedOut || exitCode != 0 else { return nil }
        return ["success": false, "result": probeOutcome(clientSucceeded: false, timedOut: timedOut),
                "stage": "create", "timedOut": timedOut, "exitCode": exitCode,
                "clientOperationSucceeded": false, "contextAfter": context,
                "timestamp": Date().timeIntervalSince1970,
                "message": timedOut ? "1С не завершила создание проверочной базы за время ожидания." : "1С завершилась с ошибкой при создании проверочной базы."]
    }

    /// Aggregate license counters cannot establish whether this client failed.
    /// A completed client operation stays unconfirmed until its source is known.
    public static func probeOutcome(clientSucceeded: Bool, timedOut: Bool) -> String {
        if timedOut { return "timeout" }
        return clientSucceeded ? "unconfirmed" : "failure"
    }

    public static func continuous(before:[String:Any],after:[String:Any])->Bool {
        guard before["available"] as? Bool == true,after["available"] as? Bool == true,
              let initial=before["sources"] as? [[String:Any]],!initial.isEmpty,
              let final=after["sources"] as? [[String:Any]] else { return false }
        for file in initial {
            guard let name=file["name"] as? String,let size=file["bytes"] as? Int,
                  let digest=file["digest"] as? String,!digest.isEmpty,
                  let inode=file["inode"] as? UInt64,
                  let next=final.first(where:{$0["name"] as? String==name}),
                  next["inode"] as? UInt64 == inode,
                  (next["bytes"] as? Int ?? -1)>=size,
                  next["baselineDigest"] as? String == digest else { return false }
        }
        return true
    }
}
