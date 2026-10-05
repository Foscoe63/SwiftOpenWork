import Foundation

/// The built-in Claude catalog, and what to do with ids Anthropic has retired.
///
/// One list, read by both the seeded `anthropic-cloud` provider and `AnthropicService`'s offline
/// fallback. They used to be two hand-written copies that both defaulted to
/// `claude-3-7-sonnet-20250219` — a model the API stopped serving on 2026-02-19 — so a fresh
/// install's default Anthropic model answered every turn with a 404.
public enum AnthropicModels {

    /// The model a new install, and the "Default" badge, points at.
    public static let defaultModelId = "claude-opus-5"

    /// The same default, as OpenRouter names it.
    public static let openRouterDefaultModelId = "anthropic/claude-opus-5"

    /// The curated models, stamped with the provider they belong to.
    ///
    /// Aliases, not dated snapshots: Anthropic's current models are published under undated ids.
    /// Prices are per 1K tokens (first-party API rates).
    public static func curated(providerId: String) -> [ModelInfo] {
        [
            ModelInfo(id: "claude-opus-5", name: "Claude Opus 5", providerId: providerId, contextWindow: 1_000_000, supportsVision: true, supportsReasoning: true, isDefault: true, speedTier: "Powerful", costPer1kPrompt: 0.005, costPer1kCompletion: 0.025),
            ModelInfo(id: "claude-sonnet-5", name: "Claude Sonnet 5", providerId: providerId, contextWindow: 1_000_000, supportsVision: true, supportsReasoning: true, speedTier: "Balanced", costPer1kPrompt: 0.002, costPer1kCompletion: 0.010),
            ModelInfo(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", providerId: providerId, contextWindow: 200_000, supportsVision: true, supportsReasoning: true, speedTier: "Fast", costPer1kPrompt: 0.001, costPer1kCompletion: 0.005)
        ]
    }

    /// Retired ids, each mapped to its successor in the same tier.
    ///
    /// Same tier rather than "the new default": a user who picked Sonnet for its price should not
    /// wake up on Opus. Covers the four ids the catalog used to ship, the other retired 3.x
    /// snapshots and Opus 4.1 (retired 2026-08-05), plus the OpenRouter slug the seed used.
    public static let retiredReplacements: [String: String] = [
        "claude-3-7-sonnet-20250219": "claude-sonnet-5",
        "claude-3-7-sonnet-latest": "claude-sonnet-5",
        "claude-3-5-sonnet-20241022": "claude-sonnet-5",
        "claude-3-5-sonnet-20240620": "claude-sonnet-5",
        "claude-3-5-sonnet-latest": "claude-sonnet-5",
        "claude-3-sonnet-20240229": "claude-sonnet-5",
        "claude-3-5-haiku-20241022": "claude-haiku-4-5",
        "claude-3-5-haiku-latest": "claude-haiku-4-5",
        "claude-3-haiku-20240307": "claude-haiku-4-5",
        "claude-3-opus-20240229": "claude-opus-5",
        "claude-3-opus-latest": "claude-opus-5",
        "claude-opus-4-1": "claude-opus-5",
        "claude-opus-4-1-20250805": "claude-opus-5",
        "anthropic/claude-3.7-sonnet": "anthropic/claude-sonnet-5",
        "anthropic/claude-3.5-sonnet": "anthropic/claude-sonnet-5",
        "anthropic/claude-3.5-haiku": "anthropic/claude-haiku-4.5",
        "anthropic/claude-3-opus": "anthropic/claude-opus-5"
    ]

    /// The id to use in place of `id`, or nil when `id` is still served.
    public static func replacement(for id: String) -> String? {
        retiredReplacements[id]
    }

    /// Rewrite a provider's model list so it names no retired model.
    ///
    /// Retired entries are dropped; for the first-party provider the curated models it lacks are
    /// added, so the list is never left empty. If the dropped entry carried the Default badge,
    /// it moves to the dropped model's successor when listed, else to the first model. Returns
    /// whether anything changed, so callers write only when they must.
    @discardableResult
    public static func removeRetired(from provider: inout ModelProvider) -> Bool {
        let retired = provider.models.filter { replacement(for: $0.id) != nil }
        guard !retired.isEmpty else { return false }

        let retiredDefault = retired.first(where: \.isDefault)
        provider.models.removeAll { replacement(for: $0.id) != nil }

        if provider.kind == .anthropic {
            let listed = Set(provider.models.map(\.id))
            for model in curated(providerId: provider.id) where !listed.contains(model.id) {
                var added = model
                added.isDefault = false
                provider.models.append(added)
            }
        } else if provider.kind == .openrouter {
            for old in retired {
                guard let successor = replacement(for: old.id),
                      !provider.models.contains(where: { $0.id == successor }) else { continue }
                provider.models.insert(
                    ModelInfo(id: successor, name: openRouterName(successor), providerId: provider.id, contextWindow: successor.contains("haiku") ? 200_000 : 1_000_000, supportsVision: true, supportsReasoning: true, speedTier: old.speedTier),
                    at: 0
                )
            }
        }

        if !provider.models.contains(where: \.isDefault), !provider.models.isEmpty {
            let target = retiredDefault.flatMap { replacement(for: $0.id) }
            let index = provider.models.firstIndex { $0.id == target } ?? 0
            provider.models[index].isDefault = true
        }
        return true
    }

    private static func openRouterName(_ slug: String) -> String {
        switch slug {
        case "anthropic/claude-opus-5": return "Claude Opus 5 (via OpenRouter)"
        case "anthropic/claude-sonnet-5": return "Claude Sonnet 5 (via OpenRouter)"
        case "anthropic/claude-haiku-4.5": return "Claude Haiku 4.5 (via OpenRouter)"
        default: return slug
        }
    }
}
