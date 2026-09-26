import Foundation

/// One thinking block a Claude model produced, kept exactly as received.
///
/// Claude's API requires the thinking blocks of a tool-use turn to come back, complete and
/// unmodified, with the tool results: the `signature` carries the encrypted reasoning the model
/// resumes from, and an altered block is rejected. This app kept only the readable summary, so
/// every tool round started the model's reasoning over. Nothing here is ever edited — the fields
/// are stored as the stream delivered them, including an empty `thinking` string when the
/// provider omits the text and sends only the signature.
public struct ThinkingBlock: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case thinking
        case redacted
    }

    public var kind: Kind
    /// The readable text. Empty when thinking display is omitted. `.thinking` only.
    public var thinking: String
    /// The signature that authenticates the block. `.thinking` only.
    public var signature: String
    /// The opaque payload of a redacted block. `.redacted` only.
    public var data: String
    /// The model that produced it. A block is only valid for the model that wrote it (and a few
    /// others), so it is replayed to that model alone.
    public var modelId: String
    /// True when the block came before any text or tool call in its response. A block that
    /// followed content would have to be replayed in a position this app does not track, so
    /// those are never replayed.
    public var leading: Bool

    public init(
        kind: Kind,
        thinking: String = "",
        signature: String = "",
        data: String = "",
        modelId: String,
        leading: Bool = true
    ) {
        self.kind = kind
        self.thinking = thinking
        self.signature = signature
        self.data = data
        self.modelId = modelId
        self.leading = leading
    }
}
