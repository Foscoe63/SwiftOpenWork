import Foundation

/// Facts about hosted models the app knows by name: context window and list price.
///
/// One table, because the same three numbers were typed into the seed providers, the Anthropic
/// `/models` mapping and its offline fallback separately — and drifted: every one of them still
/// said Claude 3.x, 200K context and 2024 prices after the lineup moved on, so the context meter
/// and the session cost were both wrong for any current model.
///
/// Sources: Anthropic "Models overview" and OpenAI "Models" documentation, checked 2026-09-24.
/// A model not listed here returns nil, and callers keep whatever they derived themselves —
/// guessing a price is worse than showing none.
public enum KnownModels {

    public struct Spec: Equatable, Sendable {
        public var displayName: String
        public var contextWindow: Int
        /// US dollars per million tokens.
        public var inputPerMTok: Double
        public var outputPerMTok: Double

        public var costPer1kPrompt: Double { inputPerMTok / 1_000 }
        public var costPer1kCompletion: Double { outputPerMTok / 1_000 }
    }

    /// Exact IDs first, then dated snapshots of a known family (`claude-haiku-4-5-20251001`).
    private static let table: [(prefix: String, spec: Spec)] = [
        ("claude-fable-5-1", Spec(displayName: "Claude Fable 5.1", contextWindow: 1_000_000, inputPerMTok: 10, outputPerMTok: 50)),
        ("claude-opus-5-5", Spec(displayName: "Claude Opus 5.5", contextWindow: 1_000_000, inputPerMTok: 4, outputPerMTok: 20)),
        ("claude-sonnet-5", Spec(displayName: "Claude Sonnet 5", contextWindow: 1_000_000, inputPerMTok: 2, outputPerMTok: 10)),
        ("claude-haiku-4-5", Spec(displayName: "Claude Haiku 4.5", contextWindow: 200_000, inputPerMTok: 1, outputPerMTok: 5)),
        ("gpt-6-astra", Spec(displayName: "GPT-6 Astra", contextWindow: 1_050_000, inputPerMTok: 10, outputPerMTok: 50)),
        ("gpt-6-sol", Spec(displayName: "GPT-6 Sol", contextWindow: 1_050_000, inputPerMTok: 2, outputPerMTok: 10)),
        ("gpt-6-luna", Spec(displayName: "GPT-6 Luna", contextWindow: 1_050_000, inputPerMTok: 0.1, outputPerMTok: 0.5)),
    ]

    public static func spec(for modelId: String) -> Spec? {
        let id = modelId.lowercased()
        // Longest prefix wins so `claude-sonnet-5-1` would not be read as `claude-sonnet-5`
        // unless the table says so — and today's IDs are all distinct, so this is only a guard.
        return table
            .filter { id == $0.prefix || id.hasPrefix($0.prefix + "-") || id.hasPrefix($0.prefix + "@") }
            .max { $0.prefix.count < $1.prefix.count }?
            .spec
    }

    /// `info` with the facts this table knows filled in. Anything it doesn't know is left as is.
    public static func applying(to info: ModelInfo) -> ModelInfo {
        guard let spec = spec(for: info.id) else { return info }
        var out = info
        out.contextWindow = spec.contextWindow
        out.costPer1kPrompt = spec.costPer1kPrompt
        out.costPer1kCompletion = spec.costPer1kCompletion
        return out
    }

    // MARK: - Migration

    /// Model IDs the app itself seeded for each hosted provider before the lineup moved on.
    private static let staleSeeds: [String: Set<String>] = [
        "anthropic-cloud": [
            "claude-3-7-sonnet-20250219", "claude-3-5-sonnet-20241022",
            "claude-3-5-haiku-20241022", "claude-3-opus-20240229",
        ],
        "openai-cloud": ["gpt-4o", "gpt-4o-mini", "o1", "o3-mini"],
    ]

    /// Replace a hosted provider's model list with the current seed when it is still *entirely*
    /// what an old version of the app seeded. Seeds only reach a fresh install, so everyone else
    /// kept Claude 3.x and GPT-4o with 2024 context windows and prices until they happened to
    /// refresh from the API. A list with anything else in it — a model the user added — is theirs
    /// and is left alone. Returns whether anything changed.
    @discardableResult
    public static func refreshStaleSeeds(in providers: inout [ModelProvider], defaults: [ModelProvider]) -> Bool {
        var changed = false
        for index in providers.indices {
            guard let stale = staleSeeds[providers[index].id],
                  !providers[index].models.isEmpty,
                  providers[index].models.allSatisfy({ stale.contains($0.id) }),
                  let current = defaults.first(where: { $0.id == providers[index].id }),
                  !current.models.isEmpty else { continue }
            providers[index].models = current.models
            changed = true
        }
        return changed
    }
}
