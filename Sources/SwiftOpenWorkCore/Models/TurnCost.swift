import Foundation

/// What a turn has cost so far, priced from the model's own per-1k rates.
///
/// A token budget is a proxy: a million tokens is cheap on one model and expensive on another.
/// A spend limit says what the person actually minds. A model with no price (anything local) costs
/// nothing, so a dollar limit never halts a local turn.
public enum TurnCost {
    public static func usd(model: ModelInfo, promptTokens: Int, completionTokens: Int) -> Double {
        Double(max(0, promptTokens)) / 1000 * model.costPer1kPrompt
            + Double(max(0, completionTokens)) / 1000 * model.costPer1kCompletion
    }

    /// `$0.42`, or `$0.0031` for amounts under a cent.
    public static func format(_ usd: Double) -> String {
        usd >= 0.01 ? String(format: "$%.2f", usd) : String(format: "$%.4f", usd)
    }

    public static func exceeds(limit: Double, spent: Double) -> Bool {
        limit > 0 && spent > limit
    }
}
