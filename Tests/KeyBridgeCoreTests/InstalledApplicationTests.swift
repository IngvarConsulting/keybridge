// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class InstalledApplicationTests: XCTestCase {
    func withFixture(_ body: (URL,URL) throws -> Void) throws {
        let base=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kb-installed-"+UUID().uuidString)
        let runtime=base.appendingPathComponent("runtime"),executables=base.appendingPathComponent("KeyBridge.app/Contents/MacOS")
        try BridgePaths.preparePrivateDirectory(runtime)
        try FileManager.default.createDirectory(at:executables,withIntermediateDirectories:true)
        let agent=executables.appendingPathComponent("KeyBridgeAgent")
        try Data("first-build".utf8).write(to:agent)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:agent.path)
        defer { try? FileManager.default.removeItem(at:base) }
        try body(runtime,executables)
    }
    func testFinderReplacementRejectsOldBuildWithoutCreatingOrDeletingData() throws {
        try withFixture { runtime,executables in
            let expected=try XCTUnwrap(AgentIdentity.fingerprint(executableDirectory:executables))
            let intent=try IntentStore(runtime:runtime);try intent.stop()
            let before=try Data(contentsOf:runtime.appendingPathComponent("intent.json"))
            try InstalledApplication.requireCurrentBuild(executableDirectory:executables,expectedBuild:expected)
            try Data("replacement-build".utf8).write(to:executables.appendingPathComponent("KeyBridgeAgent"))
            XCTAssertThrowsError(try InstalledApplication.requireCurrentBuild(executableDirectory:executables,expectedBuild:expected))
            XCTAssertEqual(try Data(contentsOf:runtime.appendingPathComponent("intent.json")),before)
        }
    }
    func testFinderTrashCannotRecreateDataFromLoadedOldController() throws {
        try withFixture { runtime,executables in
            let expected=try XCTUnwrap(AgentIdentity.fingerprint(executableDirectory:executables))
            try FileManager.default.removeItem(at:executables.deletingLastPathComponent().deletingLastPathComponent())
            try FileManager.default.removeItem(at:runtime)
            XCTAssertThrowsError(try InstalledApplication.requireCurrentBuild(executableDirectory:executables,expectedBuild:expected))
            XCTAssertFalse(FileManager.default.fileExists(atPath:runtime.path))
        }
    }
    func testControllerSeparatesExternalApplicationChangeFromRuntimeLoss() throws {
        try withFixture { runtime,executables in
            _=try IntentStore(runtime:runtime)
            let integrity=InstalledApplication.ControllerIntegrity(runtime:runtime,executableDirectory:executables)
            XCTAssertNil(integrity.problem)
            try Data("new-build".utf8).write(to:executables.appendingPathComponent("KeyBridgeAgent"))
            XCTAssertTrue(integrity.runtimeUnchanged);XCTAssertNotNil(integrity.problem)
            try FileManager.default.removeItem(at:runtime)
            try BridgePaths.preparePrivateDirectory(runtime)
            XCTAssertFalse(integrity.runtimeUnchanged)
            XCTAssertTrue(integrity.problem?.contains("Данные KeyBridge") == true)
        }
    }
    func testMissingDataOffersFirstPreparationOnlyWithFreshVMAbsence() throws {
        try withFixture { runtime,_ in
            try FileManager.default.removeItem(at:runtime)
            XCTAssertNoThrow(try InstalledApplication.validateRuntime(runtime,observation:{["ownership":"absent","running":false]}))
            for value: [String:Any] in [["ownership":"owned","running":true],["ownership":"unknown","running":false],[:]] {
                XCTAssertThrowsError(try InstalledApplication.validateRuntime(runtime,observation:{value}))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:runtime.path))
        }
    }
    func testCorruptSettingsAreNotTreatedAsFreshDataAndRemainUnchanged() throws {
        try withFixture { runtime,_ in
            let path=runtime.appendingPathComponent("intent.json"),bad=Data("broken".utf8)
            try bad.write(to:path)
            XCTAssertThrowsError(try InstalledApplication.validateRuntime(runtime,observation:{["ownership":"absent","running":false]}))
            XCTAssertEqual(try Data(contentsOf:path),bad)
        }
    }
    func testRetainedCurrentDataCanBeInspectedWhileOwnedVMIsRunning() throws {
        try withFixture { runtime,_ in
            let intent=try IntentStore(runtime:runtime);try intent.stop()
            try writeObject(["schema":1,"generation":UUID().uuidString],to:runtime.appendingPathComponent("current.json"))
            XCTAssertNoThrow(try InstalledApplication.validateRuntime(runtime,observation:{ XCTFail("Current data inspection must not claim the VM needs to be absent");return [:] }))
            XCTAssertTrue(intent.value.autoInhibit)
        }
    }
    func testSymbolicLinkCannotRedirectSettingsReadToAnotherFile() throws {
        try withFixture { runtime,_ in
            let target=runtime.deletingLastPathComponent().appendingPathComponent("external-intent")
            try JSONEncoder().encode(DesiredRuntime()).write(to:target)
            try FileManager.default.createSymbolicLink(at:runtime.appendingPathComponent("intent.json"),withDestinationURL:target)
            XCTAssertThrowsError(try InstalledApplication.validateRuntime(runtime,observation:{["ownership":"absent","running":false]}))
        }
    }
    func testUnreadableDirectoryCannotBeReportedAsMissingData() throws {
        try withFixture { runtime,_ in
            _=try IntentStore(runtime:runtime)
            try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:runtime.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:runtime.path) }
            XCTAssertThrowsError(try InstalledApplication.validateRuntime(runtime,observation:{ XCTFail("Missing data was not established");return ["ownership":"absent","running":false] }))
        }
    }
    func testCurrentPreparationBeforePointerCommitRemainsVisibleInsteadOfDataLoss() throws {
        try withFixture { runtime,executables in
            let path=executables.appendingPathComponent("KeyBridgeAgent")
            let identity=try XCTUnwrap(AgentIdentity.fingerprint(executableDirectory:executables))
            let busy:[String:Any]=["agentPID":23,"agentIdentity":identity,"busy":true,"operation":"prepare"]
            let confirmed=InstalledApplication.isCurrentPreparation(status:busy,pid:23,path:path,executableDirectory:executables)
            XCTAssertTrue(confirmed)
            XCTAssertNoThrow(try InstalledApplication.validateRuntime(runtime,observation:{["ownership":"owned","running":true]},activePreparation:{confirmed}))
            for changes: [String:Any] in [["busy":false],["operation":"probe"],["agentPID":24],["agentIdentity":"old-build"]] {
                let observation=busy.merging(changes){_,new in new}
                XCTAssertFalse(InstalledApplication.isCurrentPreparation(status:observation,pid:23,path:path,executableDirectory:executables))
            }
            XCTAssertFalse(InstalledApplication.isCurrentPreparation(status:busy,pid:23,path:URL(fileURLWithPath:"/other/KeyBridgeAgent"),executableDirectory:executables))
        }
    }
}
