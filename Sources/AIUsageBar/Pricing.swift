import Foundation

/// USD per million tokens for one model family.
struct TokenRates {
    var input: Double
    var output: Double
    var cacheWrite: Double  // 1.25x input (5-minute TTL)
    var cacheRead: Double   // 0.1x input

    init(input: Double, output: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = input * 1.25
        self.cacheRead = input * 0.1
    }
}

/// Published Claude API list prices (USD/MTok). The logs are subscription
/// usage, so this is the *equivalent* pay-as-you-go value, not a bill.
enum Pricing {
    // Ordered: first prefix match wins, so specific families come before
    // broader ones ("claude-opus-4-1" before "claude-opus").
    private static let claudeRates: [(prefix: String, rates: TokenRates)] = [
        ("claude-fable", TokenRates(input: 10, output: 50)),
        ("claude-mythos", TokenRates(input: 10, output: 50)),
        ("claude-opus-4-1", TokenRates(input: 15, output: 75)),
        ("claude-opus-4-2", TokenRates(input: 15, output: 75)),
        ("claude-opus-4-0", TokenRates(input: 15, output: 75)),
        ("claude-opus-4-20", TokenRates(input: 15, output: 75)),
        ("claude-3-opus", TokenRates(input: 15, output: 75)),
        ("claude-opus", TokenRates(input: 5, output: 25)),      // 4.5+
        ("claude-sonnet", TokenRates(input: 3, output: 15)),
        ("claude-3-7-sonnet", TokenRates(input: 3, output: 15)),
        ("claude-3-5-haiku", TokenRates(input: 0.8, output: 4)),
        ("claude-haiku", TokenRates(input: 1, output: 5)),
        ("claude-3-haiku", TokenRates(input: 0.25, output: 1.25)),
    ]

    /// Fallback for unrecognized model IDs — Sonnet-tier middle ground.
    private static let defaultClaudeRates = TokenRates(input: 3, output: 15)

    /// OpenAI GPT-5 list prices; Codex session logs don't record per-request
    /// models, so all Codex usage is priced at the gpt-5 rate.
    static let codexRates = (input: 1.25, cachedInput: 0.125, output: 10.0)

    /// Gemini list prices (USD/MTok) for Gemini 3.5 Flash and Pro
    static let geminiFlashRates = TokenRates(input: 0.075, output: 0.3)
    static let geminiProRates = TokenRates(input: 1.25, output: 5.0)

    /// ChatGPT/GPT-4o list prices (USD/MTok)
    static let gpt4oRates = TokenRates(input: 2.5, output: 10.0)

    /// Price Antigravity usage (we assume average prompt is 1.5K input, 800 output tokens on Gemini 3.5 Flash)
    static func antigravityCostUSD(_ usage: AntigravityUsage) -> Double {
        let inputTokens = usage.totalPrompts * 1500
        let outputTokens = usage.totalPrompts * 800
        return (Double(inputTokens) * geminiFlashRates.input + Double(outputTokens) * geminiFlashRates.output) / 1_000_000
    }

    static func claudeRates(model: String) -> TokenRates {
        for entry in claudeRates where model.hasPrefix(entry.prefix) {
            return entry.rates
        }
        return defaultClaudeRates
    }

    /// USD value of today's Claude usage, summed per model.
    static func claudeCostUSD(_ usage: ClaudeUsage) -> Double {
        guard !usage.perModel.isEmpty else {
            // No per-model breakdown (e.g. old snapshot) — price the totals
            // at the last-seen model's rate.
            let r = claudeRates(model: usage.lastModel ?? "")
            return cost(input: usage.inputTokens, output: usage.outputTokens,
                        cacheW: usage.cacheCreationTokens, cacheR: usage.cacheReadTokens, rates: r)
        }
        return usage.perModel.reduce(0) { sum, entry in
            let r = claudeRates(model: entry.key)
            return sum + cost(input: entry.value.input, output: entry.value.output,
                              cacheW: entry.value.cacheWrite, cacheR: entry.value.cacheRead, rates: r)
        }
    }

    /// USD value of a single model's token slice, for the per-model breakdown
    /// rows in the dropdown.
    static func claudeModelCostUSD(_ tokens: ModelTokens, model: String) -> Double {
        let r = claudeRates(model: model)
        return cost(input: tokens.input, output: tokens.output,
                    cacheW: tokens.cacheWrite, cacheR: tokens.cacheRead, rates: r)
    }

    static func codexCostUSD(_ usage: CodexUsage) -> Double {
        let fresh = Double(max(0, usage.inputTokens - usage.cachedInputTokens))
        let cached = Double(usage.cachedInputTokens)
        let out = Double(usage.outputTokens)  // includes reasoning tokens
        return (fresh * codexRates.input + cached * codexRates.cachedInput + out * codexRates.output) / 1_000_000
    }

    /// % of prompt-input-equivalent tokens served from cache rather than
    /// fresh — a rough savings signal, not billed separately from the rows
    /// it's derived from.
    static func claudeCacheHitRatePercent(_ usage: ClaudeUsage) -> Double {
        let total = usage.inputTokens + usage.cacheReadTokens
        guard total > 0 else { return 0 }
        return Double(usage.cacheReadTokens) / Double(total) * 100
    }

    /// Codex's `inputTokens` already includes `cachedInputTokens` (see the
    /// `fresh = inputTokens - cachedInputTokens` subtraction in `codexCostUSD`).
    static func codexCacheHitRatePercent(_ usage: CodexUsage) -> Double {
        guard usage.inputTokens > 0 else { return 0 }
        return Double(usage.cachedInputTokens) / Double(usage.inputTokens) * 100
    }

    private static func cost(input: Int, output: Int, cacheW: Int, cacheR: Int, rates r: TokenRates) -> Double {
        (Double(input) * r.input + Double(output) * r.output
            + Double(cacheW) * r.cacheWrite + Double(cacheR) * r.cacheRead) / 1_000_000
    }
}

/// "$0.386" / "$12.34" — 3 decimals under a dollar so small spends stay visible.
func formatUSD(_ v: Double) -> String {
    v < 1 ? String(format: "$%.3f", v) : String(format: "$%.2f", v)
}

/// "฿12.34" at the user-configured exchange rate.
func formatTHB(_ usd: Double) -> String {
    let thb = usd * AppSettings.shared.thbPerUSD
    return thb < 1 ? String(format: "฿%.3f", thb) : String(format: "฿%.2f", thb)
}
