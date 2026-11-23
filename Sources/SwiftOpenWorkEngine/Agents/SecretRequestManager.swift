import Foundation

/// Pauses the agent loop while the user types a secret into a secure field.
///
/// Same shape as `UserChoiceManager`, with one difference that matters: the typed value goes
/// straight into `AgentSecrets` and never into the continuation's result, the transcript or the
/// model. The run is told only whether it was saved.
@MainActor
public final class SecretRequestManager: ObservableObject {
    public static let shared = SecretRequestManager()

    public struct Pending: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let reason: String
    }

    public enum Outcome: Equatable { case saved, declined, failed }

    @Published public private(set) var pending: Pending?
    private var queue: [(request: Pending, continuation: CheckedContinuation<Outcome, Never>)] = []

    private init() {}

    public func request(name: String, reason: String, callId: String) async -> Outcome {
        let request = Pending(id: callId, name: name, reason: reason)
        return await withCheckedContinuation { cont in
            queue.append((request, cont))
            pending = queue.first?.request
        }
    }

    /// Stores the value for the request on screen and brings up the next.
    public func submit(value: String) {
        guard !queue.isEmpty else { return }
        let head = queue.removeFirst()
        pending = queue.first?.request
        let saved = AgentSecrets.save(name: head.request.name, value: value)
        head.continuation.resume(returning: saved ? .saved : .failed)
    }

    public func decline() {
        guard !queue.isEmpty else { return }
        let head = queue.removeFirst()
        pending = queue.first?.request
        head.continuation.resume(returning: .declined)
    }

    public func cancelAll() {
        let waiting = queue
        queue.removeAll()
        pending = nil
        for entry in waiting { entry.continuation.resume(returning: .declined) }
    }
}
