import Foundation
import SwiftOpenWorkCore

/// Rebuilds thinking blocks from Anthropic's streaming events, exactly as delivered.
///
/// A block streams as `content_block_start` (type `thinking`, or `redacted_thinking` carrying its
/// payload), then `thinking_delta`s with the text — empty when display is omitted — then one
/// `signature_delta`, then `content_block_stop`. Nothing is trimmed, merged or normalised: the API
/// verifies the signature against what comes back and rejects an edited block.
public struct ThinkingStreamCapture {

    private var kind: ThinkingBlock.Kind?
    private var text = ""
    private var signature = ""
    private var redacted = ""
    /// Set once any text or tool call has started in this response. A thinking block after that
    /// point is not in the leading position this app can rebuild, so it is flagged, not replayed.
    private var sawContent = false

    public init() {}

    /// Feed one decoded SSE event. Returns the block when this event completes one.
    public mutating func handle(_ event: [String: Any], modelId: String) -> ThinkingBlock? {
        switch event["type"] as? String {
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            switch block?["type"] as? String {
            case "thinking":
                kind = .thinking
                text = block?["thinking"] as? String ?? ""
                signature = block?["signature"] as? String ?? ""
            case "redacted_thinking":
                kind = .redacted
                redacted = block?["data"] as? String ?? ""
            case .some:
                sawContent = true
            case .none:
                break
            }
            return nil

        case "content_block_delta":
            guard kind != nil, let delta = event["delta"] as? [String: Any] else { return nil }
            switch delta["type"] as? String {
            case "thinking_delta": text += delta["thinking"] as? String ?? ""
            case "signature_delta": signature += delta["signature"] as? String ?? ""
            default: break
            }
            return nil

        case "content_block_stop":
            guard let finished = kind else { return nil }
            let block = ThinkingBlock(
                kind: finished,
                thinking: text,
                signature: signature,
                data: redacted,
                modelId: modelId,
                leading: !sawContent
            )
            kind = nil
            text = ""
            signature = ""
            redacted = ""
            return block

        default:
            return nil
        }
    }
}
