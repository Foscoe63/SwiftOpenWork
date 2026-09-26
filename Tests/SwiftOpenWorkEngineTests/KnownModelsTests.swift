import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

final class KnownModelsTests: XCTestCase {

    func testCurrentModelsCarryTheirPublishedContextAndPrices() throws {
        let sonnet = try XCTUnwrap(KnownModels.spec(for: "claude-sonnet-5"))
        XCTAssertEqual(sonnet.contextWindow, 1_000_000)
        XCTAssertEqual(sonnet.costPer1kPrompt, 0.002, accuracy: 1e-9)
        XCTAssertEqual(sonnet.costPer1kCompletion, 0.01, accuracy: 1e-9)

        let haiku = try XCTUnwrap(KnownModels.spec(for: "claude-haiku-4-5-20251001"), "a dated snapshot of a known family")
        XCTAssertEqual(haiku.contextWindow, 200_000)
        XCTAssertEqual(haiku.costPer1kCompletion, 0.005, accuracy: 1e-9)

        XCTAssertEqual(KnownModels.spec(for: "gpt-6-luna")?.inputPerMTok, 0.1)
        XCTAssertEqual(KnownModels.spec(for: "claude-fable-5-1")?.outputPerMTok, 50)
    }

    func testUnknownModelsAreLeftAlone() {
        XCTAssertNil(KnownModels.spec(for: "qwen3-coder-30b"))
        XCTAssertNil(KnownModels.spec(for: "claude-sonnet-50"), "a prefix match must respect the family boundary")
        var info = ModelInfo(id: "llama-3.3-70b", name: "Llama", contextWindow: 131_072, costPer1kPrompt: 0.5)
        info = KnownModels.applying(to: info)
        XCTAssertEqual(info.contextWindow, 131_072)
        XCTAssertEqual(info.costPer1kPrompt, 0.5)
    }

    func testDefaultProvidersUseCurrentModelsWithRealPrices() throws {
        let providers = PersistenceManager.shared.defaultProviders
        let anthropic = try XCTUnwrap(providers.first { $0.id == "anthropic-cloud" })
        let openai = try XCTUnwrap(providers.first { $0.id == "openai-cloud" })
        XCTAssertFalse(anthropic.models.contains { $0.id.hasPrefix("claude-3") })
        XCTAssertFalse(openai.models.contains { $0.id == "gpt-4o" || $0.id == "o1" })
        for model in anthropic.models + openai.models {
            XCTAssertGreaterThan(model.costPer1kCompletion, 0, "\(model.id) should carry a real price")
            XCTAssertGreaterThanOrEqual(model.contextWindow, 200_000, model.id)
        }
        XCTAssertEqual(anthropic.models.filter(\.isDefault).map(\.id), ["claude-sonnet-5"])
    }

    func testAnUntouchedOldSeedIsRefreshed() throws {
        let defaults = PersistenceManager.shared.defaultProviders
        var stored = defaults
        let anthropic = try XCTUnwrap(stored.firstIndex { $0.id == "anthropic-cloud" })
        stored[anthropic].models = [ModelInfo(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", providerId: "anthropic-cloud")]

        XCTAssertTrue(KnownModels.refreshStaleSeeds(in: &stored, defaults: defaults))
        XCTAssertEqual(stored[anthropic].models.map(\.id), defaults[anthropic].models.map(\.id))
        XCTAssertFalse(KnownModels.refreshStaleSeeds(in: &stored, defaults: defaults), "already current: nothing to do")
    }

    func testAListWithAUserAddedModelIsNotTouched() throws {
        let defaults = PersistenceManager.shared.defaultProviders
        var stored = defaults
        let openai = try XCTUnwrap(stored.firstIndex { $0.id == "openai-cloud" })
        stored[openai].models = [
            ModelInfo(id: "gpt-4o", name: "GPT-4o", providerId: "openai-cloud"),
            ModelInfo(id: "my-fine-tune", name: "Mine", providerId: "openai-cloud"),
        ]
        XCTAssertFalse(KnownModels.refreshStaleSeeds(in: &stored, defaults: defaults))
        XCTAssertEqual(stored[openai].models.map(\.id), ["gpt-4o", "my-fine-tune"])
    }
}
