import AppKit
import BTCore
import SwiftUI

/// The pane layout of one window: a binary tree of splits with panes at the leaves.
@MainActor
final class WindowModel: ObservableObject {
    enum Axis { case sideBySide, stacked }

    indirect enum Node: Identifiable {
        case pane(PaneModel)
        case split(UUID, Axis, Node, Node)

        var id: UUID {
            switch self {
            case .pane(let p): return p.id
            case .split(let id, _, _, _): return id
            }
        }
        var panes: [PaneModel] {
            switch self {
            case .pane(let p): return [p]
            case .split(_, _, let a, let b): return a.panes + b.panes
            }
        }
    }

    @Published private(set) var root: Node
    @Published var focused: PaneModel { didSet { if oldValue !== focused { focused.focusActive() } } }
    /// Pane frames in window coordinates (for ⌘⌥-arrow focus moves).
    var frames: [UUID: CGRect] = [:]
    weak var window: NSWindow?

    // Window ↔ model registry, for the key-routing monitor and menu commands.
    private static var all: [Weak] = []
    private struct Weak { weak var model: WindowModel? }
    static func model(for window: NSWindow?) -> WindowModel? {
        all.lazy.compactMap(\.model).first { $0.window === window && window != nil }
    }
    static var allModels: [WindowModel] { all.compactMap(\.model) }
    /// The pane window the user last worked in (for ⌘T / + when AppKit has no key window yet).
    static weak var lastActiveWindow: NSWindow?
    /// Set by "New Tab": the next window that appears joins this window as a tab.
    static weak var pendingTabParent: NSWindow?
    /// Folder for the next window's first pane (new tab in the current folder).
    static var pendingCwd: String?
    /// Files and URLs opened from Finder or links, one per new window (see OpenHandler).
    static var pendingLaunches: [LaunchPlan] = []

    init() {
        let plan = Self.pendingLaunches.isEmpty ? nil : Self.pendingLaunches.removeFirst()
        let p = PaneModel(cwd: plan?.directory ?? Self.pendingCwd)
        Self.pendingCwd = nil
        if let plan { p.run(plan) }
        root = .pane(p)
        focused = p
        p.host = self
        Self.all.removeAll { $0.model == nil }
        Self.all.append(Weak(model: self))
    }

    var panes: [PaneModel] { root.panes }
    var title: String { focused.title }

    private var closeGuard: CloseGuard?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        Self.lastActiveWindow = window
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { n in
            MainActor.assumeIsolated { Self.lastActiveWindow = n.object as? NSWindow }
        }
        // System default: ⌘N opens a separate window (CEO report: it opened a tab while this said
        // .preferred). ⌘T and the tab bar's + add tabs explicitly with addTabbedWindow below.
        window.tabbingMode = .automatic
        // The red close button: ask before stopping running commands (⌘W already asks per pane).
        let guardObj = CloseGuard(model: self)
        closeGuard = guardObj
        if let b = window.standardWindowButton(.closeButton) { b.target = guardObj; b.action = #selector(CloseGuard.close(_:)) }
        if let parent = Self.pendingTabParent, parent !== window {
            Self.pendingTabParent = nil
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            // The mini has a projector and a remote (Jump Desktop) display: open where the user's pointer is.
            Self.moveToPointerScreen(window)
        }
        focused.focusActive()
    }

    /// Centres `window` on the display that has the mouse pointer (no-op when it is already there).
    static func moveToPointerScreen(_ window: NSWindow, force: Bool = false) {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main,
              force || window.screen !== screen else { return }
        let v = screen.visibleFrame
        var f = window.frame
        f.size.width = min(f.width, v.width); f.size.height = min(f.height, v.height)
        f.origin = NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2)
        window.setFrame(f, display: true)
    }

    // MARK: Splits

    func split(_ axis: Axis) {
        let old = focused
        let new = PaneModel(cwd: old.cwd)
        new.host = self
        root = replacing(old.id, in: root) { .split(UUID(), axis, $0, .pane(new)) }
        focused = new
    }

    /// Closes a pane. Returns false when it was the last one (the caller closes the window).
    @discardableResult
    func close(_ pane: PaneModel) -> Bool {
        guard case .split = root else { return false }
        let order = panes
        let i = order.firstIndex { $0 === pane } ?? 0
        root = removing(pane.id, from: root) ?? root
        pane.terminate()
        if focused === pane {
            let rest = panes
            focused = rest[min(i, rest.count - 1)]
        }
        return true
    }

    func closeAll() { panes.forEach { $0.terminate() } }

    enum Direction { case left, right, up, down }

    func moveFocus(_ d: Direction) {
        guard let from = frames[focused.id] else { return }
        let c = CGPoint(x: from.midX, y: from.midY)
        let candidates = panes.filter { $0 !== focused }.compactMap { p -> (PaneModel, CGFloat)? in
            guard let f = frames[p.id] else { return nil }
            let ok: Bool
            switch d {
            case .left: ok = f.maxX <= from.minX + 1
            case .right: ok = f.minX >= from.maxX - 1
            case .up: ok = f.maxY <= from.minY + 1
            case .down: ok = f.minY >= from.maxY - 1
            }
            guard ok else { return nil }
            return (p, hypot(f.midX - c.x, f.midY - c.y))
        }
        if let next = candidates.min(by: { $0.1 < $1.1 })?.0 { focused = next }
    }

    func cycleFocus(_ step: Int) {
        let order = panes
        guard let i = order.firstIndex(where: { $0 === focused }), order.count > 1 else { return }
        focused = order[(i + step + order.count) % order.count]
    }

    // MARK: Tree helpers

    private func replacing(_ id: UUID, in node: Node, with make: (Node) -> Node) -> Node {
        switch node {
        case .pane(let p): return p.id == id ? make(node) : node
        case .split(let sid, let axis, let a, let b):
            return .split(sid, axis, replacing(id, in: a, with: make), replacing(id, in: b, with: make))
        }
    }

    private func removing(_ id: UUID, from node: Node) -> Node? {
        switch node {
        case .pane(let p): return p.id == id ? nil : node
        case .split(let sid, let axis, let a, let b):
            let na = removing(id, from: a), nb = removing(id, from: b)
            switch (na, nb) {
            case (nil, let x?), (let x?, nil): return x
            case (let x?, let y?): return .split(sid, axis, x, y)
            case (nil, nil): return nil
            }
        }
    }
}

/// Target for the window's close button (WindowModel is not an NSObject).
final class CloseGuard: NSObject {
    weak var model: WindowModel?
    init(model: WindowModel) { self.model = model }

    @objc func close(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let m = model, let w = m.window else { return }
            let busy = m.panes.filter(\.isBusy)
            if !busy.isEmpty {
                let names = busy.compactMap { $0.running?.label }.prefix(3).joined(separator: ", ")
                guard AppDelegate.confirm("Close this window?",
                                          "\(busy.count == 1 ? "A command is" : "\(busy.count) commands are") still running (\(names)). Closing stops \(busy.count == 1 ? "it" : "them") and clears the thread.",
                                          button: "Close") else { return }
            }
            w.close()
        }
    }
}
