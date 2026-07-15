import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle owns the updater lifecycle and keeps its menu action enabled only
    // when the app is in a state that can check for updates.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var animationTimer: Timer?
    private var animationPhase: CGFloat = 0
    private let refreshInterval: TimeInterval = 60
    // Last successful Claude limits, reused between limit polls and when a
    // poll is rate-limited (429) so the display holds steady. Persisted to
    // UserDefaults so a relaunch still has data while the first fetch runs
    // (or is rate limited).
    private var lastGoodClaude: ClaudeLimits? {
        didSet { persistLastGoodClaude() }
    }
    // The usage API rate-limits aggressively, so poll it far less often than
    // the (free, local) token counts, and back off further on 429.
    private var nextClaudeFetch = Date.distantPast
    private let claudePollOK: TimeInterval = 300
    private let claudePollBackoff: TimeInterval = 600
    private var manualRefresh = false
    // A limits fetch can block for a long time on the keychain-permission
    // dialog; never start a second one while the first is still out, or every
    // 60s tick stacks another password prompt behind the dialog.
    private var limitsFetchInFlight = false
    // Server-imposed 429 window. Nothing may fetch before it — not even ⌘R —
    // and it persists across relaunches so a restart doesn't burn another hit.
    private static let rateLimitedUntilKey = "claudeRateLimitedUntil"
    private var rateLimitedUntil: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.rateLimitedUntilKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.rateLimitedUntilKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.rateLimitedUntilKey)
            }
        }
    }
    // Last applied snapshot, re-rendered instantly when a setting changes.
    private var lastSnapshot: UsageSnapshot?
    // When the periodic refresh timer next fires, for the countdown ring.
    private var nextRefreshAt = Date()

    private static let appVersion: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short else { return "dev" }
        return build.map { "\(short) (\($0))" } ?? short
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("app launched v\(Self.appVersion)")
        restoreLastGoodClaude()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        statusItem.menu = NSMenu()

        refresh()
        // .common mode so the periodic refresh keeps firing while the menu is
        // open (menu tracking suspends default-mode timers).
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let animation = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, self.lastSnapshot?.antigravity?.isWorking == true else { return }
            self.animationPhase += 0.08
            self.updateStatusBarTitle(self.lastSnapshot!)
        }
        RunLoop.main.add(animation, forMode: .common)
        animationTimer = animation

        NotificationCenter.default.addObserver(
            forName: .usageSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let snap = self.lastSnapshot else { return }
            self.apply(snap)
        }
    }

    @objc private func refreshClicked() {
        manualRefresh = true   // force a limits fetch on explicit ⌘R
        refresh()
    }
    @objc private func settingsClicked() { SettingsWindowController.shared.show() }
    @objc private func quitClicked() { NSApp.terminate(nil) }

    private func refresh() {
        nextRefreshAt = Date().addingTimeInterval(refreshInterval)
        let inPenaltyBox = Date() < (rateLimitedUntil ?? .distantPast)
        let doLimits = (manualRefresh || Date() >= nextClaudeFetch)
            && !limitsFetchInFlight && !inPenaltyBox
        manualRefresh = false
        if doLimits { limitsFetchInFlight = true }
        DispatchQueue.global(qos: .utility).async {
            let snap = UsageReader.snapshot(fetchClaudeLimits: doLimits)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if doLimits {
                    self.limitsFetchInFlight = false
                    self.scheduleNextClaudeFetch(snap.claudeLimits)
                }
                self.apply(snap)
            }
        }
    }

    private func scheduleNextClaudeFetch(_ limits: ClaudeLimits?) {
        let delay: TimeInterval
        if case .rateLimited(let retryAfter)? = limits?.state {
            // Honor the server's Retry-After (plus a buffer) — polling sooner
            // just burns more 429s.
            delay = max(claudePollBackoff, (retryAfter ?? 0) + 15)
            rateLimitedUntil = Date().addingTimeInterval(delay)
            appLog("claude: backing off — next limits fetch in \(Int(delay))s")
        } else if case .stale? = limits?.state {
            // Token expired: the CLI will write a fresh one to the keychain on
            // its next refresh cycle. Recheck every poll tick so the display
            // recovers within a minute instead of five. We never refresh the
            // token ourselves — refresh tokens are single-use, and racing the
            // CLI for one would log the user out of Claude Code.
            delay = refreshInterval
            rateLimitedUntil = nil
        } else {
            delay = claudePollOK
            rateLimitedUntil = nil
        }
        nextClaudeFetch = Date().addingTimeInterval(delay)
    }

    // MARK: - Limits persistence

    private struct StoredLimits: Codable {
        var fiveHourUsed: Double?
        var fiveHourReset: Date?
        var sevenDayUsed: Double?
        var sevenDayReset: Date?
        var fetchedAt: Date
    }

    private static let storedLimitsKey = "lastGoodClaudeLimits"

    private func persistLastGoodClaude() {
        guard let l = lastGoodClaude, let at = l.fetchedAt else { return }
        let stored = StoredLimits(
            fiveHourUsed: l.fiveHour?.usedPercent, fiveHourReset: l.fiveHour?.resetsAt,
            sevenDayUsed: l.sevenDay?.usedPercent, sevenDayReset: l.sevenDay?.resetsAt,
            fetchedAt: at)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storedLimitsKey)
        }
    }

    private func restoreLastGoodClaude() {
        guard let data = UserDefaults.standard.data(forKey: Self.storedLimitsKey),
              let stored = try? JSONDecoder().decode(StoredLimits.self, from: data),
              // Older than the weekly window is stale beyond usefulness.
              stored.fetchedAt > Date().addingTimeInterval(-8 * 24 * 3600)
        else { return }
        var limits = ClaudeLimits()
        limits.state = .ok
        limits.fetchedAt = stored.fetchedAt
        if let used = stored.fiveHourUsed {
            limits.fiveHour = LimitWindow(usedPercent: used, resetsAt: stored.fiveHourReset)
        }
        if let used = stored.sevenDayUsed {
            limits.sevenDay = LimitWindow(usedPercent: used, resetsAt: stored.sevenDayReset)
        }
        lastGoodClaude = limits
        appLog("claude: restored cached limits from \(humanAgo(stored.fetchedAt))")
    }

    private func apply(_ snap: UsageSnapshot) {
        lastSnapshot = snap
        var snap = snap
        // Cache good readings; reuse the last good one when this tick skipped
        // the fetch (nil) or failed, so the display holds steady. A failure
        // is still surfaced as a status note so the user knows what happened.
        var claudeAPIProblem: String?
        if let cl = snap.claudeLimits {
            switch cl.state {
            case .ok:
                lastGoodClaude = cl
            case .rateLimited(let retryAfter):
                claudeAPIProblem = "Usage API rate limited (HTTP 429)"
                if let retryAfter {
                    claudeAPIProblem! += " · retry in \(humanDuration(retryAfter))"
                }
                if let cached = lastGoodClaude { snap.claudeLimits = cached }
            case .error(let m):
                claudeAPIProblem = "Usage API failed: \(m)"
                if let cached = lastGoodClaude { snap.claudeLimits = cached }
            case .stale, .notLoggedIn:
                break
            }
        } else if snap.claude != nil {
            snap.claudeLimits = lastGoodClaude
            if let until = rateLimitedUntil, until > Date() {
                claudeAPIProblem = "Usage API rate limited (HTTP 429) · retry in \(humanDuration(until.timeIntervalSinceNow))"
            }
        }

        // Menu-bar title prefers the tightest (lowest-remaining) live limit;
        // falls back to today's token total when limits are unavailable.
        // Rendered attributed: real brand glyphs, monospaced digits so the
        // title width stays steady, and a segment turns red when a limit runs
        // low.
        updateStatusBarTitle(snap)

        let menu = NSMenu()

        if let c = snap.claude {
            menu.addItem(headerItem("Claude Code", icon: BrandIcons.claude, iconTint: BrandIcons.claudeBrandColor))
            if let problem = claudeAPIProblem {
                var text = "⚠︎ \(problem)"
                if let goodAt = lastGoodClaude?.fetchedAt {
                    text += " · showing data from \(humanAgo(goodAt))"
                }
                menu.addItem(note(text))
            }
            addClaudeLimits(menu, snap.claudeLimits)
            menu.addItem(caption("Today's tokens"))
            menu.addItem(statPairItem("Total", formatTokens(c.total), "Sessions", "\(c.sessionCount)"))
            menu.addItem(statPairItem("Input", formatTokens(c.inputTokens), "Output", formatTokens(c.outputTokens)))
            menu.addItem(statPairItem("Cache write", formatTokens(c.cacheCreationTokens), "Cache read", formatTokens(c.cacheReadTokens)))
            if let m = c.lastModel { menu.addItem(row("Last model", m)) }
            let usd = Pricing.claudeCostUSD(c)
            menu.addItem(row("Est. cost", "\(formatTHB(usd)) · \(formatUSD(usd))"))
            menu.addItem(.separator())
        }

        if let x = snap.codex {
            var title = "Codex"
            if let plan = snap.codexLimits?.planType { title += " (\(plan))" }
            menu.addItem(headerItem(title, icon: BrandIcons.codex))
            addCodexLimits(menu, snap.codexLimits)
            menu.addItem(caption("Today's tokens"))
            menu.addItem(statPairItem("Total", formatTokens(x.totalTokens), "Sessions", "\(x.sessionCount)"))
            menu.addItem(statPairItem("Input", formatTokens(x.inputTokens), "Cached in", formatTokens(x.cachedInputTokens)))
            menu.addItem(statPairItem("Output", formatTokens(x.outputTokens), "Reasoning", formatTokens(x.reasoningTokens)))
            let usd = Pricing.codexCostUSD(x)
            menu.addItem(row("Est. cost", "\(formatTHB(usd)) · \(formatUSD(usd))"))
            menu.addItem(.separator())
        }

        if let g = snap.antigravity {
            menu.addItem(headerItem("Antigravity", icon: BrandIcons.gemini, iconTint: BrandIcons.geminiBrandColor))
            addAntigravityLimits(menu, g)
            menu.addItem(caption("Today's activity"))
            menu.addItem(statPairItem("Prompts", "\(g.totalPrompts)", "Sessions", "\(g.sessionCount)"))
            let usd = Pricing.antigravityCostUSD(g)
            menu.addItem(row("Est. cost", "\(formatTHB(usd)) · \(formatUSD(usd))"))
            menu.addItem(.separator())
        }

        if snap.claude == nil && snap.codex == nil && snap.antigravity == nil {
            menu.addItem(header("No AI CLI detected"))
            menu.addItem(note("Looked for ~/.claude, ~/.codex and ~/.gemini"))
            menu.addItem(.separator())
        }

        menu.addItem(caption("Analytics · Today"))
        if let peak = snap.hourlyUsage.peakHour {
            menu.addItem(note("Peak activity: \(String(format: "%02d:00", peak)) · \(formatTokens(snap.hourlyUsage.values[peak])) units"))
        }
        menu.addItem(hourlyUsageChartItem(snap.hourlyUsage))
        menu.addItem(.separator())

        menu.addItem(refreshCountdownItem(
            updatedAt: snap.updatedAt, nextFire: nextRefreshAt, interval: refreshInterval))
        menu.addItem(note("AI Usage Bar v\(Self.appVersion)"))

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit AI Usage Bar", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateStatusBarTitle(_ snap: UsageSnapshot) {
        let warnBelow = AppSettings.shared.warnBelowRemaining
        var parts: [(icon: NSImage, text: String, warning: Bool)] = []
        if snap.claude != nil { let low = lowestClaudeRemaining(snap); parts.append((BrandIcons.claude, claudeTitleValue(snap), (low ?? 100) < warnBelow)) }
        if let x = snap.codex { if let v = codexTitleValue(snap) { parts.append((BrandIcons.codex, v.text, v.remaining < warnBelow)) } else { parts.append((BrandIcons.codex, formatTokens(x.totalTokens), false)) } }
        if let g = snap.antigravity {
            let windows = [g.fiveHour, g.weekly].compactMap { $0 }
            let icon = g.isWorking ? BrandIcons.rotated(BrandIcons.gemini, angle: animationPhase) : BrandIcons.gemini
            if let remaining = windows.map(\.remainingPercent).min() {
                parts.append((icon, AppSettings.shared.displayMode.shortText(remaining: remaining), remaining < warnBelow))
            } else {
                parts.append((icon, "\(g.totalPrompts)P", false))
            }
        }
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let title = NSMutableAttributedString()
        for part in parts { if title.length > 0 { title.append(NSAttributedString(string: "   ", attributes: [.font: font])) }; let color: NSColor = part.warning ? .systemRed : .labelColor; title.append(BrandIcons.attachment(part.icon, font: font, color: color)); title.append(NSAttributedString(string: " " + part.text, attributes: [.font: font, .foregroundColor: color])) }
        button.attributedTitle = title.length == 0 ? NSAttributedString(string: "AI —", attributes: [.font: font]) : title
    }

    private func addAntigravityLimits(_ menu: NSMenu, _ usage: AntigravityUsage) {
        if let fiveHour = usage.fiveHour { menu.addItem(limitRowItem(name: "5-hour", window: fiveHour)) }
        if let weekly = usage.weekly { menu.addItem(limitRowItem(name: "Weekly", window: weekly)) }
        if usage.fiveHour == nil && usage.weekly == nil { menu.addItem(note("No quota data yet — use Antigravity once to refresh it")) }
    }

    // MARK: - Limit rendering

    private func claudeTitleValue(_ snap: UsageSnapshot) -> String {
        guard let l = snap.claudeLimits else { return "—" }
        switch l.state {
        case .ok:
            if let low = lowestClaudeRemaining(snap) {
                return AppSettings.shared.displayMode.shortText(remaining: low)
            }
            // Both windows hidden from the menu bar — fall back to tokens.
            if let c = snap.claude { return formatTokens(c.total) }
            return "—"
        case .stale: return "login"
        case .rateLimited: return "…"
        case .notLoggedIn: return "—"
        case .error: return "!"
        }
    }

    /// Lowest remaining % across the Claude windows the user chose to show in
    /// the menu bar; nil when limits are absent or both windows are hidden.
    private func lowestClaudeRemaining(_ snap: UsageSnapshot) -> Double? {
        guard let l = snap.claudeLimits, case .ok = l.state else { return nil }
        let s = AppSettings.shared
        var values: [Double] = []
        if s.showFiveHourInMenuBar, let w = l.fiveHour { values.append(w.remainingPercent) }
        if s.showWeeklyInMenuBar, let w = l.sevenDay { values.append(w.remainingPercent) }
        return values.min()
    }

    private func addClaudeLimits(_ menu: NSMenu, _ limits: ClaudeLimits?) {
        guard let l = limits else { return }
        switch l.state {
        case .ok:
            windowRows(menu, "5-hour", l.fiveHour)
            windowRows(menu, "Weekly", l.sevenDay)
        case .rateLimited, .error:
            // Cause already shown by the ⚠︎ status note; nothing cached to draw.
            menu.addItem(note("No limit data to show yet — retrying next refresh"))
        case .stale:
            menu.addItem(note("Login expired — run `claude` to sign in"))
        case .notLoggedIn:
            menu.addItem(note("Not logged in to Claude Code"))
        }
    }

    /// Codex has no live API here — the reading is whatever the last Codex
    /// session logged. Weekly window only; Codex retired its 5-hour window.
    /// Returns nil when even that is missing.
    private func codexTitleValue(_ snap: UsageSnapshot) -> (text: String, remaining: Double)? {
        guard let l = snap.codexLimits else { return nil }
        if let s = l.secondary, !isExpired(s) {
            return (AppSettings.shared.displayMode.shortText(remaining: s.remainingPercent), s.remainingPercent)
        }
        return nil
    }

    private func addCodexLimits(_ menu: NSMenu, _ limits: CodexLimits?) {
        guard let l = limits else {
            menu.addItem(note("No limit data yet — run codex once"))
            return
        }
        menu.addItem(caption("Limits · as of \(humanAgo(l.asOf))"))
        windowRows(menu, "Weekly", l.secondary)
    }

    private func isExpired(_ w: LimitWindow) -> Bool {
        if let r = w.resetsAt { return r <= Date() }
        return false
    }

    private func windowRows(_ menu: NSMenu, _ name: String, _ w: LimitWindow?) {
        guard let w = w else { return }
        if isExpired(w) {
            // Window already rolled over; the stored percent is meaningless now.
            menu.addItem(note("\(name): window reset — reopen CLI for fresh reading"))
            return
        }
        menu.addItem(limitRowItem(name: name, window: w))
    }

    // Thin wrappers over the MenuViews factories keep apply() readable.
    private func header(_ title: String) -> NSMenuItem { headerItem(title) }
    private func caption(_ title: String) -> NSMenuItem { captionItem(title) }
    private func note(_ text: String) -> NSMenuItem { noteItem(text) }
    private func row(_ label: String, _ value: String) -> NSMenuItem { statRowItem(label, value) }
}

