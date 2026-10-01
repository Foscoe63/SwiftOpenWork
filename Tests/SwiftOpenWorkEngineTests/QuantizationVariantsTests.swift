import XCTest
@testable import SwiftOpenWorkCore

final class QuantizationVariantsTests: XCTestCase {
    private func model(_ id: String, quant: String?, ram: Double, downloaded: Bool = false) -> LocalMLXModel {
        LocalMLXModel(id: id, name: id, description: "", quantization: quant, isDownloaded: downloaded, estimatedRAMGB: ram)
    }

    func testFitThresholds() {
        func fit(_ need: Double, avail: Double) -> MLXMemoryFit {
            MLXMemoryBudget.fit(requiredRAMGB: need, budgetRatio: 0.75, availableGB: avail, physicalGB: 32)
        }
        XCTAssertEqual(fit(10, avail: 20), .fits)
        XCTAssertEqual(fit(10, avail: 4), .needsFreeMemory(shortByGB: 6))
        XCTAssertEqual(fit(26, avail: 30), .overBudget)          // budget is 24 GB
        XCTAssertEqual(fit(31, avail: 30), .wontLoad)            // beyond 95% of 32 GB
        XCTAssertTrue(fit(31, avail: 30).willLikelyFail)
        XCTAssertFalse(fit(26, avail: 30).willLikelyFail)
    }

    func testBitsParsing() {
        XCTAssertEqual(model("a", quant: "4-bit", ram: 1).quantizationBits, 4)
        XCTAssertEqual(model("a", quant: "8-bit", ram: 1).quantizationBits, 8)
        XCTAssertEqual(model("a", quant: "fp16", ram: 1).quantizationBits, 16)
        XCTAssertEqual(model("a", quant: "bf16", ram: 1).quantizationBits, 16)
        XCTAssertEqual(model("a", quant: "MXFP4", ram: 1).quantizationBits, 4)
        XCTAssertNil(model("a", quant: nil, ram: 1).quantizationBits)
    }

    func testSameModelAtDifferentPrecisionsGroupsTogether() {
        let models = [
            model("mlx-community/Qwen3-8B-8bit", quant: "8-bit", ram: 10),
            model("other/Llama-3-70B-4bit", quant: "4-bit", ram: 40),
            model("mlx-community/Qwen3-8B-4bit", quant: "4-bit", ram: 6),
            model("ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit", quant: "4-bit", ram: 21),
            model("mlx-community/Ornith-1.5-35B-A3B-8bit", quant: "8-bit", ram: 44),
        ]
        let groups = LocalMLXModel.variantGroups(models)
        XCTAssertEqual(groups.count, 3)
        // First-appearance order, variants low bits first.
        XCTAssertEqual(groups[0].map(\.quantizationBits), [4, 8])
        XCTAssertEqual(groups[1].count, 1)
        XCTAssertEqual(groups[2].map(\.id), ["ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit", "mlx-community/Ornith-1.5-35B-A3B-8bit"])
    }

    func testDifferentSizesDoNotGroup() {
        let a = model("mlx-community/Qwen3-8B-4bit", quant: "4-bit", ram: 6)
        let b = model("mlx-community/Qwen3-32B-4bit", quant: "4-bit", ram: 20)
        XCTAssertEqual(LocalMLXModel.variantGroups([a, b]).count, 2)
    }

    func testRecommendsMostPreciseVariantThatFits() {
        let group = LocalMLXModel.variantGroups([
            model("o/M-4bit", quant: "4-bit", ram: 6),
            model("o/M-8bit", quant: "8-bit", ram: 12),
            model("o/M-bf16", quant: "bf16", ram: 24),
        ])[0]
        func pick(avail: Double) -> Int? {
            LocalMLXModel.recommendedVariant(in: group, budgetRatio: 0.9, availableGB: avail, physicalGB: 32)?.quantizationBits
        }
        XCTAssertEqual(pick(avail: 30), 16)
        XCTAssertEqual(pick(avail: 14), 8)
        XCTAssertEqual(pick(avail: 7), 4)
        XCTAssertEqual(pick(avail: 1), 4, "nothing fits right now: offer the smallest")
    }

    func testADownloadedVariantIsAlwaysTheOneShown() {
        let group = LocalMLXModel.variantGroups([
            model("o/M-4bit", quant: "4-bit", ram: 6, downloaded: true),
            model("o/M-8bit", quant: "8-bit", ram: 12),
        ])[0]
        XCTAssertEqual(LocalMLXModel.recommendedVariant(in: group, budgetRatio: 0.9, availableGB: 30, physicalGB: 32)?.quantizationBits, 4)
    }
}
