import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var logText = ""

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
                LabeledContent("Claude windows") {
                    HStack(spacing: 16) {
                        Toggle("5-hour", isOn: $settings.showFiveHourInMenuBar)
                        Toggle("Weekly", isOn: $settings.showWeeklyInMenuBar)
                    }
                }
                Toggle("Compact provider display", isOn: $settings.compactMenuBar)
                Toggle("Show Antigravity model details", isOn: $settings.showAntigravityModelDetails)
                LabeledContent("THB per USD") {
                    TextField("33", value: $settings.thbPerUSD, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Text("The menu bar shows the tightest of the selected Claude windows (token total when both are off); the dropdown always shows both. Cost rows price today's tokens at API list prices, converted to baht at this rate.")
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

            Section {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(logText.isEmpty ? "No log entries yet." : logText)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("logEnd")
                    }
                    .frame(height: 170)
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
            } header: {
                Text("Log")
            } footer: {
                Text("API calls, keychain reads, and errors. Stored at ~/Library/Logs/AIUsageBar/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize()
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
