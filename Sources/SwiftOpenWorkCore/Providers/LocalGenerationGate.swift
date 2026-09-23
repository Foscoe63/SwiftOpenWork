import Foundation

/// One generation at a time on the in-process engine, first come first served.
///
/// Nothing used to stop two turns generating on the built-in model at once, and three things in
/// this app start turns without the chat window knowing: scheduled automations, Shortcuts and
/// Siri, and sub-agents, which a lead can spawn in parallel. They all shared one cached
/// `ChatSession` and one list of what it had consumed, so an automation arriving mid-turn could
/// replace the session a chat turn was still streaming from, and the chat turn's cleanup then
/// recorded its reply against the automation's history. The next turn continued a KV cache that
/// no longer matched its transcript — the model steered by text nobody could see.
///
/// Serialising generation costs little on one GPU, where concurrent decoding mostly splits the
/// same throughput. What it buys is that the cache bookkeeping between deciding, generating and
/// recording is never interleaved. A waiting turn says what it is waiting for, so a pause reads as
/// a queue rather than a hang.
public actor LocalGenerationGate {

    public static let shared = LocalGenerationGate()

    /// Who a generation is for, in words a person would recognise: "a chat turn",
    /// "automation Morning Brief", "sub-agent Researcher". Set around a run with
    /// `LocalGenerationGate.$claimLabel.withValue(...)`.
    @TaskLocal public static var claimLabel: String?

    /// Where a run's time spent queued behind other generations is recorded. Set around a run
    /// with `LocalGenerationGate.$waitClock.withValue(...)` by callers whose time limit should
    /// count only their own work — a sub-agent queued behind a sibling was stopped at its
    /// deadline having generated almost nothing.
    @TaskLocal public static var waitClock: WaitClock?

    /// Total time spent waiting in the queue, including a wait still in progress.
    public final class WaitClock: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Double = 0
        private var waitingSince: Double?

        public init() {}

        public var seconds: Double {
            lock.lock(); defer { lock.unlock() }
            return total + (waitingSince.map { CFAbsoluteTimeGetCurrent() - $0 } ?? 0)
        }

        func begin() {
            lock.lock(); defer { lock.unlock() }
            if waitingSince == nil { waitingSince = CFAbsoluteTimeGetCurrent() }
        }

        func end() {
            lock.lock(); defer { lock.unlock() }
            if let since = waitingSince { total += CFAbsoluteTimeGetCurrent() - since }
            waitingSince = nil
        }
    }

    public struct Ticket: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    private struct Waiter {
        let id: UInt64
        let label: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private var nextId: UInt64 = 0
    private var holder: (id: UInt64, label: String)?
    private var waiters: [Waiter] = []

    public init() {}

    /// The label of whoever holds the engine, if anyone.
    public var currentHolder: String? { holder?.label }

    /// How many generations are queued behind the holder.
    public var queueLength: Int { waiters.count }

    /// Take the engine, waiting in line if it is busy.
    ///
    /// `onWait` is called once, before suspending, with the label of the generation in front —
    /// only when there is actually a wait. Cancelling the waiting task leaves the queue and throws
    /// `CancellationError`, so a Stop pressed while queued does not later start a generation
    /// nobody is listening to.
    public func acquire(
        label: String,
        onWait: @Sendable (String) -> Void = { _ in }
    ) async throws -> Ticket {
        nextId += 1
        let id = nextId
        try Task.checkCancellation()
        if holder == nil {
            holder = (id, label)
            return Ticket(id: id)
        }
        onWait(holder?.label ?? "another generation")
        let clock = Self.waitClock
        clock?.begin()
        defer { clock?.end() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, label: label, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        return Ticket(id: id)
    }

    /// Take the engine only if it is free right now.
    ///
    /// For work that is worth doing only when nothing else wants the model — editor suggestions.
    /// Queueing those would make an agent turn wait behind a guess at the next line, and the guess
    /// would be stale by the time it ran.
    public func tryAcquire(label: String) -> Ticket? {
        guard holder == nil, waiters.isEmpty else { return nil }
        nextId += 1
        holder = (nextId, label)
        return Ticket(id: nextId)
    }

    /// Give the engine to the next in line. Releasing a ticket that does not hold it is a no-op,
    /// so a double release cannot hand the engine to two generations.
    public func release(_ ticket: Ticket) {
        guard holder?.id == ticket.id else { return }
        guard !waiters.isEmpty else {
            holder = nil
            return
        }
        let next = waiters.removeFirst()
        holder = (next.id, next.label)
        next.continuation.resume()
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// The notice a queued turn shows.
    public nonisolated static func waitingNotice(behind label: String) -> String {
        "Waiting for the local model — it is busy with \(label). This turn starts when that one finishes."
    }
}
