// SPDX-License-Identifier: MIT
import Foundation
import Darwin
import CryptoKit

/// Identity and mutation metadata, not a publisher signature. ctime prevents
/// restoring mtime from reviving a cached result after an in-place edit.
struct FileRevision: Equatable, Sendable {
    private let value:String
    init?(_ url:URL) {
        var s=stat()
        guard lstat(url.path,&s)==0,(s.st_mode&S_IFMT)==S_IFREG else { return nil }
        value="\(s.st_dev):\(s.st_ino):\(s.st_uid):\(s.st_gid):\(s.st_mode):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
    }
}

final class FileDigestCache {
    private let lock=NSLock()
    private var entries=[URL:(FileRevision,String)]()
    func digest(_ path:URL,read:(URL)throws->Data = {try Data(contentsOf:$0)})->String? {
        lock.lock();defer { lock.unlock() }
        guard let before=FileRevision(path) else { entries.removeValue(forKey:path);return nil }
        if let entry=entries[path],entry.0==before { return entry.1 }
        guard let data=try?read(path),FileRevision(path)==before else {entries.removeValue(forKey:path);return nil}
        let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        if entries.count>=64 { entries.removeAll() }
        entries[path]=(before,digest)
        return digest
    }
}
