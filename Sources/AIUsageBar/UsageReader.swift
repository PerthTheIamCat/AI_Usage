import Foundation

enum UsageReader {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")
    static let codexDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    static let antigravityDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli")

    /// - Parameter fetchClaudeLimits: when false, skips the Claude usage API
    ///   call (leaving `claudeLimits == nil`) so the caller can throttle that
    ///   endpoint independently of the cheap local token-count reads.
    static func snapshot(fetchClaudeLimits: Bool = true) -> UsageSnapshot {
        let fm = FileManager.default
        var snap = UsageSnapshot()
        if fm.fileExists(atPath: claudeDir.path) {
            snap.claude = readClaudeToday()
            if fetchClaudeLimits { snap.claudeLimits = ClaudeLimitsReader.fetch() }
        }
        if fm.fileExists(atPath: codexDir.path) {
            snap.codex = readCodexToday()
            snap.codexLimits = codexLimits()
        }
        if fm.fileExists(atPath: antigravityDir.path) {
            snap.antigravity = readAntigravityToday()
        }
        snap.hourlyUsage = readHourlyUsage()
        snap.updatedAt = Date()
        return snap
    }

    // MARK: - Shared helpers

    private static func localHour(_ date: Date) -> Int {
        Calendar.current.component(.hour, from: date)
    }

    private static func readHourlyUsage() -> HourlyUsage {
        var usage = HourlyUsage()

        // Claude assistant records contain the actual token usage for each
        // completed response.
        if FileManager.default.fileExists(atPath: claudeDir.path) {
            for file in filesModifiedToday(under: claudeDir, ext: "jsonl") {
                forEachLine(of: file) { line in
                    guard line.contains("\"usage\""), line.contains("\"assistant\""),
                          let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (obj["type"] as? String) == "assistant",
                          let ts = obj["timestamp"] as? String,
                          isTodayLocal(isoTimestamp: ts),
                          let message = obj["message"] as? [String: Any],
                          let tokenUsage = message["usage"] as? [String: Any],
                          let date = parseISO(ts)
                    else { return }
                    let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                        .reduce(0) { $0 + ((tokenUsage[$1] as? Int) ?? 0) }
                    usage.values[localHour(date)] += tokens
                }
            }
        }

        // Codex token_count events are cumulative per session; add only the
        // delta between consecutive readings to avoid counting the same turn
        // repeatedly.
        if FileManager.default.fileExists(atPath: codexDir.path) {
            for file in filesModifiedToday(under: codexDir, ext: "jsonl") {
                var previous = 0
                forEachLine(of: file) { line in
                    guard line.contains("\"token_count\""),
                          let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ts = obj["timestamp"] as? String,
                          isTodayLocal(isoTimestamp: ts),
                          let payload = obj["payload"] as? [String: Any],
                          (payload["type"] as? String) == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let totals = info["total_token_usage"] as? [String: Any],
                          let total = totals["total_tokens"] as? Int,
                          let date = parseISO(ts)
                    else { return }
                    let delta = max(0, total - previous)
                    usage.values[localHour(date)] += delta
                    previous = max(previous, total)
                }
            }
        }

        if FileManager.default.fileExists(atPath: antigravityDir.path) {
            let historyFile = antigravityDir.appendingPathComponent("history.jsonl")
            forEachLine(of: historyFile) { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestampMS = obj["timestamp"] as? Double
                else { return }
                let date = Date(timeIntervalSince1970: timestampMS / 1000.0)
                if Calendar.current.isDateInToday(date) { usage.values[localHour(date)] += 1 }
            }
        }
        return usage
    }

