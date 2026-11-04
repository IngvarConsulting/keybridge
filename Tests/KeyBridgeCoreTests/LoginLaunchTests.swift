// SPDX-License-Identifier: MIT
import XCTest
import CoreServices
import ServiceManagement
@testable import KeyBridgeCore

final class LoginLaunchTests: XCTestCase {
    func testNeverRegisteredValidApplicationIsOffRatherThanAnObservationFailure() {
        XCTAssertEqual(LoginLaunch.interpret(.notFound, validApplication: true), .unregistered)
        XCTAssertEqual(LoginLaunch.interpret(.notFound, validApplication: false), .unavailable)
        XCTAssertEqual(LoginLaunch.interpret(.notRegistered, validApplication: true).access, "unregistered")
    }

    func testRegistrationFailureDoesNotSaveEnabledChoice() {
        var saved = false
        XCTAssertThrowsError(try LoginLaunch.change(true, status: { .unregistered },
            register: { throw BridgeError("Registration refused") }, unregister: { XCTFail("Nothing was registered") },
            persist: { saved = $0 }))
        XCTAssertFalse(saved)
    }

    func testSuccessfulCallWithoutRegisteredStateIsNotSuccess() {
        var saved = false
        XCTAssertThrowsError(try LoginLaunch.change(true, status: { .unregistered }, register: {}, unregister: {}, persist: { saved = $0 }))
        XCTAssertFalse(saved)
    }

    func testNewRegistrationIsRolledBackIfSavingFails() {
        var state: LoginLaunch.Status = .unregistered
        XCTAssertThrowsError(try LoginLaunch.change(true, status: { state }, register: { state = .enabled },
            unregister: { state = .unregistered }, persist: { _ in throw BridgeError("Disk full") }))
        XCTAssertEqual(state, .unregistered)
    }

    func testExistingRegistrationIsPreservedIfSavingFails() {
        XCTAssertThrowsError(try LoginLaunch.change(true, status: { .enabled },
            register: { XCTFail("Already registered") }, unregister: { XCTFail("Must retain existing registration") },
            persist: { _ in throw BridgeError("Disk full") }))
    }

    func testDisabledRegistrationIsRestoredIfSavingFails() {
        var state: LoginLaunch.Status = .enabled
        var sequence = [String]()
        XCTAssertThrowsError(try LoginLaunch.change(false, status: { state }, register: {
            sequence.append("register"); state = .enabled
        }, unregister: {
            sequence.append("unregister"); state = .unregistered
        }, persist: { _ in
            sequence.append("persist"); throw BridgeError("Disk full")
        })) { error in
            XCTAssertEqual(error.localizedDescription, "Disk full")
        }
        XCTAssertEqual(state, .enabled)
        XCTAssertEqual(sequence, ["unregister", "persist", "register"])
    }

    func testRollbackOfEnablingMustBeObservedRatherThanAssumedFromSuccessfulCall() {
        for rollbackState: LoginLaunch.Status in [.enabled, .unavailable] {
            var state: LoginLaunch.Status = .unregistered
            XCTAssertThrowsError(try LoginLaunch.change(true, status: { state }, register: { state = .enabled },
                unregister: { state = rollbackState }, persist: { _ in throw BridgeError("Disk full") })) { error in
                XCTAssertTrue(error.localizedDescription.contains("отмена автозапуска не подтверждена"))
            }
        }
    }

    func testRollbackOfDisablingMustBeObservedRatherThanAssumedFromSuccessfulCall() {
        for rollbackState: LoginLaunch.Status in [.unregistered, .unavailable] {
            var state: LoginLaunch.Status = .enabled
            XCTAssertThrowsError(try LoginLaunch.change(false, status: { state }, register: { state = rollbackState },
                unregister: { state = .unregistered }, persist: { _ in throw BridgeError("Disk full") })) { error in
                XCTAssertTrue(error.localizedDescription.contains("прежний автозапуск не восстановлен"))
            }
        }
    }

    func testRollbackFailureReportsBothUnsavedChoiceAndUnrestoredRegistration() {
        var state: LoginLaunch.Status = .enabled
        XCTAssertThrowsError(try LoginLaunch.change(false, status: { state },
            register: { throw BridgeError("Registration refused") }, unregister: { state = .unregistered },
            persist: { _ in throw BridgeError("Disk full") })) { error in
            XCTAssertTrue(error.localizedDescription.contains("Настройка не сохранилась"))
            XCTAssertTrue(error.localizedDescription.contains("прежний автозапуск не восстановлен"))
        }
    }

