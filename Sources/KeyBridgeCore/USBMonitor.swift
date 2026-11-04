// SPDX-License-Identifier: MIT
import Foundation
import Darwin

public struct USBConnection:Equatable {
    public let bus:Int
    public let address:Int
    public let epoch:String
    public var descriptor:[String:Any] { ["bus":bus,"address":address,"epoch":epoch] }
}

/// libusb arrival/departure notifications survive gaps between controller polls.
/// Each arrival creates a new epoch, even if the bus/address are reused.
public final class USBMonitor {
    typealias Callback = @convention(c)(OpaquePointer?,OpaquePointer?,Int32,UnsafeMutableRawPointer?)->Int32
    typealias Init = @convention(c)(UnsafeMutablePointer<OpaquePointer?>?)->Int32
    typealias Location = @convention(c)(OpaquePointer?)->UInt8
    typealias Register = @convention(c)(OpaquePointer?,Int32,Int32,Int32,Int32,Int32,Callback?,UnsafeMutableRawPointer?,UnsafeMutablePointer<Int32>?)->Int32
    typealias Events = @convention(c)(OpaquePointer?,UnsafeMutablePointer<timeval>?,UnsafeMutablePointer<Int32>?)->Int32
    private let lock=NSLock()
    private var connected=[String:USBConnection]()
    private var failure:String?
    private let library:UnsafeMutableRawPointer
    private var context:OpaquePointer?
    private let bus:Location
    private let address:Location
    private let changed:()->Void
    private let events:Events
    public init(resources:URL,changed:@escaping()->Void = {}) throws {
        self.changed=changed
        guard let library=dlopen(resources.appendingPathComponent("runtime/lib/libusb-1.0.0.dylib").path,RTLD_NOW|RTLD_LOCAL) else { throw BridgeError("Наблюдатель USB недоступен") }
        self.library=library
        func symbol<T>(_ name:String,_ type:T.Type)throws->T {
            guard let ptr=dlsym(library,name) else { throw BridgeError("USB API недоступен: "+name) }
            return unsafeBitCast(ptr,to:type)
        }
        let initialize=try symbol("libusb_init",Init.self)
        bus=try symbol("libusb_get_bus_number",Location.self)
        address=try symbol("libusb_get_device_address",Location.self)
        events=try symbol("libusb_handle_events_timeout_completed",Events.self)
        guard initialize(&context)==0 else { throw BridgeError("Нельзя наблюдать USB") }
        let register=try symbol("libusb_hotplug_register_callback",Register.self)
        var handle:Int32=0
        let result=register(context,3,1,0x0529,1,-1,{ _,device,event,user in
            guard let user else { return 0 }
            Unmanaged<USBMonitor>.fromOpaque(user).takeUnretainedValue().receive(device,event)
            return 0
        },Unmanaged.passUnretained(self).toOpaque(),&handle)
        guard result==0 else { throw BridgeError("События подключения USB недоступны: \(result)") }
        // Monitor has agent lifetime. The event loop holds it strongly so callback
        // user-data cannot outlive its owner.
        Thread.detachNewThread { [self] in
            while true {
                var timeout=timeval(tv_sec:0,tv_usec:100_000)
                let result=events(context,&timeout,nil)
                if result<0 && result != -10 {
                    lock.lock();failure="Потерян наблюдатель USB: \(result)";lock.unlock();changed();return
                }
            }
        }
    }
    private func receive(_ device:OpaquePointer?,_ event:Int32) {
        let b=Int(bus(device)),a=Int(address(device)),key="\(b):\(a)"
        lock.lock()
        if event==2 { connected.removeValue(forKey:key) }
        else if event==1 { connected[key]=USBConnection(bus:b,address:a,epoch:UUID().uuidString) }
        lock.unlock()
        changed()
    }
    public func snapshot() throws ->[USBConnection] {
        lock.lock();defer{lock.unlock()}
        if let failure { throw BridgeError(failure) }
        return Array(connected.values)
    }
}

struct USBTransfer {
    static func matches(_ tree:String,connection:USBConnection)->Bool {
        guard let range=tree.range(of:"dev: usb-host, id \"physical_hasp\"") else { return false }
        let tail=String(tree[range.upperBound...])
        let block=String(tail.components(separatedBy:"dev:").first ?? "")
        return block.range(of:"(?m)^\\s*hostbus = \(connection.bus) ",options:.regularExpression) != nil &&
               block.range(of:"(?m)^\\s*hostaddr = \(connection.address) ",options:.regularExpression) != nil &&
               block.contains("attached")
    }
}
