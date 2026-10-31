// SPDX-License-Identifier: MIT
import Foundation
import Darwin

public enum RuntimeResources {
    public static func bytes(_ path:URL)->[String:Any] {
        var logical:Int64=0,allocated:Int64=0,complete=true
        func count(_ url:URL) {
            var info=stat()
            guard lstat(url.path,&info)==0 else { complete=false;return }
            if (info.st_mode&S_IFMT)==S_IFREG { logical += info.st_size;allocated += Int64(info.st_blocks)*512 }
        }
        var info=stat()
        if lstat(path.path,&info) != 0 { return ["logicalBytes":0,"allocatedBytes":0,"available":false] }
        if (info.st_mode&S_IFMT)==S_IFDIR {
            if let tree=FileManager.default.enumerator(at:path,includingPropertiesForKeys:nil,options:[],errorHandler:{_,_ in complete=false;return true}) {
                for case let url as URL in tree { count(url) }
            } else { complete=false }
        } else { count(path) }
        return ["logicalBytes":logical,"allocatedBytes":allocated,"available":complete]
    }
    public static func virtualSize(_ image:URL) throws ->Int64 {
        let file=try FileHandle(forReadingFrom:image);defer{try?file.close()}
        guard let data=try file.read(upToCount:32),data.count==32,Array(data[0..<4])==[0x51,0x46,0x49,0xfb],
              data[4]==0,data[5]==0,data[6]==0,[UInt8(2),3].contains(data[7]) else {throw BridgeError("Формат диска не подтверждён")}
        let value=data[24..<32].reduce(UInt64(0)){($0<<8)|UInt64($1)}
        guard value>0,value<=UInt64(Int64.max/4) else {throw BridgeError("Размер диска не подтверждён")}
        return Int64(value)
    }
    public static func availableBytes(_ path:URL) throws ->Int64 {
        var ancestor=path
        while !FileManager.default.fileExists(atPath:ancestor.path),ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        var fs=statfs()
        guard statfs(ancestor.path,&fs)==0 else { throw BridgeError("Свободное место на Mac неизвестно.") }
        return Int64(fs.f_bavail)*Int64(fs.f_bsize)
    }
    public static func preparationSpace(runtime:URL,resources:URL,installer:URL?,driver:URL?) throws ->[String:Any] {
        let available=try availableBytes(runtime)
        guard let installer,let driver else {return ["availableBytes":available]}
        let virtual=try virtualSize(resources.appendingPathComponent("base/alpine.qcow2"))
        let inputs=try [installer,driver].reduce(Int64(0)) { total,url in
            let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
            guard values.isRegularFile==true,let size=values.fileSize else {throw BridgeError("Не удалось прочитать размер установщика.")}
            return total+Int64(size)
        }
        let estimated=inputs*2+virtual*2+virtual/100
        return ["estimatedPeakBytes":estimated,"availableBytes":available,"inputBytes":inputs,"virtualDiskBytes":virtual,"sufficient":available>=estimated]
    }

    public static func disk(runtime:URL,resources:URL)->[String:Any] {
        let store=GenerationStore(runtime:runtime)
        let selected=readObject(runtime.appendingPathComponent("current.json"))["generation"] as? String
        let previous=readObject(runtime.appendingPathComponent("previous.json"))["generation"] as? String
        let published=Set(store.records().compactMap{$0["generation"] as? String})
        let folder=runtime.appendingPathComponent("generations")
        let generations=((try?FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).map { url ->[String:Any] in
            var result=bytes(url);result["generation"]=url.lastPathComponent
            result["role"]=url.lastPathComponent==selected ? "selected" : (url.lastPathComponent==previous ? "previous" : (published.contains(url.lastPathComponent) ? "retained":"candidate"))
            return result
        }
        var result:[String:Any]=["base":bytes(resources.appendingPathComponent("base")),"generations":generations,"runtime":bytes(runtime)]
        if let selected,let virtual=try?virtualSize(runtime.appendingPathComponent("generations/"+selected+"/guest.qcow2")) {result["virtualDiskBytes"]=virtual}
        if let available=try?availableBytes(runtime) { result["availableBytes"]=available }
        return result
    }
}
