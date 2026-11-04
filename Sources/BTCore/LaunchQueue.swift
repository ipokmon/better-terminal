import Foundation

/// Names one requested pane window. The window is opened with this value (SwiftUI's
/// `openWindow(id:value:)`), so it can claim exactly the plan queued for it; a plain ⌘N window has none.
public struct LaunchTicket: Hashable, Codable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Plans waiting for their windows. Pure value type so ordering and claiming are testable.
public struct LaunchQueue: Sendable {
    private var items: [(ticket: LaunchTicket, plan: LaunchPlan)] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    public var tickets: [LaunchTicket] { items.map(\.ticket) }

    public mutating func enqueue(_ plan: LaunchPlan) -> LaunchTicket {
        let ticket = LaunchTicket()
        items.append((ticket, plan))
        return ticket
    }

    /// The plan queued for `ticket`, removed so it can never run twice. nil for no ticket or an unknown one.
    public mutating func claim(_ ticket: LaunchTicket?) -> LaunchPlan? {
        guard let ticket, let i = items.firstIndex(where: { $0.ticket == ticket }) else { return nil }
        return items.remove(at: i).plan
    }

    /// Every unclaimed plan, oldest first, leaving the queue empty (to report what did not run).
    public mutating func drain() -> [LaunchPlan] {
        defer { items.removeAll() }
        return items.map(\.plan)
    }
}

/// How an accepted open request gets its pane window. Pure, so the app's window bookkeeping is testable.
public enum OpenRoute: Equatable, Sendable {
    /// Open a window for its ticket now through SwiftUI's openWindow.
    case openWindow
    /// Still launching: applicationDidFinishLaunching opens the windows.
    case waitForLaunch
    /// Launched and still no way to open a window: report the plan as not run.
    case cannotOpen

    public static func decide(canOpenWindows: Bool, finishedLaunching: Bool) -> OpenRoute {
        guard finishedLaunching else { return .waitForLaunch }
        return canOpenWindows ? .openWindow : .cannotOpen
    }
}
