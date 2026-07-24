import Foundation
import Combine

/// Backs the popover's SwiftUI content. AppDelegate publishes into this on
/// every refresh tick instead of rebuilding an NSMenu from scratch.
final class UsageViewModel: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    @Published var claudeAPIProblem: String?
    @Published var lastGoodClaudeFetchedAt: Date?
    @Published var nextRefreshAt = Date()
    let refreshInterval: TimeInterval

    init(refreshInterval: TimeInterval) {
        self.refreshInterval = refreshInterval
    }
}
