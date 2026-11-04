// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class FileRevisionTests:XCTestCase {
    func testUnchangedDigestReadsOnceAndDetectsSameSizeEditWithRestoredMtime() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try?FileManager.default.removeItem(at:file)}
        try Data("first".utf8).write(to:file)
        let mtime=try XCTUnwrap(FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate] as? Date)
        let cache=FileDigestCache();var reads=0
        func read(_ url:URL)throws->Data {reads+=1;return try Data(contentsOf:url)}
        let first=cache.digest(file,read:read)
        XCTAssertNotNil(first);XCTAssertEqual(cache.digest(file,read:read),first);XCTAssertEqual(reads,1)
        let handle=try FileHandle(forWritingTo:file)
        try handle.write(contentsOf:Data("other".utf8));try handle.close()
        try FileManager.default.setAttributes([.modificationDate:mtime],ofItemAtPath:file.path)
        XCTAssertNotEqual(cache.digest(file,read:read),first);XCTAssertEqual(reads,2)
        try FileManager.default.removeItem(at:file)
        XCTAssertNil(cache.digest(file,read:read))
    }
    func testAtomicReplacementSymlinkAndMutationDuringReadAreNotTrusted() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try?FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("file"),link=folder.appendingPathComponent("link")
        try Data("before".utf8).write(to:file)
        let cache=FileDigestCache(),first=cache.digest(file)
        try Data("after!".utf8).write(to:file,options:.atomic)
        XCTAssertNotEqual(cache.digest(file),first)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertNil(cache.digest(link))
        let other=FileDigestCache()
        XCTAssertNil(other.digest(file,read:{url in
            let data=try Data(contentsOf:url)
            try Data("racing".utf8).write(to:url,options:.atomic)
            return data
        }))
    }
}
