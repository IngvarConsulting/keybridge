// SPDX-License-Identifier: MIT
import Foundation
import CoreFoundation
import CryptoKit

/// Only a target-bound record with a digest can authorize restoration.
public struct ConfigurationBackupMetadata {
    public let existed: Bool
    public let originalFile: String
    public let originalSHA256: String
    public static func digest(_ data:Data)->String {
        SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    }
    public init(_ object:[String:Any], expectedDigest:String, target:String) throws {
        guard object["schemaVersion"] as? Int == 1,
              let flag=object["existed"] as?NSNumber,CFGetTypeID(flag)==CFBooleanGetTypeID(),
              object["installedSHA256"] as?String==expectedDigest,
              let digest=object["originalSHA256"] as? String,digest.count==64,
              digest.allSatisfy({"0123456789abcdef".contains($0)}) else {
            throw BridgeError("Копия настроек не имеет достоверной контрольной суммы или повреждена. Текущие настройки не изменены.")
        }
        guard object["target"] as?String==target else {
            throw BridgeError("Копия относится к другой или неизвестной установке 1С. Текущие настройки не изменены.")
        }
        guard let name=object["originalFile"] as?String,
              name=="original.ini" || (name.hasPrefix("original-") && name.hasSuffix(".ini") && UUID(uuidString:String(name.dropFirst(9).dropLast(4))) != nil) else {
            throw BridgeError("Указатель резервной копии повреждён. Текущие настройки не изменены.")
        }
        existed=flag.boolValue;originalFile=name;originalSHA256=digest
    }
    public func verifyOriginal(_ data:Data?) throws {
        guard (data != nil)==existed,Self.digest(data ?? Data())==originalSHA256 else {
            throw BridgeError("Содержимое резервной копии повреждено. Текущие настройки не изменены.")
        }
    }
}
