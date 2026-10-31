// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class ConfigurationBackupMetadataTests:XCTestCase {
    func testMalformedExistenceCannotAuthorizeDeletingCurrentConfiguration() throws {
        let digest="expected",target="/opt/1cv8/9.1/conf/nethasp.ini"
        var metadata:[String:Any]=["installedSHA256":digest,"target":target]
        XCTAssertThrowsError(try ConfigurationBackupMetadata(metadata,expectedDigest:digest,target:target))
        for corrupt:Any in [NSNull(),0,1,"false","true",[String:Any]()] {
            metadata["existed"]=corrupt
            XCTAssertThrowsError(try ConfigurationBackupMetadata(metadata,expectedDigest:digest,target:target))
        }
        metadata["existed"]=false
        XCTAssertFalse(try ConfigurationBackupMetadata(metadata,expectedDigest:digest,target:target).existed)
        metadata["existed"]=true
        XCTAssertTrue(try ConfigurationBackupMetadata(metadata,expectedDigest:digest,target:target).existed)
    }
    func testOtherTargetAndEscapingOriginalNeverAuthorizeRestore() throws {
        let digest="expected",target="/opt/1cv8/9.1/conf/nethasp.ini"
        let valid:[String:Any]=["installedSHA256":digest,"target":target,"existed":true]
        for patch:[String:Any] in [["target":"/other"],["installedSHA256":"unknown"],["originalFile":"../elsewhere"],["originalFile":false]] {
            var bad=valid;bad.merge(patch){_,new in new}
            XCTAssertThrowsError(try ConfigurationBackupMetadata(bad,expectedDigest:digest,target:target))
        }
        var generated=valid;let name="original-"+UUID().uuidString+".ini";generated["originalFile"]=name
        XCTAssertEqual(try ConfigurationBackupMetadata(generated,expectedDigest:digest,target:target).originalFile,name)
        XCTAssertEqual(try ConfigurationBackupMetadata(["installedSHA256":digest,"existed":true],expectedDigest:digest,target:target).originalFile,"original.ini")
    }
}
