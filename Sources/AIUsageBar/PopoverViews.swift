import SwiftUI
import AppKit

// MARK: - NSViewRepresentable wrappers around the existing drawing code
// (MenuViews.swift) — reused as-is rather than reimplemented in SwiftUI.

private struct LimitBarRepresentable: NSViewRepresentable {
    let remainingPercent: Double
    func makeNSView(context: Context) -> LimitBarView {
        let v = LimitBarView()
        v.remainingPercent = remainingPercent
        return v
    }
    func updateNSView(_ nsView: LimitBarView, context: Context) {
        nsView.remainingPercent = remainingPercent
    }
}

private struct HourlyChartRepresentable: NSViewRepresentable {
    let usage: HourlyUsage
    func makeNSView(context: Context) -> HourlyUsageChartView { HourlyUsageChartView(usage: usage) }
    // HourlyUsageChartView's data is set once at init; the call site forces a
    // fresh instance via `.id(usage.values)` when the data actually changes.
    func updateNSView(_ nsView: HourlyUsageChartView, context: Context) {}
}

private struct RefreshCountdownRepresentable: NSViewRepresentable {
    let updatedAt: Date
    let nextFire: Date
    let interval: TimeInterval
    func makeNSView(context: Context) -> RefreshCountdownView {
        RefreshCountdownView(updatedAt: updatedAt, nextFire: nextFire, interval: interval)
    }
    // Same story as the chart above — call site uses `.id(nextFire)`.
    func updateNSView(_ nsView: RefreshCountdownView, context: Context) {}
}

// MARK: - Basic rows (SwiftUI equivalents of the old NSMenuItem factories)

struct CaptionText: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

struct NoteText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatRow: View {
    let name: String
    let value: String
    var body: some View {
        HStack {
            Text(name).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13, weight: .medium).monospacedDigit()).lineLimit(1)
        }
    }
}

/// Two independent label/value pairs side by side, matching the old
/// `statPairItem` layout: `label value    label value`.
struct StatPairRow: View {
    let name1: String
    let value1: String
    let name2: String?
    let value2: String?

    init(_ name1: String, _ value1: String, _ name2: String? = nil, _ value2: String? = nil) {
        self.name1 = name1; self.value1 = value1; self.name2 = name2; self.value2 = value2
    }

    var body: some View {
        HStack(spacing: 20) {
            StatRow(name: name1, value: value1).frame(maxWidth: .infinity)
            if let name2, let value2 {
                StatRow(name: name2, value: value2).frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        }
    }
}

struct PaneHeader: View {
    let title: String
    var icon: NSImage? = nil
    var iconTint: Color? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(iconTint ?? Color.primary)
            }
            Text(title).font(.system(size: 16, weight: .bold))
            Spacer()
        }
        .padding(.bottom, 2)
    }
}

