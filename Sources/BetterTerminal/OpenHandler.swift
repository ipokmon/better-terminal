import AppKit
import BTCore

/// Files and URLs that macOS routes to us (Better Terminal as the default terminal): .command, .sh,
/// .tool, unix executables, ssh://, telnet://, x-man-page://. Parsing is in BTCore's OpenRequest.
/// Each accepted item is queued under a LaunchTicket and gets a window opened with that ticket; only
/// that window runs it (a ⌘N window carries no ticket).
@MainActor
enum OpenHandler {
    /// A requested window that has not appeared by then is given up on and its plan reported as not run.
    static let windowTimeout: TimeInterval = 10

    private static var queue = LaunchQueue()
    private static var finishedLaunching = false

    /// A launch to open a document makes no SwiftUI window (see handlesExternalEvents): open the queued ones.
    static func didFinishLaunching() {
        finishedLaunching = true
        // One turn of the run loop, so SwiftUI has built the menu bar commands that register the opener.
        DispatchQueue.main.async {
            guard !queue.isEmpty else { return }
            guard AppActions.openTicketWindow != nil else { return reportUnrun("Could not open a window.") }
            queue.tickets.forEach(request)
        }
    }

    static func open(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            do {
                route(try OpenRequest.plan(for: url))
            } catch let error as OpenRequestError {
                rejected.append(error.description)
            } catch {
                rejected.append(OpenRequest.displaySafe("\(url.absoluteString): \(error.localizedDescription)"))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if !rejected.isEmpty { showError(rejected) }
    }

    /// The plan queued for a window's ticket; nil (a plain shell) for ⌘N and unknown or used tickets.
    static func claim(_ ticket: LaunchTicket?) -> LaunchPlan? { queue.claim(ticket) }

    private static func route(_ plan: LaunchPlan) {
        let ticket = queue.enqueue(plan)
        switch OpenRoute.decide(canOpenWindows: AppActions.openTicketWindow != nil, finishedLaunching: finishedLaunching) {
        case .openWindow: request(ticket)
        case .waitForLaunch: break
        case .cannotOpen: reportUnrun("Could not open a window.")
        }
    }

    private static func request(_ ticket: LaunchTicket) {
        AppActions.openTicketWindow?(ticket)
        DispatchQueue.main.asyncAfter(deadline: .now() + windowTimeout) {
            // Still unclaimed: the window never appeared. Remove it so a late window cannot run it.
            if let plan = queue.claim(ticket) {
                showError(["No window opened within \(Int(windowTimeout)) s. Not run:", OpenRequest.displaySafe(plan.commandLine)])
            }
        }
    }

    private static func reportUnrun(_ reason: String) {
        let lost = queue.drain().map { OpenRequest.displaySafe($0.commandLine) }
        guard !lost.isEmpty else { return }
        showError(["\(reason) Not run:"] + lost)
    }

    private static func showError(_ reasons: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = reasons.count == 1 ? "Better Terminal could not open this" : "Better Terminal could not open everything"
        alert.informativeText = reasons.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
