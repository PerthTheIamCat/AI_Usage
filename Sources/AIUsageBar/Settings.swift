import Foundation
import Combine

extension Notification.Name {
    /// Posted whenever a setting changes so the status item re-renders.
    static let usageSettingsChanged = Notification.Name("usageSettingsChanged")
}

/// How percentages are presented everywhere (menu-bar title, menu rows, bars).
enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case remaining  // "84% left"
    case used       // "16% used"

    var id: String { rawValue }

    /// Short form for the menu-bar title.
    func shortText(remaining: Double) -> String {
        switch self {
        case .remaining: return "\(Int(remaining.rounded()))%"
        case .used: return "\(Int((100 - remaining).rounded()))%"
        }
    }

    /// Long form for menu limit rows.
    func rowText(remaining: Double) -> String {
        switch self {
        case .remaining: return "\(Int(remaining.rounded()))% left"
        case .used: return "\(Int((100 - remaining).rounded()))% used"
        }
    }
}

/// UserDefaults-backed app settings, observable from SwiftUI.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let displayMode = "displayMode"
        static let warnBelowRemaining = "warnBelowRemaining"
        static let showFiveHourInMenuBar = "showFiveHourInMenuBar"
        static let showWeeklyInMenuBar = "showWeeklyInMenuBar"
        static let thbPerUSD = "thbPerUSD"
        static let compactMenuBar = "compactMenuBar"
        static let showAntigravityModelDetails = "showAntigravityModelDetails"
    }

    @Published var displayMode: UsageDisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Turn the title/bars red when a window's *remaining* capacity drops
    /// below this percentage (stored in remaining terms in both modes).
    @Published var warnBelowRemaining: Double {
        didSet {
            UserDefaults.standard.set(warnBelowRemaining, forKey: Keys.warnBelowRemaining)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Which Claude windows feed the menu-bar percentage. The dropdown menu
    /// always shows both; these only affect the title in the menu bar.
    @Published var showFiveHourInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showFiveHourInMenuBar, forKey: Keys.showFiveHourInMenuBar)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var showWeeklyInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showWeeklyInMenuBar, forKey: Keys.showWeeklyInMenuBar)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Exchange rate for the estimated-cost rows (THB per 1 USD).
    @Published var thbPerUSD: Double {
        didSet {
            UserDefaults.standard.set(thbPerUSD, forKey: Keys.thbPerUSD)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var compactMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(compactMenuBar, forKey: Keys.compactMenuBar)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var showAntigravityModelDetails: Bool {
        didSet {
            UserDefaults.standard.set(showAntigravityModelDetails, forKey: Keys.showAntigravityModelDetails)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    private init() {
        let d = UserDefaults.standard
        displayMode = UsageDisplayMode(rawValue: d.string(forKey: Keys.displayMode) ?? "") ?? .remaining
        let stored = d.double(forKey: Keys.warnBelowRemaining)
        warnBelowRemaining = stored > 0 ? stored : 20
        showFiveHourInMenuBar = d.object(forKey: Keys.showFiveHourInMenuBar) as? Bool ?? true
        showWeeklyInMenuBar = d.object(forKey: Keys.showWeeklyInMenuBar) as? Bool ?? true
        let rate = d.double(forKey: Keys.thbPerUSD)
        thbPerUSD = rate > 0 ? rate : 33
        compactMenuBar = d.object(forKey: Keys.compactMenuBar) as? Bool ?? false
        showAntigravityModelDetails = d.object(forKey: Keys.showAntigravityModelDetails) as? Bool ?? false
    }
}
