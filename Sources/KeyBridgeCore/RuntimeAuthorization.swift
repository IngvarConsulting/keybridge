// SPDX-License-Identifier: MIT
import Foundation
import Darwin

public final class RunAuthorization {
    private let lock=NSLock();private var enabled=false
    public init() {}
    public var allowed:Bool { lock.lock();defer{lock.unlock()};return enabled }
    public func set(_ value:Bool) { lock.lock();defer{lock.unlock()};enabled=value }
}

public enum LoginSessionIdentity {
    public static func current()->String? {
        guard let identity=try?ProcessIdentity.capture(getpid()) else { return nil }
        var size=0
        guard sysctlbyname("kern.bootsessionuuid",nil,&size,nil,0)==0,size>1,size<1024 else { return nil }
        var bytes=[CChar](repeating:0,count:size)
        guard sysctlbyname("kern.bootsessionuuid",&bytes,&size,nil,0)==0 else { return nil }
        return String(cString:bytes)+":"+String(identity.audit[6])
    }
}
