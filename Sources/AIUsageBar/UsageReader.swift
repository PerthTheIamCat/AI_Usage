import Foundation
import Security

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
        let cachedFiveHour = readAntigravityLimit(shortWindow: true)
        let cachedWeekly = readAntigravityLimit(shortWindow: false)
        let live = fetchAntigravityLimits()
        usage.fiveHour = live?.fiveHour ?? cachedFiveHour
        usage.weekly = live?.weekly ?? cachedWeekly
        usage.groups = live?.groups ?? []
        usage.accountEmail = live?.accountEmail
        usage.planName = live?.planName
        usage.weeklyHistory = recordWeeklyHistory(weekly: usage.weekly)
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

    /// Query Antigravity's loopback language server. The server uses a
    /// self-signed certificate and requires the CSRF token passed to its
    /// process, so this stays strictly local and never reads OAuth credentials.
    private struct AntigravityLiveData {
        var fiveHour: LimitWindow?
        var weekly: LimitWindow?
        var groups: [AntigravityQuotaGroup] = []
        var accountEmail: String?
        var planName: String?
    }

    private static func fetchAntigravityLimits() -> AntigravityLiveData? {
        var cloud: AntigravityLiveData?
        guard let servers = antigravityServers() else {
            return fetchAntigravityQuotaSummary()
        }
        let path = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
        for server in servers {
            for scheme in ["https", "http"] {
                guard let url = URL(string: "\(scheme)://127.0.0.1:\(server.port)\(path)") else { continue }
                var request = URLRequest(url: url, timeoutInterval: 3)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(server.csrf, forHTTPHeaderField: "x-codeium-csrf-token")
                request.httpBody = Data("{}".utf8)
                guard let data = localRequest(request, allowSelfSigned: scheme == "https"),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else { continue }

                let candidates = quotaCandidates(in: object)
                guard !candidates.isEmpty else { continue }
                var fiveHour: LimitWindow?
                var weekly: LimitWindow?
                for candidate in candidates {
                    let until = candidate.reset.timeIntervalSinceNow
                    let window = LimitWindow(
                        usedPercent: max(0, min(100, (1 - candidate.remaining) * 100)),
                        resetsAt: candidate.reset)
                    if until > 0 && until <= 12 * 3600 {
                        if fiveHour == nil || window.remainingPercent < fiveHour!.remainingPercent { fiveHour = window }
                    } else if until > 12 * 3600 {
                        if weekly == nil || window.remainingPercent < weekly!.remainingPercent { weekly = window }
                    }
                }
                cloud = AntigravityLiveData(
                    fiveHour: fiveHour,
                    weekly: weekly,
                    accountEmail: firstString(in: object, keys: ["email", "emailAddress"]),
                    planName: firstString(in: object, keys: ["planName", "tierName", "paidTier"]))
                break
            }
        }
        let summary = fetchAntigravityQuotaSummary()
        guard var cloud, let summary else { return cloud ?? summary }
        cloud.fiveHour = cloud.fiveHour ?? summary.fiveHour
        cloud.weekly = cloud.weekly ?? summary.weekly
        cloud.groups = summary.groups
        cloud.accountEmail = cloud.accountEmail ?? summary.accountEmail
        cloud.planName = cloud.planName ?? summary.planName
        return cloud
    }

    /// The local language server exposes model/5-hour quota, while the weekly
    /// account bucket is returned by Google's quota-summary endpoint. The CLI
    /// stores the OAuth credential in the macOS Keychain under service
    /// `gemini`, account `antigravity`; read it without persisting or logging
    /// the token.
    private static func fetchAntigravityQuotaSummary() -> AntigravityLiveData? {
        guard let token = antigravityAccessToken() else {
            appLog("antigravity: weekly quota skipped — keychain token unavailable")
            return nil
        }
        let base = "https://daily-cloudcode-pa.googleapis.com"
        guard let loadURL = URL(string: base + "/v1internal:loadCodeAssist") else { return nil }
        var load = URLRequest(url: loadURL, timeoutInterval: 5)
        load.httpMethod = "POST"
        load.setValue("application/json", forHTTPHeaderField: "Content-Type")
        load.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        load.setValue("antigravity/cli", forHTTPHeaderField: "User-Agent")
        load.httpBody = Data(#"{"metadata":{"ideType":"ANTIGRAVITY"}}"#.utf8)
        guard let loadData = localRequest(load, allowSelfSigned: false),
              let loadObject = try? JSONSerialization.jsonObject(with: loadData),
              let project = jsonString(in: loadObject, key: "cloudaicompanionProject")
        else {
            appLog("antigravity: weekly quota skipped — loadCodeAssist failed")
            return nil
        }

        guard let summaryURL = URL(string: base + "/v1internal:retrieveUserQuotaSummary") else { return nil }
        var summary = URLRequest(url: summaryURL, timeoutInterval: 5)
        summary.httpMethod = "POST"
        summary.setValue("application/json", forHTTPHeaderField: "Content-Type")
        summary.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        summary.setValue("antigravity/cli", forHTTPHeaderField: "User-Agent")
        let body = ["project": project]
        summary.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let summaryData = localRequest(summary, allowSelfSigned: false),
              let object = try? JSONSerialization.jsonObject(with: summaryData)
        else {
            appLog("antigravity: weekly quota skipped — retrieveUserQuotaSummary failed")
            return nil
        }

        var fiveHour: LimitWindow?
        var weekly: LimitWindow?
        for candidate in quotaCandidates(in: object) {
            let until = candidate.reset.timeIntervalSinceNow
            let window = LimitWindow(
                usedPercent: max(0, min(100, (1 - candidate.remaining) * 100)),
                resetsAt: candidate.reset)
            if until > 0 && until <= 12 * 3600 {
                if fiveHour == nil || window.remainingPercent < fiveHour!.remainingPercent { fiveHour = window }
            } else if until > 12 * 3600 {
                if weekly == nil || window.remainingPercent < weekly!.remainingPercent { weekly = window }
            }
        }
        let groups = quotaGroups(in: object)
        appLog("antigravity: quota summary parsed — 5h=\(fiveHour != nil) weekly=\(weekly != nil)")
        return AntigravityLiveData(
            fiveHour: fiveHour,
            weekly: weekly,
            groups: groups,
            accountEmail: firstString(in: loadObject, keys: ["email", "emailAddress"]),
            planName: firstString(in: loadObject, keys: ["planName", "tierName", "paidTier"]))
    }

    private static func quotaGroups(in value: Any) -> [AntigravityQuotaGroup] {
        guard let root = value as? [String: Any],
              let rawGroups = root["groups"] as? [[String: Any]] else { return [] }
        return rawGroups.compactMap { group in
            let name = group["displayName"] as? String ?? "Other models"
            var models = group["models"] as? [String] ?? group["modelIds"] as? [String] ?? []
            if models.isEmpty, let description = group["description"] as? String,
               let separator = description.firstIndex(of: ":") {
                models = description[description.index(after: separator)...]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            var fiveHour: LimitWindow?
            var weekly: LimitWindow?
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let fraction = number(in: bucket, key: "remainingFraction"),
                      let resetText = bucket["resetTime"] as? String,
                      let reset = parseISO(resetText) else { continue }
                let window = LimitWindow(usedPercent: max(0, min(100, (1 - fraction) * 100)), resetsAt: reset)
                let kind = ((bucket["window"] as? String) ?? (bucket["bucketId"] as? String) ?? "").lowercased()
                if kind.contains("week") { weekly = window }
                else if kind.contains("5h") || kind.contains("hour") { fiveHour = window }
            }
            guard fiveHour != nil || weekly != nil else { return nil }
            return AntigravityQuotaGroup(name: name, models: models, fiveHour: fiveHour, weekly: weekly)
        }
    }

    private static func number(in object: [String: Any], key: String) -> Double? {
        if let n = object[key] as? Double { return n }
        if let n = object[key] as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func firstString(in value: Any, keys: [String]) -> String? {
        for key in keys where jsonString(in: value, key: key) != nil {
            return jsonString(in: value, key: key)
        }
        return nil
    }

    private static func recordWeeklyHistory(weekly: LimitWindow?) -> [AntigravityQuotaHistoryPoint] {
        let key = "antigravityWeeklyQuotaHistory"
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        var history = (try? decoder.decode([AntigravityQuotaHistoryPoint].self, from: defaults.data(forKey: key) ?? Data())) ?? []
        if let weekly {
            let point = AntigravityQuotaHistoryPoint(date: Date(), weeklyRemaining: weekly.remainingPercent)
            if let index = history.indices.last, Date().timeIntervalSince(history[index].date) < 30 * 60 {
                history[index] = point
            } else {
                history.append(point)
            }
            history = history.filter { $0.date > Date().addingTimeInterval(-14 * 24 * 3600) }
            if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: key) }
        }
        return history
    }

    private static func antigravityAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var wrapped: String?
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            wrapped = String(data: data, encoding: .utf8)
        }
        if wrapped == nil {
            wrapped = commandOutput("/usr/bin/security", [
                "find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"
            ])?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let wrapped,
              wrapped.hasPrefix("go-keyring-base64:"),
              let decoded = Data(base64Encoded: String(wrapped.dropFirst("go-keyring-base64:".count))),
              let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let token = root["token"] as? [String: Any],
              let accessToken = token["access_token"] as? String,
              !accessToken.isEmpty
        else { return nil }
        return accessToken
    }

    private static func jsonString(in value: Any, key: String) -> String? {
        if let dict = value as? [String: Any] {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            for child in dict.values {
                if let found = jsonString(in: child, key: key) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = jsonString(in: child, key: key) { return found }
            }
        }
        return nil
    }

    private struct AntigravityServer {
        var port: Int
        var csrf: String
    }

    private static func antigravityServers() -> [AntigravityServer]? {
        guard let output = commandOutput("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else { return nil }
        var pid: String?
        var ports: [(pid: String, port: Int)] = []
        for line in output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = value
            case "n":
                if let port = Int(value.split(separator: ":").last ?? ""), let pid { ports.append((pid, port)) }
            default: break
            }
        }
        var servers: [AntigravityServer] = []
        for entry in ports {
            guard let args = commandOutput("/bin/ps", ["eww", "-p", entry.pid, "-o", "command="]) else { continue }
            let tokenPatterns = [
                #"GEMINI_CLI_IDE_AUTH_TOKEN=([^\s]+)"#,
                #"(?:--)?csrf[_-]token(?:=|\s+)([^\s]+)"#
            ]
            guard let pattern = tokenPatterns.first(where: { args.range(of: $0, options: .regularExpression) != nil }),
                  let match = args.range(of: pattern, options: .regularExpression)
            else { continue }
            var token = String(args[match])
            if let equals = token.firstIndex(of: "=") { token = String(token[token.index(after: equals)...]) }
            if !token.isEmpty { servers.append(AntigravityServer(port: entry.port, csrf: token)) }
        }
        return servers.isEmpty ? nil : servers
    }

    private static func commandOutput(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private final class LocalServerDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               challenge.protectionSpace.host == "127.0.0.1" {
                completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private static func localRequest(_ request: URLRequest, allowSelfSigned: Bool) -> Data? {
        let delegate = allowSelfSigned ? LocalServerDelegate() : nil
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    result = data
                    if request.url?.path.contains("retrieveUserQuotaSummary") == true {
                        appLog("antigravity: quota summary HTTP 200 (\(data?.count ?? 0) bytes)")
                    }
                } else if request.url?.path.contains("retrieveUserQuotaSummary") == true {
                    appLog("antigravity: quota summary HTTP \(http.statusCode)")
                }
            } else if request.url?.path.contains("retrieveUserQuotaSummary") == true {
                appLog("antigravity: quota summary returned no HTTP response")
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        session.invalidateAndCancel()
        return result
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
