// SPDX-License-Identifier: MIT
import Foundation

/// Selection and installation share the same private, resolved file. A successful
/// preflight establishes compatibility; the candidate VM still verifies the actual
/// installed programs before publishing a new installation.
public enum ImportInspection {
    public static func inspect(_ candidate: ImportCandidate, kind: String, resources: URL,
                               workspace: URL, cancelled: @escaping () -> Bool = { false }) throws -> [String: Any] {
        if cancelled() { throw CancellationError() }
        var result = try ImportValidation.inspect(candidate.file, kind: kind, cancelled: cancelled)
        if kind == "installer" {
            result = try InstallerPreflight.inspect(candidate.file, resources: resources,
                                                    workspace: workspace, cancelled: cancelled)
        }
        if cancelled() { throw CancellationError() }
        guard result["valid"] as? Bool == true else {
            throw BridgeError("Пригодность файла не подтверждена. Выберите другой файл и повторите проверку.")
        }
        result["kind"] = kind
        result["name"] = candidate.displayName
        result["resolvedPath"] = candidate.file.path
        return result
    }
}
