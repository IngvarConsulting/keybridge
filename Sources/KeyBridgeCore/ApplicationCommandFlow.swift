// SPDX-License-Identifier: MIT
import Foundation

/// UI command identity is separate from the agent's durable request identity.
/// A Stop supersedes old UI replies; only its confirmed outcome can finish Quit.
public struct ApplicationCommandFlow {
    public struct Ticket: Equatable {
        public let sequence: UInt64
        public let id: String
        public let action: String
    }
    public private(set) var active: Ticket?
    public private(set) var quitRequested = false
    private var sequence: UInt64 = 0

    public init() {}
    public mutating func requestQuit() { quitRequested = true }
    public mutating func begin(id: String, action: String) -> Ticket? {
        if active != nil && action != "stop" { return nil }
        if active?.action == "stop" && action == "stop" { return nil }
        sequence &+= 1
        let ticket = Ticket(sequence: sequence, id: id, action: action)
        active = ticket
        return ticket
    }
    public func isCurrent(_ ticket: Ticket) -> Bool { active == ticket }
    @discardableResult public mutating func finish(_ ticket: Ticket, succeeded: Bool,
                                                   stopped: Bool, stopSaved: Bool) -> Bool {
        guard active == ticket else { return false }
        active = nil
        return quitRequested && ticket.action == "stop" && succeeded && stopped && stopSaved
    }
}
