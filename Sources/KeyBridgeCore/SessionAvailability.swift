// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics

/// Notifications describe transitions, while a fresh Quartz observation tells
/// whether this process's GUI session is currently on the console. Neither a
/// missed activation notification nor a console poll may override system sleep.
public final class SessionAvailability {
    public enum Event { case poll, willSleep, didWake, willResignActive, didBecomeActive }
    public enum Availability: String { case active, sleeping, unavailable }
    public struct Observation {
        public let onConsole: Bool?
        public let loginDone: Bool?
        public init(onConsole: Bool?,loginDone: Bool?) { self.onConsole=onConsole;self.loginDone=loginDone }
        public static func current() -> Observation {
            let value=CGSessionCopyCurrentDictionary() as? [String:Any]
            return Observation(onConsole:value?[kCGSessionOnConsoleKey as String] as? Bool,
                               loginDone:value?[kCGSessionLoginDoneKey as String] as? Bool)
        }
    }
    public struct State: Equatable {
        public let availability: Availability
        public let reason: String
        public var active: Bool { availability == .active }
        public func permitsAutomaticResume(authorized: Bool,wantsRunning: Bool,inhibited: Bool) -> Bool {
            active && authorized && wantsRunning && !inhibited
        }
    }
    public struct Change {
        public let before: State
        public let after: State
        public var changed: Bool { before != after }
    }
    private let lock=NSLock()
    private var sleeping=false
    private var switchPending=false
    private var current=State(availability:.unavailable,reason:"observation-unavailable")
    public init(observation: Observation = .current()) { _=observe(.poll,observation:observation) }
    public var state: State { lock.lock();defer { lock.unlock() };return current }
    @discardableResult public func observe(_ event: Event,observation: Observation = .current()) -> Change {
        lock.lock();defer { lock.unlock() }
        let before=current
        switch event {
        case .willSleep:sleeping=true
        case .didWake:sleeping=false
        case .willResignActive:switchPending=true
        case .didBecomeActive:switchPending=false
        case .poll:break
        }
        // Resign is announced before Quartz may switch the console. Do not
        // undo it from an old on-console sample. Once off-console was observed,
        // a later true sample can recover a missed become-active notification.
        if observation.onConsole == false { switchPending=false }
        if sleeping { current=State(availability:.sleeping,reason:"system-sleep") }
        else if switchPending || observation.onConsole == false { current=State(availability:.unavailable,reason:"session-off-console") }
        else if observation.loginDone == false { current=State(availability:.unavailable,reason:"login-incomplete") }
        else if observation.onConsole == true && observation.loginDone == true { current=State(availability:.active,reason:"") }
        else { current=State(availability:.unavailable,reason:"observation-unavailable") }
        return Change(before:before,after:current)
    }
}
