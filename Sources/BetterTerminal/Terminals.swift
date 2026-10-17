import AppKit
import BTCore
import SwiftTerm

/// Shared by the compose bar and the classic view (full pane or in-thread panel): the right-click menu.
///
/// SwiftTerm forwards right-clicks to the program when it asked for mouse events (vim with
/// `mouse=a`, htop) and otherwise hands them to AppKit, which asks `menu(for:)`: that is where
/// the menu, or the Windows Terminal-style copy/paste, happens.
class PaneTerminalView: TerminalView {
    weak var paneDelegate: PaneModel?

    private static let copySel = NSSelectorFromString("copy:")
    private static let pasteSel = NSSelectorFromString("paste:")
    private static let selectAllSel = NSSelectorFromString("selectAll:")

    /// True when the user has selected text in this terminal (SwiftTerm enables Copy exactly then).
    var hasSelection: Bool {
        super.validateUserInterfaceItem(NSMenuItem(title: "", action: Self.copySel, keyEquivalent: ""))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if Prefs.shared.rightClickCopyPaste {
            // Windows Terminal style: copy the selection if there is one, otherwise paste.
            if hasSelection { NSApp.sendAction(Self.copySel, to: self, from: self) } else { paste(self) }
            return nil
        }
        return buildMenu()
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", mods: NSEvent.ModifierFlags = .command) {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
        }
        add("Copy", Self.copySel, "c")
        add("Paste", Self.pasteSel, "v")
        add("Select All", Self.selectAllSel, "a")
        m.addItem(.separator())
        add("Clear Thread", #selector(btClearThread(_:)), "k")
        add("Copy Screenshot of Pane", #selector(btScreenshot(_:)), "s", mods: [.command, .shift])
        let classic = MainActor.assumeIsolated { paneDelegate?.showsFullClassic ?? false }
        add(classic ? "Bubble View" : "Classic View", #selector(btToggleClassic(_:)), "\\")
        return m
    }

    @objc func btClearThread(_ sender: Any?) { MainActor.assumeIsolated { paneDelegate?.clearThread() } }
    @objc func btScreenshot(_ sender: Any?) { MainActor.assumeIsolated { if let p = paneDelegate { Screenshot.copy(pane: p) } } }
    @objc func btToggleClassic(_ sender: Any?) { MainActor.assumeIsolated { paneDelegate?.toggleClassic() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(btClearThread(_:)), #selector(btScreenshot(_:)): return true
        case #selector(btToggleClassic(_:)): return !Prefs.shared.classicEverywhere
        default: return super.validateUserInterfaceItem(item) // Copy only with a selection; Paste, Select All always
        }
    }
}

/// The always-up-to-date classic terminal. It is the only view that answers terminal queries.
final class ClassicTerminalView: PaneTerminalView, TerminalViewDelegate {

    override init(frame: CGRect, font: NSFont?) {
        // SwiftTerm's default scrollback is 500 lines; the design promises 10,000.
        super.init(frame: frame, font: font, options: TerminalOptions(scrollback: 10_000))
        terminalDelegate = self
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { paneDelegate?.sendFromKeyboard(data) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { paneDelegate?.classicResized(cols: newCols, rows: newRows) }
    }
    func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated { paneDelegate?.titleChanged(title) }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let d = directory, let url = URL(string: d) else { return }
        let path = url.path.removingPercentEncoding ?? url.path
        let name = path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
        MainActor.assumeIsolated {
            paneDelegate?.cwdChanged(path)
            paneDelegate?.titleChanged(name)
        }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The compose bar: a small terminal that shows only the live prompt / zsh line editor.
/// Keystrokes go to the shell; its own replies to terminal queries are dropped (the classic view answers).
final class ComposeTerminalView: PaneTerminalView, TerminalViewDelegate {

    override init(frame: CGRect, font: NSFont?) {
        super.init(frame: frame, font: font)
        terminalDelegate = self
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // Bytes the terminal itself emits. Query replies are dropped (the classic view answers those);
    // everything else, notably pasted and dropped text, goes to the shell.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !TerminalReplies.isQueryReply(data) else { return }
        let bytes = Array(data)
        let forward: () -> Void = { [weak self] in
            MainActor.assumeIsolated { _ = self?.paneDelegate?.sendFromKeyboard(bytes[...]) }
        }
        if Thread.isMainThread { forward() } else { DispatchQueue.main.async { forward() } }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { paneDelegate?.sendFromKeyboard(data) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {} // the classic view beeps for the same BEL
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
