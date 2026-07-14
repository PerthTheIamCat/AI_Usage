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
    private let refreshInterval: TimeInterval = 60
    // Last successful Claude limits, reused between limit polls and when a
    // poll is rate-limited (429) so the display holds steady.
    private var lastGoodClaude: ClaudeLimits?
    // The usage API rate-limits aggressively, so poll it far less often than
    // the (free, local) token counts, and back off further on 429.
    private var nextClaudeFetch = Date.distantPast
    private let claudePollOK: TimeInterval = 300
    private let claudePollBackoff: TimeInterval = 600
    private var manualRefresh = false
    // Last applied snapshot, re-rendered instantly when a setting changes.
    private var lastSnapshot: UsageSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        statusItem.menu = NSMenu()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }

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
        let doLimits = manualRefresh || Date() >= nextClaudeFetch
        manualRefresh = false
        DispatchQueue.global(qos: .utility).async {
            let snap = UsageReader.snapshot(fetchClaudeLimits: doLimits)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if doLimits { self.scheduleNextClaudeFetch(snap.claudeLimits) }
                self.apply(snap)
            }
        }
    }

    private func scheduleNextClaudeFetch(_ limits: ClaudeLimits?) {
        let delay: TimeInterval
        if case .rateLimited? = limits?.state { delay = claudePollBackoff }
        else { delay = claudePollOK }
        nextClaudeFetch = Date().addingTimeInterval(delay)
    }

    private func apply(_ snap: UsageSnapshot) {
        lastSnapshot = snap
        var snap = snap
        // Cache good readings; reuse the last good one when this tick skipped
        // the fetch (nil) or was rate-limited, so the display holds steady.
        if let cl = snap.claudeLimits {
            if case .ok = cl.state { lastGoodClaude = cl }
            else if case .rateLimited = cl.state, let cached = lastGoodClaude {
                snap.claudeLimits = cached
            }
        } else if snap.claude != nil {
            snap.claudeLimits = lastGoodClaude
        }

        // Menu-bar title prefers the tightest (lowest-remaining) live limit;
        // falls back to today's token total when limits are unavailable.
        // Rendered attributed: real brand glyphs, monospaced digits so the
        // title width stays steady, and a segment turns red when a limit runs
        // low.
        let warnBelow = AppSettings.shared.warnBelowRemaining
        var parts: [(icon: NSImage, text: String, warning: Bool)] = []
        if snap.claude != nil {
            let low = lowestClaudeRemaining(snap)
            parts.append((BrandIcons.claude, claudeTitleValue(snap), (low ?? 100) < warnBelow))
        }
        if snap.codex != nil {
            if let v = codexTitleValue(snap) {
                parts.append((BrandIcons.codex, v.text, v.remaining < warnBelow))
            } else if let x = snap.codex {
                parts.append((BrandIcons.codex, formatTokens(x.totalTokens), false))
            }
        }
        if let button = statusItem.button {
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            let title = NSMutableAttributedString()
            if parts.isEmpty {
                title.append(NSAttributedString(string: "AI —", attributes: [.font: font]))
            } else {
                for part in parts {
                    if title.length > 0 {
                        title.append(NSAttributedString(string: "   ", attributes: [.font: font]))
                    }
                    let color: NSColor = part.warning ? .systemRed : .labelColor
                    title.append(BrandIcons.attachment(part.icon, font: font, color: color))
                    title.append(NSAttributedString(string: " " + part.text, attributes: [
                        .font: font, .foregroundColor: color,
                    ]))
                }
            }
            button.attributedTitle = title
        }

        let menu = NSMenu()

        if let c = snap.claude {
            menu.addItem(headerItem("Claude Code", icon: BrandIcons.claude, iconTint: BrandIcons.claudeBrandColor))
            addClaudeLimits(menu, snap.claudeLimits)
            menu.addItem(caption("Today's tokens"))
            menu.addItem(row("Total", formatTokens(c.total)))
            menu.addItem(row("Input", formatTokens(c.inputTokens)))
            menu.addItem(row("Output", formatTokens(c.outputTokens)))
            menu.addItem(row("Cache write", formatTokens(c.cacheCreationTokens)))
            menu.addItem(row("Cache read", formatTokens(c.cacheReadTokens)))
            menu.addItem(row("Sessions", "\(c.sessionCount)"))
            if let m = c.lastModel { menu.addItem(row("Last model", m)) }
            menu.addItem(.separator())
        }

        if let x = snap.codex {
            var title = "Codex"
            if let plan = snap.codexLimits?.planType { title += " (\(plan))" }
            menu.addItem(headerItem(title, icon: BrandIcons.codex))
            addCodexLimits(menu, snap.codexLimits)
            menu.addItem(caption("Today's tokens"))
            menu.addItem(row("Total", formatTokens(x.totalTokens)))
            menu.addItem(row("Input", formatTokens(x.inputTokens)))
            menu.addItem(row("Cached input", formatTokens(x.cachedInputTokens)))
            menu.addItem(row("Output", formatTokens(x.outputTokens)))
            menu.addItem(row("Reasoning", formatTokens(x.reasoningTokens)))
            menu.addItem(row("Sessions", "\(x.sessionCount)"))
            menu.addItem(.separator())
        }

        if snap.claude == nil && snap.codex == nil {
            menu.addItem(header("No AI CLI detected"))
            menu.addItem(note("Looked for ~/.claude and ~/.codex"))
            menu.addItem(.separator())
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        menu.addItem(note("Updated \(fmt.string(from: snap.updatedAt)) · refreshes every \(Int(refreshInterval / 60))m"))

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

    // MARK: - Limit rendering

    private func claudeTitleValue(_ snap: UsageSnapshot) -> String {
        guard let l = snap.claudeLimits else { return "—" }
        switch l.state {
        case .ok:
            if let low = lowestClaudeRemaining(snap) {
                return AppSettings.shared.displayMode.shortText(remaining: low)
            }
            return "—"
        case .stale: return "login"
        case .rateLimited: return "…"
        case .notLoggedIn: return "—"
        case .error: return "!"
        }
    }

    /// Lowest remaining % across live Claude windows, nil when limits are absent.
    private func lowestClaudeRemaining(_ snap: UsageSnapshot) -> Double? {
        guard let l = snap.claudeLimits, case .ok = l.state else { return nil }
        return [l.fiveHour?.remainingPercent, l.sevenDay?.remainingPercent].compactMap { $0 }.min()
    }

    private func addClaudeLimits(_ menu: NSMenu, _ limits: ClaudeLimits?) {
        guard let l = limits else { return }
        switch l.state {
        case .ok:
            windowRows(menu, "5-hour", l.fiveHour)
            windowRows(menu, "Weekly", l.sevenDay)
        case .rateLimited:
            menu.addItem(note("Rate limited — retrying next refresh"))
        case .stale:
            menu.addItem(note("Login expired — run `claude` to sign in"))
        case .notLoggedIn:
            menu.addItem(note("Not logged in to Claude Code"))
        case .error(let m):
            menu.addItem(note("Limits unavailable: \(m)"))
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
