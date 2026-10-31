// SPDX-License-Identifier: MIT
import Foundation
import CoreFoundation

/// A malformed backup must never be interpreted as "the original did not exist".
/// Validation precedes target writes and deletion in the privileged helper.
public struct ConfigurationBackupMetadata {
    public let existed: Bool
    public let originalFile: String
    public init(_ object:[String:Any], expectedDigest:String, target:String) throws {
        guard let flag=object["existed"] as?NSNumber,CFGetTypeID(flag)==CFBooleanGetTypeID(),
              object["installedSHA256"] as?String==expectedDigest else {
            throw BridgeError("Копия настроек повреждена или имеет неизвестный формат. Текущие настройки не изменены.")
        }
        if let recordedTarget=object["target"] {
            guard recordedTarget as?String==target else {throw BridgeError("Копия относится к другой установке 1С. Текущие настройки не изменены.")}
        }
        let name:String
        if let value=object["originalFile"] {
            guard let value=value as?String else {throw BridgeError("Указатель резервной копии повреждён.")};name=value
        } else {name="original.ini"} // The original pilot's record format.
        guard name=="original.ini" || (name.hasPrefix("original-") && name.hasSuffix(".ini") && UUID(uuidString:String(name.dropFirst(9).dropLast(4))) != nil) else {
            throw BridgeError("Указатель резервной копии повреждён. Текущие настройки не изменены.")
        }
        existed=flag.boolValue;originalFile=name
    }
}
