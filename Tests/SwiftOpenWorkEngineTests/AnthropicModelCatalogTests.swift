import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// The built-in Claude catalog shipped `claude-3-7-sonnet-20250219` as the Anthropic default long
/// after the API retired it (2026-02-19), in two hand-kept copies — the seed and the service's
/// offline fallback. These pin the catalog to one list, the migration of installs that stored the
/// old ids, and the request shape current models accept.
final class AnthropicModelCatalogTests: XCTestCase {

    private var seededAnthropic: ModelProvider? {
        PersistenceManager.shared.defaultProviders.first { $0.id == "anthropic-cloud" }
    }

    // MARK: - Catalog

    func testSeedAndServiceFallbackListTheSameModels() async throws {
        let seeded = try XCTUnwrap(seededAnthropic)
        // No API key, so `listModels` takes the offline fallback without touching the network.
        // `.local` keeps `ProviderCredentials` from filling one in from this Mac's Keychain.
        var keyless = seeded
        keyless.apiKey = ""
        keyless.type = .local
        let fallback = try await AnthropicService().listModels(provider: keyless)
        XCTAssertEqual(seeded.models.map(\.id), fallback.map(\.id))
        XCTAssertEqual(seeded.models.first(where: \.isDefault)?.id, fallback.first(where: \.isDefault)?.id)
    }

    func testTheSeededAnthropicDefaultIsCurrent() throws {
        let seeded = try XCTUnwrap(seededAnthropic)
        let defaults = seeded.models.filter(\.isDefault)
        XCTAssertEqual(defaults.map(\.id), [AnthropicModels.defaultModelId])
        for model in seeded.models {
            XCTAssertNil(AnthropicModels.replacement(for: model.id), "\(model.id) is retired")
        }
    }

    func testNoSeededProviderListsARetiredModel() {
        for provider in PersistenceManager.shared.defaultProviders {
            for model in provider.models {
                XCTAssertNil(AnthropicModels.replacement(for: model.id), "\(provider.id) lists retired \(model.id)")
            }
        }
    }

    func testEveryReplacementIsItselfCurrent() {
        for (old, new) in AnthropicModels.retiredReplacements {
            XCTAssertNil(AnthropicModels.replacement(for: new), "\(old) maps to \(new), which is also retired")
        }
    }

    // MARK: - Migration of existing installs

