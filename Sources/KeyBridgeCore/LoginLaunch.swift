// SPDX-License-Identifier: MIT
import Foundation
import CoreServices
import ServiceManagement

/// The login item is the application, not the process which owns the USB key.
/// Unregistering the application does not terminate an already running service.
public enum LoginLaunch {
    public enum Status: Equatable {
        case unregistered, enabled, requiresApproval, unavailable
        public var isRegistered: Bool { self == .enabled || self == .requiresApproval }
        public var access: String {
            switch self {
            case .enabled: return "allowed"
            case .requiresApproval: return "denied"
            case .unregistered: return "unregistered"
            case .unavailable: return "unknown"
            }
        }
    }

    public static var status: Status {
        let bundle = Bundle.main
        let validApplication = bundle.bundleURL.pathExtension == "app" &&
            bundle.executableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true
        return interpret(SMAppService.mainApp.status, validApplication: validApplication)
    }

    static func interpret(_ status: SMAppService.Status, validApplication: Bool) -> Status {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .unregistered
        // A valid app with no previous login-item record reports notFound.
        case .notFound: return validApplication ? .unregistered : .unavailable
        @unknown default: return .unavailable
        }
    }
    public static var isRegistered: Bool { status.isRegistered }
    public static var access: String { status.access }

    public static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    public static func isSessionTerminationEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventClass == kCoreEventClass, event?.eventID == kAEQuitApplication,
              let reason = (event?.attributeDescriptor(forKeyword: kAEQuitReason)
                            ?? event?.paramDescriptor(forKeyword: kAEQuitReason))?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShutDown, kAERestart].contains(reason)
    }

    public static func setEnabled(_ enabled: Bool, intent: IntentStore,
                                  publish: (() throws -> Void) throws -> Void = { try $0() }) throws {
        try ApplicationCapabilities.requireLoginLaunch(enabled)
        try change(enabled, status: { status }, register: { try SMAppService.mainApp.register() },
                   unregister: { try SMAppService.mainApp.unregister() },
                   persist: { value in try publish { try intent.setAutostart(value) } })
    }

    /// Keep the user's saved choice unchanged when registration fails. Restore
    /// the previous registration after a failed save and verify that rollback.
    static func change(_ enabled: Bool, status: () -> Status,
                       register: () throws -> Void, unregister: () throws -> Void,
                       persist: (Bool) throws -> Void) throws {
        let before = status()
        if enabled {
            if !before.isRegistered { try register() }
            guard status().isRegistered else {
                throw BridgeError("macOS не подтвердила автозапуск. Откройте настройки входа в систему и проверьте разрешение для KeyBridge.")
            }
        } else if before.isRegistered {
            try unregister()
            guard status() == .unregistered else {
                throw BridgeError("macOS не подтвердила выключение автозапуска. Выключите KeyBridge в настройках входа в систему и повторите сохранение.")
            }
        }
        do { try persist(enabled) }
        catch {
            let saveError = error
            if enabled != before.isRegistered {
                let rollbackMessage = before.isRegistered
                    ? "Настройка не сохранилась, а прежний автозапуск не восстановлен. Откройте настройки входа в систему и проверьте KeyBridge, затем повторите сохранение."
                    : "Настройка не сохранилась, а отмена автозапуска не подтверждена. Выключите KeyBridge в настройках входа в систему и повторите сохранение."
                do {
                    if before.isRegistered {
                        try register()
                        guard status().isRegistered else { throw BridgeError(rollbackMessage) }
                    } else {
                        try unregister()
                        guard status() == .unregistered else { throw BridgeError(rollbackMessage) }
                    }
                } catch { throw BridgeError(rollbackMessage) }
            }
            throw saveError
        }
    }
}
