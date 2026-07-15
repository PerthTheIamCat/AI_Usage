import Foundation

/// Token counts for a single model, used for per-model cost pricing.
struct ModelTokens {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
}

struct ClaudeUsage {
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    var lastModel: String?
    /// Per-model breakdown of the same totals; keyed by model ID.
    var perModel: [String: ModelTokens] = [:]

    var total: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

struct CodexUsage {
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var totalTokens = 0
    var sessionCount = 0
}

struct AntigravityUsage {
    var totalPrompts = 0
    var sessionCount = 0
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?
    var isWorking = false
}

struct HourlyUsage {
    var values = Array(repeating: 0, count: 24)

    var total: Int { values.reduce(0, +) }
    var peakHour: Int? {
        guard let peak = values.max(), peak > 0 else { return nil }
        return values.firstIndex(of: peak)
    }
}

struct UsageSnapshot {
    var claude: ClaudeUsage?       // nil = not detected
    var codex: CodexUsage?         // nil = not detected
    var antigravity: AntigravityUsage? // nil = not detected
    var claudeLimits: ClaudeLimits?
    var codexLimits: CodexLimits?
    var hourlyUsage = HourlyUsage()
    var updatedAt = Date()
}

func formatTokens(_ n: Int) -> String {
    let v = Double(n)
    switch v {
    case ..<1_000: return "\(n)"
    case ..<1_000_000: return String(format: "%.1fK", v / 1_000)
    case ..<1_000_000_000: return String(format: "%.2fM", v / 1_000_000)
    default: return String(format: "%.2fB", v / 1_000_000_000)
    }
}
