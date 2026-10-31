// SPDX-License-Identifier: MIT
import Foundation

public enum LicenseEvidence {
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
