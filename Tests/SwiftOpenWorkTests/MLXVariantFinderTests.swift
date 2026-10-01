import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkLocalInference

final class MLXVariantFinderTests: XCTestCase {
    private let template = LocalMLXModel(
        id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", name: "q", description: "d",
        parameterCount: "7B", quantization: "4-bit", modelType: "qwen2"
    )

    func testOnlyTheSameModelAtAnotherPrecisionIsASibling() {
        let hits = [
            "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            "mlx-community/Qwen2.5-Coder-7B-Instruct-bf16",
            "mlx-community/Qwen2.5-Coder-7B-Instruct-8bit",
            "mlx-community/Qwen2.5.1-Coder-7B-Instruct-8bit",
            "mlx-community/Josiefied-Qwen2.5-Coder-7B-Instruct-abliterated-v1-8bit",
            "mlx-community/Qwen2.5-Coder-7B-Instruct-MLX",
        ]
        XCTAssertEqual(
            MLXVariantFinder.siblingIds(searchResult: hits, of: template).sorted(),
            [
                "mlx-community/Qwen2.5-Coder-7B-Instruct-8bit",
                "mlx-community/Qwen2.5-Coder-7B-Instruct-bf16",
            ]
        )
    }

    func testWeightBytesCountsOnlySafetensors() {
        let json = """
        {"siblings":[{"rfilename":"model-00001.safetensors","size":3000000000},
                     {"rfilename":"model-00002.safetensors","size":1000000000},
                     {"rfilename":"tokenizer.json","size":7000000},
                     {"rfilename":"README.md","size":900}]}
        """
        XCTAssertEqual(MLXVariantFinder.weightBytes(blobsJSON: Data(json.utf8)), 4_000_000_000)
        XCTAssertNil(MLXVariantFinder.weightBytes(blobsJSON: Data("{\"siblings\":[]}".utf8)))
        XCTAssertNil(MLXVariantFinder.weightBytes(blobsJSON: Data("nope".utf8)))
    }

    func testVariantCarriesTheModelsMetadataAndItsOwnSize() {
        let v = MLXVariantFinder.variant(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-8bit", weightBytes: 8_000_000_000, template: template
        )
        XCTAssertEqual(v.quantization, "8-bit")
        XCTAssertEqual(v.parameterCount, "7B")
        XCTAssertEqual(v.modelType, "qwen2")
        XCTAssertEqual(v.estimatedRAMGB, 8.7, accuracy: 0.05)
        XCTAssertEqual(v.sizeBytes, 8_000_000_000)
    }

    func testQuantizationLabelFromIds() {
        XCTAssertEqual(LocalMLXModel.quantizationLabel(fromId: "a/b-4bit"), "4-bit")
        XCTAssertEqual(LocalMLXModel.quantizationLabel(fromId: "a/b-8-bit"), "8-bit")
        XCTAssertEqual(LocalMLXModel.quantizationLabel(fromId: "a/b-bf16"), "bf16")
        XCTAssertNil(LocalMLXModel.quantizationLabel(fromId: "a/b"))
    }
}
