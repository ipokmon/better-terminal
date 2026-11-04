import AppKit
import BTCore

/// Files and URLs that macOS routes to us (Better Terminal as the default terminal): .command, .sh,
/// .tool, unix executables, ssh://, telnet://, x-man-page://. Parsing is in BTCore's OpenRequest.
/// Each accepted item runs in a new window, whose first pane takes it from `WindowModel.pendingLaunches`.
@MainActor
enum OpenHandler {
    private static var finishedLaunching = false

    /// A launch to open a document makes no SwiftUI window (see handlesExternalEvents), so open one here.
    static func didFinishLaunching() {
        finishedLaunching = true
        if !WindowModel.pendingLaunches.isEmpty, WindowModel.allModels.isEmpty { openWindowFromMenu() }
    }

    static func open(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            do {
                route(try OpenRequest.plan(for: url))
            } catch let error as OpenRequestError {
                rejected.append(error.description)
            } catch {
                rejected.append("\(url.absoluteString): \(error.localizedDescription)")
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if !rejected.isEmpty { showError(rejected) }
    }

    private static func route(_ plan: LaunchPlan) {
        let decision = OpenRoute.decide(queueIsEmpty: WindowModel.pendingLaunches.isEmpty,
                                        canOpenWindows: AppActions.openPaneWindow != nil,
                                        finishedLaunching: finishedLaunching)
        WindowModel.pendingLaunches.append(plan)
        switch decision {
        case .waitForQueuedWindow, .waitForLaunch: break
        case .openWindow: AppActions.openPaneWindow?()
        case .openWindowFromMenu: openWindowFromMenu()
        }
    }

    /// Called when a pane window appears: if requests are still queued, open a window for the next one.
    static func continueQueue() {
        if !WindowModel.pendingLaunches.isEmpty { AppActions.openPaneWindow?() }
    }

    /// SwiftUI's own File ▸ New Window, for when no window exists yet to give us openWindow.
    private static func openWindowFromMenu() {
        for top in NSApp.mainMenu?.items ?? [] {
            if let sub = top.submenu, let i = sub.items.firstIndex(where: { $0.title == "New Window" }) {
                sub.performActionForItem(at: i)
                return
            }
        }
        let lost = WindowModel.pendingLaunches.map(\.commandLine)
        WindowModel.pendingLaunches.removeAll()
        showError(["Could not open a window (File ▸ New Window not found). Not run:"] + lost)
    }

    private static func showError(_ reasons: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = reasons.count == 1 ? "Better Terminal could not open this" : "Better Terminal could not open \(reasons.count) items"
        alert.informativeText = reasons.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