struct LimitRow: View {
    let name: String
    let window: LimitWindow
    var body: some View {
        let remaining = window.remainingPercent
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(AppSettings.shared.displayMode.rowText(remaining: remaining))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: limitColor(remaining)))
            }
            LimitBarRepresentable(remainingPercent: remaining)
                .frame(height: 5)
            Text("resets in \(humanReset(window.resetsAt))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A limit window row, or a "window reset" note in its place once the
/// stored percentage has rolled past its reset time and is meaningless.
@ViewBuilder
func limitRowOrNote(_ name: String, _ w: LimitWindow) -> some View {
    if let r = w.resetsAt, r <= Date() {
        NoteText(text: "\(name): window reset — reopen CLI for fresh reading")
    } else {
        LimitRow(name: name, window: w)
    }
}

// MARK: - Provider panes

struct ClaudePane: View {
    let snap: UsageSnapshot
    let claudeAPIProblem: String?
    let lastGoodClaudeFetchedAt: Date?
    @ObservedObject private var settings = AppSettings.shared

    private var c: ClaudeUsage? { snap.claude }
    private var costUSD: Double { c.map(Pricing.claudeCostUSD) ?? 0 }

    private var problemText: String? {
        guard let problem = claudeAPIProblem else { return nil }
        var text = "⚠︎ \(problem)"
        if let goodAt = lastGoodClaudeFetchedAt {
            text += " · showing data from \(humanAgo(goodAt))"
        }
        return text
    }

    private var modelBreakdown: [(model: String, total: Int, costUSD: Double)] {
        guard let c else { return [] }
        return c.perModel
            .map { (model: $0.key,
                    total: $0.value.input + $0.value.output + $0.value.cacheWrite + $0.value.cacheRead,
                    costUSD: Pricing.claudeModelCostUSD($0.value, model: $0.key)) }
            .sorted { $0.costUSD > $1.costUSD }
    }

    private var skillBreakdown: [(skill: String, count: Int)] {
        guard let c else { return [] }
        return c.skillCounts.map { (skill: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let c {
                    PaneHeader(title: "Claude Code", icon: BrandIcons.claude, iconTint: Color(nsColor: BrandIcons.claudeBrandColor))
                    if let problemText { NoteText(text: problemText) }
                    claudeLimitsSection

                    CaptionText(title: "Today's tokens")
                    StatPairRow("Total", formatTokens(c.total), "Sessions", "\(c.sessionCount)")
                    StatPairRow("Input", formatTokens(c.inputTokens), "Output", formatTokens(c.outputTokens))
                    StatPairRow("Cache write", formatTokens(c.cacheCreationTokens), "Cache read", formatTokens(c.cacheReadTokens))

                    if settings.showCacheHitRate {
                        StatRow(name: "Cache hit rate", value: "\(Int(Pricing.claudeCacheHitRatePercent(c).rounded()))%")
                    }

                    if settings.showModelBreakdown && modelBreakdown.count > 1 {
                        CaptionText(title: "By model")
                        ForEach(modelBreakdown, id: \.model) { m in
                            StatRow(name: m.model, value: "\(formatTokens(m.total)) · \(formatUSD(m.costUSD))")
                        }
                    }

                    if settings.showSkillsUsed && !skillBreakdown.isEmpty {
                        CaptionText(title: "Skills used today")
                        ForEach(skillBreakdown, id: \.skill) { s in
                            StatRow(name: s.skill, value: "\(s.count)×")
                        }
                    }

                    if let m = c.lastModel {
                        StatRow(name: "Last model", value: m)
                    }

                    if settings.showAvgPerSession {
                        StatRow(name: "Avg/session",
                                value: "\(formatTokens(c.total / max(1, c.sessionCount))) · \(formatUSD(costUSD / Double(max(1, c.sessionCount))))")
                    }
                    StatRow(name: "Est. cost", value: "\(formatTHB(costUSD)) · \(formatUSD(costUSD))")

                    if settings.showPeriodCost, let pc = snap.periodCosts, let d7 = pc.claudeUSD7, let d30 = pc.claudeUSD30 {
                        StatPairRow("7-day", formatUSD(d7), "30-day", formatUSD(d30))
                    }
                } else {
                    PaneHeader(title: "Claude Code")
                    NoteText(text: "Not detected.")
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var claudeLimitsSection: some View {
        if let l = snap.claudeLimits {
            switch l.state {
            case .ok:
                if settings.showFiveHourInMenuBar, let w = l.fiveHour { limitRowOrNote("5-hour", w) }
                if settings.showWeeklyInMenuBar, let w = l.sevenDay { limitRowOrNote("Weekly", w) }
                if !settings.showFiveHourInMenuBar && !settings.showWeeklyInMenuBar {
                    NoteText(text: "Both windows hidden — enable in Settings › Providers")
                }
            case .rateLimited, .error:
                NoteText(text: "No limit data to show yet — retrying next refresh")
            case .stale:
                NoteText(text: "Login expired — run `claude` to sign in")
            case .notLoggedIn:
                NoteText(text: "Not logged in to Claude Code")
            }
        } else {
            NoteText(text: "Fetching limits…")
        }
    }
}

struct CodexPane: View {
    let snap: UsageSnapshot
    @ObservedObject private var settings = AppSettings.shared

    private var x: CodexUsage? { snap.codex }
    private var costUSD: Double { x.map(Pricing.codexCostUSD) ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let x {
                    let title = snap.codexLimits?.planType.map { "Codex (\($0))" } ?? "Codex"
                    PaneHeader(title: title, icon: BrandIcons.codex)
                    codexLimitsSection

                    CaptionText(title: "Today's tokens")
                    StatPairRow("Total", formatTokens(x.totalTokens), "Sessions", "\(x.sessionCount)")
                    StatPairRow("Input", formatTokens(x.inputTokens), "Cached in", formatTokens(x.cachedInputTokens))
                    StatPairRow("Output", formatTokens(x.outputTokens), "Reasoning", formatTokens(x.reasoningTokens))

                    if settings.showCacheHitRate {
                        StatRow(name: "Cache hit rate", value: "\(Int(Pricing.codexCacheHitRatePercent(x).rounded()))%")
                    }
                    if settings.showAvgPerSession {
                        StatRow(name: "Avg/session",
                                value: "\(formatTokens(x.totalTokens / max(1, x.sessionCount))) · \(formatUSD(costUSD / Double(max(1, x.sessionCount))))")
                    }
                    StatRow(name: "Est. cost", value: "\(formatTHB(costUSD)) · \(formatUSD(costUSD))")
                    if settings.showPeriodCost, let pc = snap.periodCosts, let d7 = pc.codexUSD7, let d30 = pc.codexUSD30 {
                        StatPairRow("7-day", formatUSD(d7), "30-day", formatUSD(d30))
                    }
                } else {
                    PaneHeader(title: "Codex")
                    NoteText(text: "Not detected.")
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var codexLimitsSection: some View {
        if let l = snap.codexLimits {
            CaptionText(title: "Limits · as of \(humanAgo(l.asOf))")
            if let w = l.secondary { limitRowOrNote("Weekly", w) }
        } else {
            NoteText(text: "No limit data yet — run codex once")
        }
    }
}

struct AntigravityPane: View {
    let snap: UsageSnapshot
    @ObservedObject private var settings = AppSettings.shared

    private var g: AntigravityUsage? { snap.antigravity }
    private var costUSD: Double { g.map(Pricing.antigravityCostUSD) ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let g {
                    PaneHeader(title: "Antigravity", icon: BrandIcons.gemini, iconTint: Color(nsColor: BrandIcons.geminiBrandColor))
                    antigravityLimitsSection(g)

                    CaptionText(title: "Today's activity")
                    StatPairRow("Prompts", "\(g.totalPrompts)", "Sessions", "\(g.sessionCount)")
                    if settings.showAvgPerSession {
                        StatRow(name: "Avg/session",
                                value: "\(g.totalPrompts / max(1, g.sessionCount))P · \(formatUSD(costUSD / Double(max(1, g.sessionCount))))")
                    }
                    StatRow(name: "Est. cost", value: "\(formatTHB(costUSD)) · \(formatUSD(costUSD))")
                    if settings.showPeriodCost, let pc = snap.periodCosts, let d7 = pc.antigravityUSD7, let d30 = pc.antigravityUSD30 {
                        StatPairRow("7-day", formatUSD(d7), "30-day", formatUSD(d30))
                    }
                } else {
                    PaneHeader(title: "Antigravity")
                    NoteText(text: "Not detected.")
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func antigravityLimitsSection(_ g: AntigravityUsage) -> some View {
        if g.fiveHour == nil && g.weekly == nil {
            NoteText(text: "No quota data yet — use Antigravity once to refresh it")
        } else {
            if let w = g.fiveHour { limitRowOrNote("5-hour", w) }
            if let w = g.weekly { limitRowOrNote("Weekly", w) }
        }
    }
}

struct AnalyticsPane: View {
    let snap: UsageSnapshot

    private var hasAnyProvider: Bool {
        snap.claude != nil || snap.codex != nil || snap.antigravity != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !hasAnyProvider {
                    PaneHeader(title: "No AI CLI detected")
                    NoteText(text: "Looked for ~/.claude, ~/.codex and ~/.gemini")
                    Divider()
                }
                PaneHeader(title: "Analytics · Today")
                if let peak = snap.hourlyUsage.peakHour {
                    NoteText(text: "Peak activity: \(String(format: "%02d:00", peak)) · \(formatTokens(snap.hourlyUsage.values[peak])) units")
                }
                HourlyChartRepresentable(usage: snap.hourlyUsage)
                    .frame(height: 132)
                    .id(snap.hourlyUsage.values)
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

// MARK: - Sidebar

enum PopoverPane: Hashable {
    case provider(ProviderKind)
    case analytics
}

private struct SidebarRow: View {
    let icon: NSImage?
    let title: String
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).renderingMode(.template).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: "chart.line.uptrend.xyaxis").frame(width: 15, height: 15)
            }
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

struct PopoverSidebar: View {
    let tabs: [PopoverPane]
    @Binding var selection: PopoverPane

    private func title(for pane: PopoverPane) -> String {
        switch pane {
        case .provider(let kind): return kind.displayName
        case .analytics: return "Analytics"
        }
    }
    private func icon(for pane: PopoverPane) -> NSImage? {
        switch pane {
        case .provider(let kind): return kind.icon
        case .analytics: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tabs, id: \.self) { pane in
                Button {
                    selection = pane
                } label: {
                    SidebarRow(icon: icon(for: pane), title: title(for: pane), selected: selection == pane)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 130)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Footer (always visible, regardless of selected tab)

struct PopoverFooter: View {
    @ObservedObject var viewModel: UsageViewModel
    let appVersion: String
    let onRefresh: () -> Void
    let onCheckForUpdates: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            RefreshCountdownRepresentable(
                updatedAt: viewModel.snapshot.updatedAt,
                nextFire: viewModel.nextRefreshAt,
                interval: viewModel.refreshInterval
            )
            .frame(height: 20)
            .id(viewModel.nextRefreshAt)

            Text("AI Usage Bar v\(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Button("Refresh Now", action: onRefresh)
                Button("Check for Updates…", action: onCheckForUpdates)
                Spacer()
            }
            HStack(spacing: 14) {
                Button("Settings…", action: onSettings)
                Spacer()
                Button("Quit", action: onQuit)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
    }
}

// MARK: - Root

struct PopoverContentView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var selection: PopoverPane
    let appVersion: String
    let onRefresh: () -> Void
    let onCheckForUpdates: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    init(
        viewModel: UsageViewModel, appVersion: String,
        onRefresh: @escaping () -> Void, onCheckForUpdates: @escaping () -> Void,
        onSettings: @escaping () -> Void, onQuit: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.appVersion = appVersion
        self.onRefresh = onRefresh
        self.onCheckForUpdates = onCheckForUpdates
        self.onSettings = onSettings
        self.onQuit = onQuit
        _selection = State(initialValue: Self.initialSelection(for: viewModel.snapshot))
    }

    private var tabs: [PopoverPane] {
        var t: [PopoverPane] = AppSettings.shared.providerOrder.compactMap { kind -> PopoverPane? in
            switch kind {
            case .claude: return viewModel.snapshot.claude != nil ? .provider(kind) : nil
            case .codex: return viewModel.snapshot.codex != nil ? .provider(kind) : nil
            case .antigravity: return viewModel.snapshot.antigravity != nil ? .provider(kind) : nil
            }
        }
        t.append(.analytics)
        return t
    }

    private static func initialSelection(for snap: UsageSnapshot) -> PopoverPane {
        for kind in AppSettings.shared.providerOrder {
            switch kind {
            case .claude: if snap.claude != nil { return .provider(.claude) }
            case .codex: if snap.codex != nil { return .provider(.codex) }
            case .antigravity: if snap.antigravity != nil { return .provider(.antigravity) }
            }
        }
        return .analytics
    }

    var body: some View {
        HStack(spacing: 0) {
            PopoverSidebar(tabs: tabs, selection: $selection)
            Divider()
            VStack(spacing: 0) {
                Group {
                    switch selection {
                    case .provider(.claude):
                        ClaudePane(snap: viewModel.snapshot, claudeAPIProblem: viewModel.claudeAPIProblem, lastGoodClaudeFetchedAt: viewModel.lastGoodClaudeFetchedAt)
                    case .provider(.codex):
                        CodexPane(snap: viewModel.snapshot)
                    case .provider(.antigravity):
                        AntigravityPane(snap: viewModel.snapshot)
                    case .analytics:
                        AnalyticsPane(snap: viewModel.snapshot)
                    }
                }
                .frame(maxHeight: .infinity)
                PopoverFooter(viewModel: viewModel, appVersion: appVersion, onRefresh: onRefresh, onCheckForUpdates: onCheckForUpdates, onSettings: onSettings, onQuit: onQuit)
            }
            .frame(width: 380)
        }
        .frame(height: 480)
        .onChange(of: viewModel.snapshot.updatedAt) { _ in
            // If the currently selected provider disappears (stopped being
            // detected), fall back instead of showing a dead pane.
            if case .provider = selection, !tabs.contains(selection) {
                selection = tabs.first ?? .analytics
            }
        }
    }
}
