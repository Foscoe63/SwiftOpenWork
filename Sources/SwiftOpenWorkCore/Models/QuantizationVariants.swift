import Foundation

/// How a model fits in memory *right now*, which `ModelCompatibility` (a fixed share of physical
/// RAM) cannot say: a model that "runs well" on paper still fails to load if Xcode and a browser are
/// holding the memory.
public enum MLXMemoryFit: Sendable, Equatable {
    case fits
    /// Within the GPU budget on paper, but more than is free at the moment. Closing apps or
    /// unloading another model makes room.
    case needsFreeMemory(shortByGB: Double)
    /// Larger than the GPU memory budget the user set, though the machine could still hold it.
    case overBudget
    /// Larger than the machine can hold. Loading would swap itself to a halt or fail outright.
    case wontLoad

    public var willLikelyFail: Bool { self == .wontLoad }

    public var label: String {
        switch self {
        case .fits: return "Fits in memory"
        case .needsFreeMemory(let short): return String(format: "Free %.0f GB more first", max(1, short.rounded(.up)))
        case .overBudget: return "Over GPU budget"
        case .wontLoad: return "Won't fit on this Mac"
        }
    }
}

extension MLXMemoryBudget {
    /// Judge `requiredRAMGB` against the budget and what is free now. Pure, so the thresholds can
    /// be tested without depending on this machine.
    public static func fit(
        requiredRAMGB: Double,
        budgetRatio: Double = AppSettings.default.mlxGpuMemoryBudgetRatio,
        availableGB: Double,
        physicalGB: Double
    ) -> MLXMemoryFit {
        let ratio = clampedBudgetRatio(budgetRatio)
        if requiredRAMGB > physicalGB * 0.95 { return .wontLoad }
        if requiredRAMGB > physicalGB * ratio { return .overBudget }
        if requiredRAMGB > availableGB { return .needsFreeMemory(shortByGB: requiredRAMGB - availableGB) }
        return .fits
    }
}

extension LocalMLXModel {
    /// Bits per weight: 4 for "4-bit", 16 for "fp16"/"bf16". nil when it is not stated.
    public var quantizationBits: Int? {
        guard let q = quantization?.lowercased() else { return nil }
        if q.contains("bf16") || q.contains("fp16") { return 16 }
        if q.contains("fp8") { return 8 }
        if q.contains("fp4") { return 4 }
        if let digits = q.split(whereSeparator: { !$0.isNumber }).first, let bits = Int(digits) { return bits }
        return nil
    }

    /// "4-bit", "fp16" and so on, read from a repo id. nil when the id does not say.
    public static func quantizationLabel(fromId id: String) -> String? {
        let lower = id.lowercased()
        for bits in [8, 5, 4, 2, 3, 6] where lower.contains("\(bits)bit") || lower.contains("\(bits)-bit") {
            return "\(bits)-bit"
        }
        if lower.contains("mxfp8") { return "MXFP8" }
        if lower.contains("mxfp4") { return "MXFP4" }
        if lower.contains("bf16") { return "bf16" }
        if lower.contains("fp16") { return "fp16" }
        return nil
    }

    private static let quantizationTokens: Set<String> = [
        "2bit", "3bit", "4bit", "5bit", "6bit", "8bit", "bf16", "fp16", "mxfp4", "mxfp8", "nvfp4",
        "mlx", "dwq", "gguf", "q4", "q8", "awq",
    ]

    /// Same model at a different precision hashes to the same key: org, case and quantization
    /// words are dropped, so `mlx-community/Qwen3-8B-4bit` and `.../Qwen3-8B-8bit` group.
    public var variantGroupKey: String {
        let repo = id.split(separator: "/").last.map(String.init) ?? id
        let words = repo.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map(String.init)
            .filter { !Self.quantizationTokens.contains($0) && !Self.isBitsToken($0) }
        return words.joined(separator: "-")
    }

    private static func isBitsToken(_ word: String) -> Bool {
        // "4bit", "8-bit" splits to "8" + "bit"; both halves must go together.
        word == "bit" || word == "bits"
    }

    /// Models grouped by what they are, each group's variants ordered by precision (lowest bits
    /// first). Groups keep the order in which their first member appeared.
    public static func variantGroups(_ models: [LocalMLXModel]) -> [[LocalMLXModel]] {
        var order: [String] = []
        var buckets: [String: [LocalMLXModel]] = [:]
        for model in models {
            // A model whose key is empty is its own group rather than joining every other one.
            let key = model.variantGroupKey.isEmpty ? model.id : model.variantGroupKey
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(model)
        }
        return order.map { key in
            buckets[key]!.sorted { ($0.quantizationBits ?? Int.max) < ($1.quantizationBits ?? Int.max) }
        }
    }

    /// The variant to show first: the most precise one that fits in free memory, since quality is
    /// the reason to pick a larger quantization. When none fits, the smallest, as the best chance.
    /// A downloaded variant wins outright: it is the one already on disk.
    public static func recommendedVariant(
        in group: [LocalMLXModel],
        budgetRatio: Double,
        availableGB: Double,
        physicalGB: Double
    ) -> LocalMLXModel? {
        if let downloaded = group.first(where: \.isDownloaded) { return downloaded }
        let fitting = group.filter {
            MLXMemoryBudget.fit(requiredRAMGB: $0.estimatedRAMGB, budgetRatio: budgetRatio,
                                availableGB: availableGB, physicalGB: physicalGB) == .fits
        }
        if let best = fitting.max(by: { ($0.quantizationBits ?? 0) < ($1.quantizationBits ?? 0) }) { return best }
        return group.min(by: { $0.estimatedRAMGB < $1.estimatedRAMGB })
    }
}
