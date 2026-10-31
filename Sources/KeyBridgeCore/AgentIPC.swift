// SPDX-License-Identifier: MIT
import Foundation
import Darwin

public enum AgentIPC {
    private static func address(_ runtime:URL) throws -> sockaddr_un {
        let bytes=Array(runtime.appendingPathComponent("control.sock").path.utf8)+[0]
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else { throw BridgeError("Путь IPC слишком длинный") }
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    private static func configure(_ fd:Int32) {
        var timeout=timeval(tv_sec:2,tv_usec:0)
        _=setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
        _=setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
        var one:Int32=1;_=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout.size(ofValue:one)))
    }
    private static func sendObject(_ fd:Int32,_ object:[String:Any]) throws {
        var data=try JSONSerialization.data(withJSONObject:object);data.append(10)
        try data.withUnsafeBytes { raw in
            var offset=0
            while offset<raw.count {
                let count=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                guard count>0 else { throw BridgeError("IPC: ответ не передан") };offset += count
            }
        }
    }
    private static func receive(_ fd:Int32) throws ->[String:Any] {
        var data=Data(),buffer=[UInt8](repeating:0,count:4096)
        while data.count<1024*1024 {
            let count=Darwin.read(fd,&buffer,buffer.count)
            guard count>0 else { throw BridgeError("IPC: ответ недоступен") }
            data.append(contentsOf:buffer.prefix(count))
            if data.contains(10) {
                guard let value=try JSONSerialization.jsonObject(with:data.prefix(while:{$0 != 10})) as? [String:Any] else { throw BridgeError("IPC: неизвестный ответ") };return value
            }
        }
        throw BridgeError("IPC: превышен размер сообщения")
    }
    public static func exchange(runtime:URL,message:[String:Any]) throws ->[String:Any] {
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else { throw BridgeError("IPC недоступен") };defer{Darwin.close(fd)}
        configure(fd);var target=try address(runtime)
        let result=withUnsafePointer(to:&target){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard result==0 else { throw BridgeError("Агент не отвечает по IPC") }
        try sendObject(fd,message);return try receive(fd)
    }
    public final class Server {
        private let fd:Int32
        private let path:URL
        private var thread:Thread?
        private let handler:([String:Any])->[String:Any]
        public init(runtime:URL,handler:@escaping([String:Any])->[String:Any]) throws {
            self.handler=handler;path=runtime.appendingPathComponent("control.sock")
            fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else { throw BridgeError("IPC socket не создан") }
            try? FileManager.default.removeItem(at:path)
            var target=try address(runtime)
            let result=withUnsafePointer(to:&target){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            guard result==0,listen(fd,16)==0 else { Darwin.close(fd);throw BridgeError("IPC socket не открыт") }
            chmod(path.path,0o600)
            thread=Thread { [weak self] in self?.serve() };thread?.start()
        }
        private func serve() {
            while !Thread.current.isCancelled {
                let client=accept(fd,nil,nil)
                if client<0 { break }
                configure(client)
                var uid:uid_t=0,gid:gid_t=0
                if getpeereid(client,&uid,&gid)==0,uid==getuid(),let message=try? receive(client) {
                    try? sendObject(client,handler(message))
                }
                Darwin.close(client)
            }
        }
        public func stop() { thread?.cancel();shutdown(fd,SHUT_RDWR);Darwin.close(fd) }
    }
}
