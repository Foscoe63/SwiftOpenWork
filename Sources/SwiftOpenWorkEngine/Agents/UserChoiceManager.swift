import Foundation

/// Radiant `ask_user` parity — pause the agent loop until the user answers in chat UI.
@MainActor
public final class UserChoiceManager: ObservableObject {
    public static let shared = UserChoiceManager()

    public struct PendingChoice: Identifiable, Equatable {
        public let id: String
        public let question: String
        public let options: [String]
        public let requestedAt: Date
    }

    @Published public private(set) var pending: PendingChoice?

    /// Every question waiting for an answer, oldest first. There used to be one continuation, so
    /// a second question orphaned the first and its run waited for ever.
    private var queue: [(choice: PendingChoice, continuation: CheckedContinuation<String, Never>)] = []

    private init() {}

    public func request(question: String, options: [String], callId: String) async -> String {
        let choice = PendingChoice(id: callId, question: question, options: options, requestedAt: Date())
        return await withCheckedContinuation { cont in
            queue.append((choice, cont))
            pending = queue.first?.choice
        }
    }

    /// Answers the question on screen — the oldest — and brings up the next.
    public func resolve(answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !queue.isEmpty else { return }
        let head = queue.removeFirst()
        pending = queue.first?.choice
        head.continuation.resume(returning: text)
    }

    public func cancelAll() {
        let waiting = queue
        queue.removeAll()
        pending = nil
        for entry in waiting { entry.continuation.resume(returning: "(user cancelled)") }
    }
}