    func testApprovalRequiredSavesRequestWithoutClaimingPermission() throws {
        var state: LoginLaunch.Status = .unregistered
        var saved = false
        try LoginLaunch.change(true, status: { state }, register: { state = .requiresApproval }, unregister: {}, persist: { saved = $0 })
        XCTAssertTrue(saved)
        XCTAssertTrue(state.isRegistered)
        XCTAssertEqual(state.access, "denied")
    }

    func testDisableUnregistersBeforeSavingAndDoesNotChangeRunningIntent() throws {
        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("KeyBridgeLoginTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: runtime) }
        let intent = try IntentStore(runtime: runtime)
        try intent.start()
        try intent.setAutostart(true, supported: true)
        var state: LoginLaunch.Status = .enabled
        try LoginLaunch.change(false, status: { state }, register: { XCTFail("Disable must not register") },
            unregister: { state = .unregistered }, persist: {
                XCTAssertEqual(state, .unregistered)
                try intent.setAutostart($0, supported: true)
            })
        XCTAssertFalse(intent.value.autostart)
        XCTAssertTrue(intent.value.want)
        XCTAssertFalse(intent.value.autoInhibit)
        XCTAssertEqual(state.access, "unregistered")
    }

    func testUnregisterFailureDoesNotSaveDisabledChoice() {
        var saved = true
        XCTAssertThrowsError(try LoginLaunch.change(false, status: { .enabled }, register: {},
            unregister: { throw BridgeError("Refused") }, persist: { saved = $0 }))
        XCTAssertTrue(saved)
    }

    func testLoginEventIsDistinctFromManualLaunchAndOtherEvents() {
        XCTAssertFalse(LoginLaunch.isLoginEvent(nil))
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(LoginLaunch.isLoginEvent(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(LoginLaunch.isLoginEvent(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
        XCTAssertFalse(LoginLaunch.isLoginEvent(event))
    }

    func testSessionTerminationRecognizesOnlySystemLogoutShutdownAndRestartQuitReasons() {
        XCTAssertFalse(LoginLaunch.isSessionTerminationEvent(nil))
        let quit = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEQuitApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(LoginLaunch.isSessionTerminationEvent(quit), "Manual Quit has no system termination reason")
        for reason in [kAELogOut, kAEReallyLogOut, kAEShutDown, kAERestart] {
            quit.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: kAEQuitReason)
            XCTAssertTrue(LoginLaunch.isSessionTerminationEvent(quit))
        }
        quit.setParam(NSAppleEventDescriptor(enumCode: kAEQuitAll), forKeyword: kAEQuitReason)
        XCTAssertFalse(LoginLaunch.isSessionTerminationEvent(quit), "Quit all applications alone does not establish a login-session end")
        let other = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        other.setParam(NSAppleEventDescriptor(enumCode: kAEShutDown), forKeyword: kAEQuitReason)
        XCTAssertFalse(LoginLaunch.isSessionTerminationEvent(other))
    }

    func testSessionQuitReasonSupportsAttributesAndPrefersAttributeOverParameter() {
        let quit = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEQuitApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(LoginLaunch.isSessionTerminationEvent(quit))
        for reason in [kAELogOut, kAEReallyLogOut, kAEShutDown, kAERestart] {
            quit.setAttribute(NSAppleEventDescriptor(enumCode: reason), forKeyword: kAEQuitReason)
            XCTAssertTrue(LoginLaunch.isSessionTerminationEvent(quit))
        }
        quit.setParam(NSAppleEventDescriptor(enumCode: kAEQuitAll), forKeyword: kAEQuitReason)
        XCTAssertTrue(LoginLaunch.isSessionTerminationEvent(quit), "System attribute takes precedence over conflicting parameter")
        quit.setAttribute(NSAppleEventDescriptor(enumCode: kAEQuitAll), forKeyword: kAEQuitReason)
        quit.setParam(NSAppleEventDescriptor(enumCode: kAERestart), forKeyword: kAEQuitReason)
        XCTAssertFalse(LoginLaunch.isSessionTerminationEvent(quit), "Parameter cannot override a non-session attribute")
    }
}