    private static func filesModifiedToday(under root: URL, ext: String) -> [URL] {
        let fm = FileManager.default
        let startOfDay = Calendar.current.startOfDay(for: Date())
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            guard url.pathExtension == ext,
                  let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  vals.isRegularFile == true,
                  let mtime = vals.contentModificationDate,
                  mtime >= startOfDay
            else { continue }
            out.append(url)
        }
        return out
    }

    private static func forEachLine(of url: URL, _ body: (String) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8)
        else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            body(String(line))
        }
    }

    private static let todayPrefixesUTC: [String] = {
        // Local "today" can span two UTC dates; timestamps in logs are UTC.
        let fmt = DateFormatter()
        // Log timestamps are Gregorian; the device locale may use another
        // calendar (e.g. Thai Buddhist year 2569), so pin the formatter.
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(24 * 3600 - 1)
        return Array(Set([fmt.string(from: start), fmt.string(from: end)]))
    }()

    private static func isTodayLocal(isoTimestamp: String) -> Bool {
        guard todayPrefixesUTC.contains(where: { isoTimestamp.hasPrefix($0) }) else { return false }
        guard let date = parseISO(isoTimestamp) else { return false }
        return Calendar.current.isDateInToday(date)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseISO(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - Claude Code

    private static func readClaudeToday() -> ClaudeUsage {
        var usage = ClaudeUsage()
        // Dedupe streamed/rewritten entries: same request may appear multiple
        // times; keep the last occurrence per key.
        var perKey: [String: (input: Int, output: Int, cacheW: Int, cacheR: Int, model: String?, ts: String)] = [:]
        var sessions = Set<String>()

        for file in filesModifiedToday(under: claudeDir, ext: "jsonl") {
            var fileHasToday = false
            forEachLine(of: file) { line in
                guard line.contains("\"usage\""), line.contains("\"assistant\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let ts = obj["timestamp"] as? String,
                      isTodayLocal(isoTimestamp: ts),
                      let message = obj["message"] as? [String: Any],
                      let u = message["usage"] as? [String: Any]
                else { return }
                fileHasToday = true
                let key = (obj["requestId"] as? String)
                    ?? (message["id"] as? String)
                    ?? (obj["uuid"] as? String)
                    ?? UUID().uuidString
                perKey[key] = (
                    input: u["input_tokens"] as? Int ?? 0,
                    output: u["output_tokens"] as? Int ?? 0,
                    cacheW: u["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheR: u["cache_read_input_tokens"] as? Int ?? 0,
                    model: message["model"] as? String,
                    ts: ts
                )
            }
            if fileHasToday { sessions.insert(file.path) }
        }

        var latestTS = ""
        for (_, e) in perKey {
            usage.inputTokens += e.input
            usage.outputTokens += e.output
            usage.cacheCreationTokens += e.cacheW
            usage.cacheReadTokens += e.cacheR
            let model = e.model ?? "unknown"
            var m = usage.perModel[model] ?? ModelTokens()
            m.input += e.input
            m.output += e.output
            m.cacheWrite += e.cacheW
            m.cacheRead += e.cacheR
            usage.perModel[model] = m
            if e.ts > latestTS, let m = e.model {
                latestTS = e.ts
                usage.lastModel = m
            }
        }
        usage.sessionCount = sessions.count
        return usage
    }

    /// Newest account-wide rate-limit snapshot Codex wrote to any recent
    /// session log. The 5h/weekly windows are account-global, so the freshest
    /// reading across all sessions is what we want (not just today's).
    static func codexLimits() -> CodexLimits? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: codexDir.path) else { return nil }
        let cutoff = Date().addingTimeInterval(-8 * 24 * 3600)
        guard let en = fm.enumerator(
            at: codexDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl",
                  let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true, let m = v.contentModificationDate, m >= cutoff
            else { continue }
            files.append((url, m))
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }) {
            var found: [String: Any]?
            var foundTS: String?
            forEachLine(of: url) { line in
                guard line.contains("\"rate_limits\""), line.contains("\"token_count\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any]
                else { return }
                // Early events in a session carry null windows; keep only
                // readings that actually contain a populated window.
                guard rl["primary"] is [String: Any] || rl["secondary"] is [String: Any] else { return }
                found = rl  // keep last (newest) populated reading in file
                foundTS = obj["timestamp"] as? String
            }
            if let rl = found {
                var limits = parseCodexLimits(rl)
                limits.asOf = foundTS.flatMap(parseISO)
                return limits
            }
        }
        return nil
    }

    private static func parseCodexLimits(_ rl: [String: Any]) -> CodexLimits {
        var out = CodexLimits()
        out.planType = rl["plan_type"] as? String
        func window(_ key: String) -> (window: LimitWindow, minutes: Double)? {
            guard let d = rl[key] as? [String: Any],
                  let pct = (d["used_percent"] as? Double) ?? (d["used_percent"] as? Int).map(Double.init)
            else { return nil }
            let reset = (d["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (d["resets_at"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
            let minutes = (d["window_minutes"] as? Double)
                ?? (d["window_minutes"] as? Int).map(Double.init)
                ?? 0
            return (LimitWindow(usedPercent: pct, resetsAt: reset), minutes)
        }
        // Codex has changed which slot carries which window over time (the
        // 5-hour window was retired and weekly moved into "primary"), so
        // classify by window length instead of slot name: anything a day or
        // longer is the weekly limit, shorter ones are the session limit.
        for parsed in [window("primary"), window("secondary")].compactMap({ $0 }) {
            if parsed.minutes >= 24 * 60 || parsed.minutes == 0 {
                out.secondary = parsed.window   // weekly
            } else {
                out.primary = parsed.window     // legacy 5-hour
            }
        }
        return out
    }

    // MARK: - Codex

    private static func readCodexToday() -> CodexUsage {
        var usage = CodexUsage()
        for file in filesModifiedToday(under: codexDir, ext: "jsonl") {
            // total_token_usage is cumulative per session; last event wins.
            var last: [String: Int]?
            var lastTS: String?
            forEachLine(of: file) { line in
                guard line.contains("\"token_count\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any]
                else { return }
                last = total.compactMapValues { $0 as? Int }
                lastTS = obj["timestamp"] as? String
            }
            guard let t = last, let ts = lastTS, isTodayLocal(isoTimestamp: ts) else { continue }
            usage.inputTokens += t["input_tokens"] ?? 0
            usage.cachedInputTokens += t["cached_input_tokens"] ?? 0
            usage.outputTokens += t["output_tokens"] ?? 0
            usage.reasoningTokens += t["reasoning_output_tokens"] ?? 0
            usage.totalTokens += t["total_tokens"] ?? 0
            usage.sessionCount += 1
        }
        return usage
    }

    private static func readAntigravityToday() -> AntigravityUsage {
        var usage = AntigravityUsage()
        let historyFile = antigravityDir.appendingPathComponent("history.jsonl")
        usage.fiveHour = readAntigravityLimit(shortWindow: true)
        usage.weekly = readAntigravityLimit(shortWindow: false)
        guard FileManager.default.fileExists(atPath: historyFile.path) else {
            usage.isWorking = antigravityIsWorking()
            return usage
        }
        var uniqueSessions = Set<String>()
        forEachLine(of: historyFile) { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestampMS = obj["timestamp"] as? Double
            else { return }
            let date = Date(timeIntervalSince1970: timestampMS / 1000.0)
            if Calendar.current.isDateInToday(date) {
                usage.totalPrompts += 1
                if let sessionID = obj["conversationId"] as? String {
                    uniqueSessions.insert(sessionID)
                }
            }
        }
        usage.sessionCount = uniqueSessions.count
        usage.isWorking = antigravityIsWorking()
        return usage
    }

    /// Antigravity stores quota responses in different cache locations across
    /// CLI versions. Read only JSON responses that contain the stable
    /// remainingFraction/resetTime pair, and classify the two windows by the
    /// time until reset (short = 5-hour, long = weekly).
    private static func readAntigravityLimit(shortWindow: Bool) -> LimitWindow? {
        let fm = FileManager.default
        let roots = [
            antigravityDir.appendingPathComponent("cache"),
            antigravityDir.appendingPathComponent("state"),
            antigravityDir
        ]
        var newest: (window: LimitWindow, modified: Date)?
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let url as URL in en {
                guard url.pathExtension == "json",
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                for candidate in quotaCandidates(in: object) {
                    let until = candidate.reset.timeIntervalSinceNow
                    let isShort = until > 0 && until <= 12 * 3600
                    guard isShort == shortWindow else { continue }
                    let window = LimitWindow(usedPercent: max(0, min(100, (1 - candidate.remaining) * 100)), resetsAt: candidate.reset)
                    if newest == nil || modified > newest!.modified { newest = (window, modified) }
                }
            }
        }
        return newest?.window
    }

    private static func quotaCandidates(in object: Any) -> [(remaining: Double, reset: Date)] {
        var result: [(Double, Date)] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let fraction = (dict["remainingFraction"] as? Double) ?? (dict["remainingFraction"] as? Int).map(Double.init),
                   let resetString = dict["resetTime"] as? String,
                   let reset = parseISO(resetString) ?? ISO8601DateFormatter().date(from: resetString),
                   fraction >= 0, fraction <= 1 {
                    result.append((fraction, reset))
                }
                dict.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        return result
    }

    private static func antigravityIsWorking() -> Bool {
        let logs = antigravityDir.appendingPathComponent("log")
        guard let files = try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles),
              let file = files.filter({ $0.pathExtension == "log" }).max(by: { modifiedDate($0) < modifiedDate($1) }),
              let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8)
        else { return false }
        let started = text.range(of: "Starting conversation update stream", options: .backwards)
            ?? text.range(of: "HandleUserInput called", options: .backwards)
        let finished = text.range(of: "Stream completed", options: .backwards)
            ?? text.range(of: "Stream goroutine exited", options: .backwards)
        return started != nil && (finished == nil || started!.lowerBound > finished!.lowerBound)
    }

    private static func modifiedDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
