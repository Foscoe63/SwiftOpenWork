import Foundation
import AppKit
import UserNotifications

/// Tells you a turn finished when you are not looking at it.
///
/// A chime already played, which answers "something happened" but not "what, and in which session"
/// — and a chime is gone the moment it ends, so stepping away for ten minutes tells you nothing at
/// all. A banner persists in Notification Centre and names the session, which is the whole reason
/// to want one: local models and long builds are slow enough that nobody sits and watches them.
@MainActor
public enum TurnCompletionNotifier {

    /// Below this a turn finished before you could look away, and a banner is just litter. A
    /// failure is exempt — a turn that broke after four seconds is still worth being told about.
    public nonisolated static let minimumDurationForNotice: TimeInterval = 20

    public struct Notice: Equatable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// What to show, or nil for "stay quiet". Pure, so the rules can be tested without a
    /// notification centre, a bundle, or a user granting permission.
    nonisolated public static func notice(
        enabled: Bool,
        appIsActive: Bool,
        failed: Bool,
        duration: TimeInterval,
        sessionTitle: String,
        summary: String?
    ) -> Notice? {
        guard enabled else { return nil }
        // Interrupting something you are already watching is worse than saying nothing.
        guard !appIsActive else { return nil }
        guard failed || duration >= minimumDurationForNotice else { return nil }

        let session = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = session.isEmpty ? "Chat" : session
        let title = failed ? "Turn failed — \(name)" : "Finished — \(name)"

        let detail = summary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })

        let body: String
        if let detail, !detail.isEmpty {
            body = String(detail.prefix(140))
        } else {
            body = failed ? "The turn ended with an error." : "Took \(describe(duration))."
        }
        return Notice(title: title, body: body)
    }

    public nonisolated static func describe(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }

    // MARK: - Delivery

    private static var didRequestAuthorization = false

    /// Ask once, on first use rather than at launch: a permission prompt during the first ten
    /// seconds of an app, for something the user has not done yet, is the one people always deny.
    public static func prepare() {
        guard !didRequestAuthorization, let center = center() else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func post(_ notice: Notice) {
        guard let center = center() else { return }
        prepare()
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    /// `UNUserNotificationCenter.current()` traps outside a bundle, which is how a unit test host
    /// or a bare binary runs. Nothing about a finished turn is worth crashing over.
    private static func center() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}
