// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class ConfigurationBackupMetadataTests:XCTestCase {
    let target="/opt/1cv8/9.1/conf/nethasp.ini"
    let digest=ConfigurationBackupMetadata.digest(Data("managed".utf8))
    var valid:[String:Any] {["schemaVersion":1,"installedSHA256":digest,"target":target,"existed":true,
        "originalFile":"original.ini","originalSHA256":ConfigurationBackupMetadata.digest(Data("original".utf8))]}
    func testMalformedExistenceCannotAuthorizeDeletingCurrentConfiguration() throws {
        for corrupt:Any in [NSNull(),0,1,"false","true",[String:Any]()] {
            var metadata=valid;metadata["existed"]=corrupt
            XCTAssertThrowsError(try ConfigurationBackupMetadata(metadata,expectedDigest:digest,target:target))
        }
        var metadata=valid;metadata["existed"]=false;metadata["originalSHA256"]=ConfigurationBackupMetadata.digest(Data())
        let record=try ConfigurationBackupMetadata(metadata,expectedDigest:digest,target:target)
        XCTAssertFalse(record.existed)
        XCTAssertNoThrow(try record.verifyOriginal(nil))
        XCTAssertThrowsError(try record.verifyOriginal(Data()))
    }
    func testOtherTargetEscapingOriginalAndLegacyNeverAuthorizeRestore() throws {
        for patch:[String:Any] in [["target":"/other"],["installedSHA256":"unknown"],["originalFile":"../elsewhere"],["originalFile":false],["originalSHA256":"bad"]] {
            var bad=valid;bad.merge(patch){_,new in new}
            XCTAssertThrowsError(try ConfigurationBackupMetadata(bad,expectedDigest:digest,target:target))
        }
        for field in ["target","schemaVersion","originalSHA256","originalFile"] {
            var legacy=valid;legacy.removeValue(forKey:field)
            XCTAssertThrowsError(try ConfigurationBackupMetadata(legacy,expectedDigest:digest,target:target))
        }
        var generated=valid;let name="original-"+UUID().uuidString+".ini";generated["originalFile"]=name
        XCTAssertEqual(try ConfigurationBackupMetadata(generated,expectedDigest:digest,target:target).originalFile,name)
    }
    func testOriginalDigestDetectsChangedAndMissingBytes() throws {
        let record=try ConfigurationBackupMetadata(valid,expectedDigest:digest,target:target)
        XCTAssertNoThrow(try record.verifyOriginal(Data("original".utf8)))
        XCTAssertThrowsError(try record.verifyOriginal(Data("damaged".utf8)))
        XCTAssertThrowsError(try record.verifyOriginal(nil))
    }
}