if CommandLine.arguments.contains("--dump") {
    let snap = UsageReader.snapshot()
    if let c = snap.claude {
        print("Claude: total=\(formatTokens(c.total)) in=\(c.inputTokens) out=\(c.outputTokens) cacheW=\(c.cacheCreationTokens) cacheR=\(c.cacheReadTokens) sessions=\(c.sessionCount) model=\(c.lastModel ?? "-")")
    } else {
        print("Claude: not detected")
    }
    if let l = snap.claudeLimits {
        func w(_ n: String, _ x: LimitWindow?) -> String {
            guard let x = x else { return "\(n)=n/a" }
            return "\(n)=\(Int(x.remainingPercent))% left (resets \(humanReset(x.resetsAt)))"
        }
        switch l.state {
        case .ok: print("Claude limits: \(w("5h", l.fiveHour))  \(w("weekly", l.sevenDay))")
        case .rateLimited: print("Claude limits: rate limited (429) — retry later")
        case .stale: print("Claude limits: login expired (run claude to sign in)")
        case .notLoggedIn: print("Claude limits: not logged in")
        case .error(let m): print("Claude limits: error \(m)")
        }
    }
    if let x = snap.codex {
        print("Codex: total=\(formatTokens(x.totalTokens)) in=\(x.inputTokens) cached=\(x.cachedInputTokens) out=\(x.outputTokens) reasoning=\(x.reasoningTokens) sessions=\(x.sessionCount)")
    } else {
        print("Codex: not detected")
    }
    if let l = snap.codexLimits {
        func w(_ n: String, _ x: LimitWindow?) -> String {
            guard let x = x else { return "\(n)=n/a" }
            if let r = x.resetsAt, r <= Date() { return "\(n)=window reset (stale)" }
            return "\(n)=\(Int(x.remainingPercent))% left (resets \(humanReset(x.resetsAt)))"
        }
        print("Codex limits (as of \(humanAgo(l.asOf))): \(w("weekly", l.secondary))")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
