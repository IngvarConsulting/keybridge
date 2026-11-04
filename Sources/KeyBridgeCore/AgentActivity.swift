// SPDX-License-Identifier: MIT
import Foundation

/// Controller admission owns activity. Engine observations describe the VM and
/// may never make an executing controller operation appear idle.
public final class AgentActivity {
    private let lock=NSLock()
    private var token: OperationToken?
    public init() {}
    public var current: OperationToken? {
        lock.lock();defer { lock.unlock() };return token
    }
    public func begin(_ value: OperationToken) {
        lock.lock();defer { lock.unlock() };token=value
    }
    public func finish(_ value: OperationToken) {
        lock.lock();defer { lock.unlock() }
        if token == value { token=nil }
    }
    public func applying(to observation: [String:Any]) -> [String:Any] {
        lock.lock();defer { lock.unlock() }
        var state=observation
        state["busy"]=token != nil
        state["operation"]=token?.action ?? ""
        return state
    }
}

/// Only one diagnostic may wait; control changes are never delayed implicitly.
public enum AgentAdmission {
    public static func canWait(action:String,active:String?,pending:Bool,stopping:Bool)->Bool {
        ["probe","inspect","resources"].contains(action) && active != nil && !pending && !stopping &&
            AgentStopAction(rawValue:active ?? "") == nil
    }
}
