// SPDX-License-Identifier: MIT
import Foundation

/// UI command identity is separate from the agent's durable request identity.
/// A Stop supersedes old UI replies; Quit also requires confirmed agent exit.
public struct ApplicationCommandFlow {
    public struct Ticket: Equatable {
        public let sequence: UInt64
        public let id: String
        public let action: String
    }
    public private(set) var active: Ticket?
    public private(set) var diagnostic: Ticket?
    public private(set) var preference: Ticket?
    public static let diagnostics: Set<String> = ["probe", "recheck", "measure"]
    public private(set) var quitRequested = false
    private var sequence: UInt64 = 0

    public init() {}
    public mutating func requestQuit() { quitRequested = true }
    public mutating func begin(id: String, action: String) -> Ticket? {
        if action == "stop", active?.action == "stop" { return nil }
        if action == "autostart" {
            guard preference == nil else { return nil }
        } else if action != "stop", active != nil {
            guard Self.diagnostics.contains(action), active?.action != "stop", diagnostic == nil else { return nil }
        }
        sequence &+= 1
        let ticket = Ticket(sequence: sequence, id: id, action: action)
        if action == "stop" { active=ticket;diagnostic=nil;preference=nil }
        else if action == "autostart" { preference=ticket }
        else if active != nil { diagnostic=ticket }
        else { active=ticket }
        return ticket
    }
    public func isCurrent(_ ticket: Ticket) -> Bool { active == ticket || diagnostic == ticket || preference == ticket }
    @discardableResult public mutating func finish(_ ticket: Ticket, succeeded: Bool,
                                                   stopped: Bool, stopSaved: Bool, agentExited: Bool = false) -> Bool {
        guard isCurrent(ticket) else { return false }
        if active == ticket { active=diagnostic;diagnostic=nil }
        else if diagnostic == ticket { diagnostic=nil }
        else { preference=nil }
        return quitRequested && ticket.action == "stop" && succeeded && stopped && stopSaved && agentExited
    }
}
