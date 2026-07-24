import AppKit
import SwiftUI
import ServiceManagement

/// Apple-style preferences window: a top tab switcher (the same pattern as
/// Xcode/Mail/Safari Preferences) instead of one long scrolling form, so each
/// page stays short and the Log doesn't crowd out everything else.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersTab()
                .tabItem { Label("Providers", systemImage: "arrow.up.arrow.down") }
            CostTab()
                .tabItem { Label("Cost", systemImage: "dollarsign.circle") }
            LogTab()
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .frame(width: 560, height: 440)
    }
}

private struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Usage display") {
                Picker("Show limits as", selection: $settings.displayMode) {
                    Text("Remaining — “84% left”").tag(UsageDisplayMode.remaining)
                    Text("Used — “16% used”").tag(UsageDisplayMode.used)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Cache hit rate", isOn: $settings.showCacheHitRate)
                Toggle("Per-model breakdown", isOn: $settings.showModelBreakdown)
                Toggle("Avg/session", isOn: $settings.showAvgPerSession)
                Toggle("7-day / 30-day cost", isOn: $settings.showPeriodCost)
            } header: {
                Text("Dropdown content")
            } footer: {
                Text("Pick which extra rows show per provider in the dropdown. Limits, today's tokens, and Est. cost always show.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Slider(value: $settings.warnBelowRemaining, in: 5...45, step: 5) {
                    Text("Warn below")
                } minimumValueLabel: {
                    Text("5%")
                } maximumValueLabel: {
                    Text("45%")
                }
                LabeledContent("Current threshold") {
                    Text("turns red at \(Int(settings.warnBelowRemaining))% remaining")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Low-limit warning")
            } footer: {
                Text("The menu-bar percentage and meters turn red when a window's remaining capacity drops below this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProvidersTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Order").font(.headline)
            Text("Drag to reorder. Applies to both the status-bar segment order and the dropdown section order.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(settings.providerOrder) { kind in
                    ProviderRow(kind: kind)
                }
                .onMove { settings.moveProvider(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .frame(height: 150)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Divider().padding(.vertical, 4)

            Text("Claude windows").font(.headline)
            Toggle("5-hour window", isOn: $settings.showFiveHourInMenuBar)
            Toggle("Weekly window", isOn: $settings.showWeeklyInMenuBar)
            Text("Which Claude limit windows appear — in the menu-bar percentage and as rows in the dropdown.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
    }
}

private struct ProviderRow: View {
    let kind: ProviderKind

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: kind.icon)
                .renderingMode(.template)
                .resizable()
                .frame(width: 15, height: 15)
            Text(kind.displayName)
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct CostTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var isRefreshing = false

    private var lastFetchedText: String {
        settings.thbLastFetched.map(humanAgo) ?? "never"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Fetch live rate automatically", isOn: $settings.thbAutoFetch)
                LabeledContent("THB per USD") {
                    TextField("33", value: $settings.thbPerUSD, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .disabled(settings.thbAutoFetch)
                }
                LabeledContent("Last fetched") {
                    Text(lastFetchedText)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(isRefreshing ? "Refreshing…" : "Refresh Now") {
                        isRefreshing = true
                        ExchangeRateFetcher.fetchUSDtoTHB { rate in
                            isRefreshing = false
                            if let rate {
                                settings.thbPerUSD = rate
                                settings.thbLastFetched = Date()
                            }
                        }
                    }
                    .disabled(isRefreshing)
                }
            } header: {
                Text("Exchange rate")
            } footer: {
                Text("Cost rows price today's tokens at API list prices, converted to baht at this rate. Auto-fetch pulls from api.frankfurter.app (ECB daily rates); turn it off to set a fixed rate by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LogTab: View {
    @State private var logText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText.isEmpty ? "No log entries yet." : logText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("logEnd")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onAppear {
                    logText = AppLog.shared.tail()
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
            HStack {
                Button("Refresh") { logText = AppLog.shared.tail() }
                Button("Open Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.shared.fileURL])
                }
                Spacer()
                Button("Clear", role: .destructive) {
                    AppLog.shared.clear()
                    logText = AppLog.shared.tail()
                }
            }
            Text("API calls, keychain reads, and errors. Stored at ~/Library/Logs/AIUsageBar/.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// Lazily-created, reusable settings window for this menu-bar-only app.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "AI Usage Bar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