    /// What a pre-2026-09 install has in `providers.json`.
    private func legacyAnthropicProvider() -> ModelProvider {
        var p = ModelProvider(name: "Anthropic Claude", type: .cloud, kind: .anthropic)
        p.id = "anthropic-cloud"
        p.models = [
            ModelInfo(id: "claude-3-7-sonnet-20250219", name: "Claude 3.7 Sonnet", providerId: p.id, isDefault: true),
            ModelInfo(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", providerId: p.id),
            ModelInfo(id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", providerId: p.id)
        ]
        return p
    }

    func testStoredAnthropicProviderLosesRetiredModels() {
        var provider = legacyAnthropicProvider()
        XCTAssertTrue(AnthropicModels.removeRetired(from: &provider))
        XCTAssertEqual(Set(provider.models.map(\.id)), Set(AnthropicModels.curated(providerId: "x").map(\.id)))
        XCTAssertTrue(provider.models.allSatisfy { $0.providerId == "anthropic-cloud" })
    }

    /// The Default badge follows the retired default to its same-tier successor — a Sonnet user
    /// is not moved onto Opus pricing.
    func testTheStoredDefaultMovesToItsSuccessor() {
        var provider = legacyAnthropicProvider()
        AnthropicModels.removeRetired(from: &provider)
        XCTAssertEqual(provider.models.filter(\.isDefault).map(\.id), ["claude-sonnet-5"])
    }

    func testMigrationIsIdempotentAndKeepsUserAddedModels() {
        var provider = legacyAnthropicProvider()
        provider.models.append(ModelInfo(id: "claude-opus-4-8", name: "Opus 4.8", providerId: provider.id))
        AnthropicModels.removeRetired(from: &provider)
        let once = provider
        XCTAssertFalse(AnthropicModels.removeRetired(from: &provider))
        XCTAssertEqual(provider, once)
        XCTAssertTrue(provider.models.contains { $0.id == "claude-opus-4-8" })
    }

    func testStoredOpenRouterSlugIsReplaced() {
        var provider = ModelProvider(name: "OpenRouter", type: .cloud, kind: .openrouter)
        provider.models = [
            ModelInfo(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet (via OpenRouter)", providerId: provider.id),
            ModelInfo(id: "deepseek/deepseek-r1", name: "DeepSeek R1", providerId: provider.id)
        ]
        XCTAssertTrue(AnthropicModels.removeRetired(from: &provider))
        XCTAssertEqual(provider.models.map(\.id), ["anthropic/claude-sonnet-5", "deepseek/deepseek-r1"])
    }

    func testSettingsNamingARetiredModelAreRepointed() {
        var settings = AppSettings.default
        settings.defaultModelId = "claude-3-7-sonnet-20250219"
        settings.inlineSuggestionModelId = "claude-3-5-haiku-20241022"
        XCTAssertTrue(PersistenceManager.replaceRetiredModels(in: &settings))
        XCTAssertEqual(settings.defaultModelId, "claude-sonnet-5")
        XCTAssertEqual(settings.inlineSuggestionModelId, "claude-haiku-4-5")
        XCTAssertFalse(PersistenceManager.replaceRetiredModels(in: &settings))
    }

    func testSettingsNamingOtherModelsAreLeftAlone() {
        var settings = AppSettings.default
        let before = settings
        XCTAssertFalse(PersistenceManager.replaceRetiredModels(in: &settings))
        XCTAssertEqual(settings.defaultModelId, before.defaultModelId)
    }

    // MARK: - Request shape

    private func fields(_ id: String, _ effort: ReasoningEffort, reasoning: Bool = true, topP: Double = 0.9) -> [String: Any] {
        AnthropicService.thinkingFields(modelId: id, supportsReasoning: reasoning, reasoningEffort: effort, temperature: 0.3, topP: topP)
    }

    /// Opus 5 rejects `budget_tokens` and every sampling parameter with a 400.
    func testCurrentModelsGetAdaptiveThinkingAndNoSampling() {
        for id in ["claude-opus-5", "claude-sonnet-5", "claude-opus-4-8", "claude-fable-5-1"] {
            for effort in ReasoningEffort.allCases {
                let f = fields(id, effort)
                XCTAssertNil(f["temperature"], "\(id) \(effort)")
                XCTAssertNil(f["top_p"], "\(id) \(effort)")
                let thinking = f["thinking"] as? [String: Any]
                XCTAssertEqual(thinking?["type"] as? String, "adaptive", "\(id) \(effort)")
                XCTAssertNil(thinking?["budget_tokens"])
                XCTAssertEqual(thinking?["display"] as? String, "summarized")
            }
        }
    }

    func testEffortIsPassedThroughAndOffBecomesLow() {
        XCTAssertEqual((fields("claude-opus-5", .high)["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual((fields("claude-opus-5", .medium)["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual((fields("claude-opus-5", .off)["output_config"] as? [String: Any])?["effort"] as? String, "low")
    }

    /// Haiku 4.5 predates adaptive thinking and rejects `effort`.
    func testHaikuKeepsBudgetedThinking() {
        let on = fields("claude-haiku-4-5", .medium)
        XCTAssertEqual((on["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 2048)
        XCTAssertNil(on["output_config"])
        XCTAssertNil(on["temperature"])

        let off = fields("claude-haiku-4-5", .off)
        XCTAssertNil(off["thinking"])
        XCTAssertEqual(off["temperature"] as? Double, 0.3)
        XCTAssertEqual(off["top_p"] as? Double, 0.9)
    }

    func testSonnet46TakesSamplingOnlyWithThinkingOff() {
        let off = fields("claude-sonnet-4-6", .off)
        XCTAssertNil(off["thinking"])
        XCTAssertEqual(off["temperature"] as? Double, 0.3)
        let on = fields("claude-sonnet-4-6", .high)
        XCTAssertNil(on["temperature"])
        XCTAssertEqual((on["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertNil((on["thinking"] as? [String: Any])?["display"])
    }

    /// An id this list has never heard of is assumed to be newer, not older.
    func testUnknownModelsAreTreatedAsCurrent() {
        XCTAssertEqual(AnthropicService.thinkingStyle(for: "claude-opus-6"), .adaptive)
        XCTAssertEqual(AnthropicService.thinkingStyle(for: "claude-3-7-sonnet-20250219"), .budgeted)
    }
}
