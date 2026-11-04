// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// Session teardown releases current resources without rewriting the user's
/// choice for the next login. Only explicit user Stop/Quit inhibits that login.
public enum AgentStopAction: String {
    case stop, shutdown
    case sessionStop = "session-stop"
    case sessionShutdown = "session-shutdown"
    public var savesStopIntent: Bool { self == .stop || self == .shutdown }
    public var exitsAgent: Bool { self == .shutdown || self == .sessionShutdown }
}

/// A successful Stop receipt is not an exited agent. After Shutdown, the
/// persisted result is combined with fresh process ownership and saved intent;
/// status.json is deliberately not used as proof that the VM has stopped.
public enum ApplicationShutdown {
    public struct Evidence {
        public let acknowledged: Bool
        public let agentExited: Bool
        public let stopped: Bool
        public let stopSaved: Bool
        public var sessionEnded: Bool { acknowledged && agentExited && stopped }
        public var confirmed: Bool { sessionEnded && stopSaved }
    }

    public static func evidence(completion: [String: Any], agentExited: Bool,
                                ownership: [String: Any], intent: [String: Any]) -> Evidence {
        Evidence(acknowledged: completion["ok"] as? Bool == true,
                 agentExited: agentExited,
                 stopped: ownership["ownership"] as? String == "absent" && ownership["running"] as? Bool == false,
                 stopSaved: intent["want"] as? Bool == false && intent["autoInhibit"] as? Bool == true)
    }

    public static func hasExited(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    public static func observe(runtime: URL, agentPID: Int32, completion: [String: Any]) -> Evidence {
        evidence(completion: completion, agentExited: hasExited(agentPID),
                 ownership: RuntimeOwnership.observation(runtime: runtime),
                 intent: readObject(runtime.appendingPathComponent("intent.json")))
    }
    public static func observeWithoutAgent(runtime: URL, completion: [String: Any]) -> Evidence {
        let fd=open(runtime.appendingPathComponent("agent.lock").path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
        let locked=fd>=0 && flock(fd,LOCK_EX|LOCK_NB)==0
        defer { if locked { flock(fd,LOCK_UN) };if fd>=0 { close(fd) } }
        var absent=false
        if locked {
            let pid=(try? String(contentsOf:runtime.appendingPathComponent("agent.pid"))).flatMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }
            absent=pid.map { hasExited($0) } ?? true
        }
        return evidence(completion:completion,agentExited:absent,ownership:RuntimeOwnership.observation(runtime:runtime),
                        intent:readObject(runtime.appendingPathComponent("intent.json")))
    }

    public enum Failure: LocalizedError {
        case noReceipt, agentStillRunning, unsafeState
        public var errorDescription: String? {
            switch self {
            case .noReceipt:
                return "KeyBridge не подтвердил завершение фоновой программы. Ответ не получен; повторите «Выключить и выйти»."
            case .agentStillRunning:
                return "Фоновая программа KeyBridge ещё работает. Она не завершилась за отведённое время; повторите «Выключить и выйти»."
            case .unsafeState:
                return "Завершение KeyBridge не подтверждено. Не удалось одновременно подтвердить остановку и сохранённый запрет запуска; повторите «Выключить и выйти»."
            }
        }
    }
}
