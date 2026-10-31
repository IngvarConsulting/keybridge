// SPDX-License-Identifier: MIT
import Foundation

/// Orders submission receipts, not operation completion. In particular, Stop
/// cannot overtake an already launched Control process that still holds Start.
@MainActor
public final class ApplicationSubmissionQueue {
    private var tail: Task<Void, Never>?
    public init() {}

    public func enqueue<Value>(_ operation: @escaping () async throws -> Value) -> Task<Value, Error> {
        let previous = tail
        let submitted = Task {
            if let previous { await previous.value }
            return try await operation()
        }
        tail = Task { _ = try? await submitted.value }
        return submitted
    }
}
