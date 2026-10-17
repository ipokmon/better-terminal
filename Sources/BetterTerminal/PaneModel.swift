import AppKit
import BTCore
import Combine
import SwiftTerm

/// One finished or running command in the thread.
@MainActor
final class CommandItem: ObservableObject, Identifiable {
    let id = UUID()
    let command: String?
    let started = Date()
    @Published private(set) var lines: [StyledLine] = []
    @Published var finished: Date?
    @Published var exitCode: Int32?
    /// Ran as a full terminal panel (alternate screen or panel list): shown as a chip, not a bubble.
    @Published var panel = false
    @Published var expanded = false
    /// Lines not kept: beyond the bubble's scrollback cap, or compacted to save memory.
    @Published private(set) var omittedLines = 0
    private(set) var compacted = false
    /// Bumped whenever `lines` changes (cache key for rendered text).
    private(set) var version = 0

    weak var pane: PaneModel?
    /// The folder the command ran in (for "wrong folder?" hints).
    var cwd: String?
    /// Running but silent for a moment (e.g. after "Checked 20 packages", while it resolves): the
    /// thread shows a typing-dots bubble.
    @Published private(set) var quiet = false
    /// Quiet for over a minute (a server waiting for requests): the dots stop animating, to save power.
    @Published private(set) var quietSince: Date?
    @Published private(set) var longQuiet = false
    private var longQuietWork: DispatchWorkItem?
    /// The program is waiting for a password (echo off, line mode): shown with a 🔑.
    @Published var awaitingSecret = false
    private var quietWork: DispatchWorkItem?
    static let quietAfter = 0.8
    private var screen: Screen?
    private let rows: Int
    private var dirty = false
    var onRefresh: () -> Void = {}

    init(command: String?, cols: Int, rows: Int) {
        self.command = command
        self.rows = rows
        screen = Screen(cols: cols, rows: rows)
    }

    var isLive: Bool { finished == nil }
    var duration: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }

    func feed(_ bytes: [UInt8]) {
        screen?.feed(bytes)
        scheduleRefresh()
        noteActivity()
    }

    /// Restarts the quiet timer: one pending timer per live bubble, nothing once it has finished.
    func noteActivity() {
        if quiet { quiet = false; quietSince = nil }
        if longQuiet { longQuiet = false }
        quietWork?.cancel()
        longQuietWork?.cancel()
        guard isLive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isLive else { return }
            self.quiet = true
            self.quietSince = Date().addingTimeInterval(-Self.quietAfter)
            self.pane?.checkSecretPrompt(self)
        }
        quietWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietAfter, execute: work)
        let long = DispatchWorkItem { [weak self] in if let self, self.isLive { self.longQuiet = true } }
        longQuietWork = long
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: long)
    }

    func resize(cols: Int) { screen?.resize(cols: cols) }

    func finish(exit: Int32?) {
        quietWork?.cancel(); quietWork = nil
        longQuietWork?.cancel(); longQuietWork = nil
        quiet = false; longQuiet = false; quietSince = nil; awaitingSecret = false
        finished = Date()
        exitCode = exit
        refresh()
        omittedLines += screen?.droppedLines ?? 0
        screen = nil // keep only the final text; free the emulator
    }

    /// Keeps the first 10 and last 20 lines of a finished bubble (memory budget for long sessions).
    func compact() {
        guard !isLive, !compacted, lines.count > 30 else { return }
        omittedLines += lines.count - 30
        lines = Array(lines.prefix(10)) + Array(lines.suffix(20))
        compacted = true
        version += 1
        searchCache = nil
        renderCache.removeAll()
    }

    // At most ~30 redraws a second per live bubble.
    private func scheduleRefresh() {
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        dirty = false
        guard let s = screen else { return }
        let new = s.lines()
        // History above the screen never changes, so comparing the tail is enough to skip no-op redraws.
        let tail = rows + 1
        guard new.count != lines.count || new.suffix(tail) != lines.suffix(tail) else { return }
        lines = new
        version += 1
        renderCache.removeAll()
        if !isLive { searchCache = nil }
        onRefresh()
    }

    // MARK: Caches

    /// The command for one-line labels (hints, chips, dialogs): first non-blank line, at most 60
    /// characters, plus "(+N lines)" for pasted scripts. The blue bubble still shows all of it.
    var label: String { Self.oneLine(command) }

    static func oneLine(_ command: String?) -> String {
        guard let command else { return "program" }
        let lines = command.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var first = lines.first { !$0.hasPrefix("#") } ?? lines.first ?? "program" // skip leading # comments
        if first.count > 60 { first = String(first.prefix(57)) + "…" }
        return lines.count > 1 ? "\(first) (+\(lines.count - 1) lines)" : first
    }

    /// A plain-English next step for common failures, shown under the error badge.
    var hint: String? {
        guard !isLive, let code = exitCode, code != 0, code != 130, code != 128 + SIGTSTP else { return nil }
        let out = searchText
        let home = NSHomeDirectory()
        let folder = cwd.map { $0 == home ? "~" : ($0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0) } ?? "this folder"
        if out.contains("no such file or directory") || out.contains("not found in") && out.contains("file") {
            return "📁 Ran in \(folder). A file it needed isn't there: wrong folder or a typo? `ls` shows what's here, `cd` moves."
        }
        if code == 127 || out.contains("command not found") {
            let name = command?.split(separator: " ").first.map(String.init) ?? "That command"
            return "🔎 “\(name)” isn't installed or isn't on your PATH. Check the spelling, or install it."
        }
        if out.contains("permission denied") {
            return "🔒 Permission denied in \(folder). The file may belong to another user, or need `chmod +x` to run."
        }
        if out.contains("parse error") || out.contains("unmatched") {
            return "✏️ zsh couldn't read the command: check quotes and brackets ( ) ' \" in what you pasted."
        }
        return nil
    }

    /// Output as plain text (what "Copy Output" puts on the clipboard).
    var outputText: String {
        lines.map { line in
            var s = line.map(\.text).joined()
            while s.last == " " { s.removeLast() }
            return s
        }.joined(separator: "\n")
    }

    private var searchCache: String?
    /// Lowercased command + output, for find. Cached once the command has finished.
    var searchText: String {
        if let c = searchCache { return c }
        let t = ((command ?? "") + "\n" + lines.map { $0.map(\.text).joined() }.joined(separator: "\n")).lowercased()
        if !isLive { searchCache = t }
        return t
    }

    private var renderCache: [String: AttributedString] = [:]
    /// Rendered output text for a slice, cached per lines version, theme and find query.
    func rendered(_ part: OutputPart, query: String) -> AttributedString {
        let key = "\(part)|\(Theme.version)|\(query)"
        if let hit = renderCache[key] { return hit }
        let slice: ArraySlice<StyledLine>
        switch part {
        case .all: slice = lines[...]
        case .head(let n): slice = lines.prefix(n)
        case .tail(let n): slice = lines.suffix(n)
        }
        let text = Theme.highlight(Theme.attributed(slice), query)
        if renderCache.count > 8 { renderCache.removeAll() }
        renderCache[key] = text
        return text
    }

    enum OutputPart: Hashable, CustomStringConvertible {
        case all, head(Int), tail(Int)
        var description: String {
            switch self { case .all: "all"; case .head(let n): "h\(n)"; case .tail(let n): "t\(n)" }
        }
    }
}

enum ThreadEntry: Identifiable {
    case command(CommandItem)
    case notice(UUID, String)
    var id: UUID {
        switch self {
        case .command(let c): return c.id
        case .notice(let id, _): return id
        }
    }
}

/// One pane: a shell session, the splitter, the hidden classic terminal and the bubble thread.
@MainActor
final class PaneModel: ObservableObject {
    @Published var entries: [ThreadEntry] = []
    @Published var classicLocal = Prefs.shared.defaultClassic
    @Published private(set) var panelActive = false
    @Published private(set) var integrationMissing = false
    @Published private(set) var running: CommandItem?
    @Published var title = "Better Terminal"
    @Published var composeRows = 1
    @Published private(set) var ended = false
    /// Bumped whenever the thread grows, so the list follows the bottom.
    @Published private(set) var scrollTick = 0
    /// The thread follows new output until the user scrolls up; "Jump to latest" brings it back.
    @Published var followBottom = true
    @Published private(set) var newBelow = false
    var bottomVisible = true
    /// Bumped to force a scroll to the bottom (new command, jump button).
    @Published private(set) var jumpTick = 0

    // Find in thread
    @Published var findVisible = false
    @Published var findQuery = "" { didSet { findIndex = 0; recomputeMatches(); findTick += 1 } }
    @Published private(set) var findMatches: [UUID] = []
    @Published private(set) var findIndex = 0
    @Published private(set) var findTick = 0

    /// Commands typed automatically, one per prompt (self-test).
    var script: [String] = []
    private(set) var scriptDone = false

    let id = UUID()
    weak var host: WindowModel?
    var isFocused: Bool { host?.focused === self }
    /// Short message shown over the pane (e.g. "Screenshot copied").
    @Published var toast: String?
    /// The pane's on-screen container, used for screenshots.
    weak var anchorView: NSView?

    let classicView: ClassicTerminalView
    let composeView: ComposeTerminalView
    private let session: Session
    private let splitter: Splitter
    /// Collects shell startup output (motd, instant prompts) into one bubble until the first prompt.
    private var startupItem: CommandItem?
    /// The panel was opened by the alternate screen (vim, fzf), so it closes when that screen does.
    private var panelByAltScreen = false
    private let composeShadow: Screen
    /// Mirrors the classic terminal, only for screenshots (SwiftTerm's layers can't be captured).
    private let classicShadow: Screen
    private var policy: PanelPolicy { PanelPolicy(programs: Set(Prefs.shared.theme.panelPrograms)) }
    private var sawPrompt = false
    private var prefsSub: AnyCancellable?
    private var lastStyle = Theme.terminalStyleKey
    private var lastShowsClassic = false

    static let composeMaxRows = 12

    /// The shell's working folder, from OSC 7 (used for new tabs and splits).
    private(set) var cwd: String?

    init(cwd: String? = nil) {
        self.cwd = cwd
        let font = Theme.font
        classicView = ClassicTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: font)
        composeView = ComposeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200), font: font)
        composeShadow = Screen(cols: 80, rows: Self.composeMaxRows, scrollback: 0)
        classicShadow = Screen(cols: 80, rows: 24, scrollback: 0)
        session = Session(cols: 80, rows: 24)
        splitter = Splitter(nonce: session.nonce)

        classicView.paneDelegate = self
        composeView.paneDelegate = self
        Theme.style(classicView, role: .classic)
        Theme.style(composeView, role: .compose)
        composeView.setCursorStyle(.steadyBlock) // a blinking caret keeps the window server compositing forever
        prefsSub = Prefs.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let style = Theme.terminalStyleKey
                if style != self.lastStyle { self.lastStyle = style; self.restyleClassic(); Theme.style(self.composeView, role: .compose) }
                let classic = self.showsClassic
                self.objectWillChange.send()
                if classic != self.lastShowsClassic { self.lastShowsClassic = classic; if self.isFocused { self.focusActive() } }
            }
        }
        if !UserDefaults.standard.bool(forKey: "seenWelcome") {
            if Prefs.shared.persist { UserDefaults.standard.set(true, forKey: "seenWelcome") }
            entries.append(.notice(UUID(), "Blue = what you typed · grey = output · ⌘\\ classic view · ⌘⇧S screenshot · ⌘F find"))
        }
        session.onData = { [weak self] slice in self?.receive(slice) }
        session.onExit = { [weak self] _ in self?.shellExited() }
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var dir: ObjCBool = false
            let start = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue ? $0 : nil } ?? home
            try session.start(currentDirectory: start,
                              extraEnvironment: Prefs.shared.persist ? [:] : ["BT_NO_HISTORY": "1"]) // tests leave no history
        } catch {
            entries.append(.notice(UUID(), "Could not start the shell: \(error.localizedDescription)"))
        }
        // No prompt mark within 8 s (oh-my-zsh, nvm and compinit can be slow): fall back to classic.
        // A late first prompt switches bubbles back on (see .promptStart).
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.sawPrompt, !self.ended else { return }
            self.integrationMissing = true
            self.entries.append(.notice(UUID(), "Bubbles are unavailable in this shell (no prompt marks). Showing the classic view."))
            self.focusActive()
        }
    }

    /// The whole pane is the classic terminal: per-pane switch, global switch, or no integration.
    var showsFullClassic: Bool { classicLocal || Prefs.shared.classicEverywhere || integrationMissing }
    /// A full-screen program (vim, claude…) runs in a framed panel inside the thread.
    var showsPanel: Bool { panelActive && !showsFullClassic }
    /// The classic terminal is visible (full pane or panel) and gets the keys.
    var showsClassic: Bool { showsFullClassic || showsPanel }

    func toggleClassic() {
        classicLocal.toggle()
        focusActive()
    }

    var activeView: TerminalView { showsClassic ? classicView : composeView }

    func focusActive() {
        let target = activeView
        DispatchQueue.main.async { target.window?.makeFirstResponder(target) }
    }

    /// Called when one of this pane's terminal views became first responder.
    func didGainFocus() {
        if let h = host, h.focused !== self { h.focused = self }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    var isBusy: Bool { running != nil && !ended }

    // MARK: Scrolling

    func userScrolled(up: Bool) {
        if up { followBottom = false } else if bottomVisible { resumeFollowing() }
    }

    func bottomAppeared() {
        bottomVisible = true
        if !followBottom { resumeFollowing() }
    }

    func bottomDisappeared() { bottomVisible = false }

    func resumeFollowing() {
        followBottom = true
        newBelow = false
        jumpTick += 1
    }

    private func contentGrew() {
        scrollTick += 1
        if !followBottom { newBelow = true }
    }

    // MARK: Find

    /// Entries whose command or output contains the query, oldest first. Stored, not computed per view pass.
    func recomputeMatches() {
        let q = findQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { if !findMatches.isEmpty { findMatches = [] }; return }
        findMatches = entries.compactMap { e in
            guard case .command(let c) = e else { return nil }
            return c.searchText.contains(q) ? c.id : nil
        }
    }

    var currentMatch: UUID? {
        let m = findMatches
        return m.isEmpty ? nil : m[min(findIndex, m.count - 1)]
    }

    func showFind() {
        if showsClassic {
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            classicView.performFindPanelAction(item)
            return
        }
        findVisible = true
        followBottom = false
        if findIndex == 0, !findMatches.isEmpty { findIndex = findMatches.count - 1 } // newest first
        findTick += 1
    }

    func findStep(_ delta: Int) {
        let n = findMatches.count
        guard n > 0 else { return }
        findIndex = (findIndex + delta + n) % n
        followBottom = false
        findTick += 1
    }

    func closeFind() {
        findVisible = false
        findQuery = ""
        focusActive()
    }

    /// Types `commands` one per prompt (self-tests). Starts now if the shell is already waiting.
    func runScript(_ commands: [String]) {
        script = commands
        scriptDone = false
        if sawPrompt, running == nil, !script.isEmpty { session.send(script.removeFirst() + "\r") }
    }

    /// What the on-screen terminal views show, for screenshots.
    var standIns: [TerminalStandIn] {
        if showsClassic {
            return [TerminalStandIn(view: classicView, lines: classicShadow.visibleLines(),
                                    background: showsPanel ? Theme.panelNSBackground : .textBackgroundColor,
                                    text: showsPanel ? Theme.panelNSText : .textColor)]
        }
        return [TerminalStandIn(view: composeView, lines: composeShadow.lines(),
                                background: Theme.composeNSBackground, text: Theme.composeNSText)]
    }

    var sessionCols: Int { session.cols }

    /// Called when a running command goes quiet: is it waiting for a password? Rechecked every 0.5 s
    /// while the prompt is up (cheap: one tcgetattr), so the 🔑 goes away once the password is entered.
    func checkSecretPrompt(_ item: CommandItem) {
        guard item.isLive, running === item, !item.panel else { return }
        let secret = session.isReadingSecret
        if item.awaitingSecret != secret { item.awaitingSecret = secret }
        if secret {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak item] in
                if let self, let item { self.checkSecretPrompt(item) }
            }
        }
    }

    // MARK: Bubble menu actions

    /// Types `text` into the prompt without running it (bracketed paste, like ⌘V).
    func pasteIntoPrompt(_ text: String) {
        guard !text.isEmpty, !ended else { return }
        composeView.pasteText(text)
        focusActive()
    }

    /// Runs a command again from the thread: clears whatever is half-typed first (Ctrl-U).
    func runAgain(_ command: String) {
        guard running == nil, !ended else { NSSound.beep(); return }
        sendFromKeyboard([0x15][...])
        sendFromKeyboard(Array((command + "\r").utf8)[...])
        focusActive()
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Plain text of the compose bar (self-tests).
    var composeText: String { composeShadow.plainText() }

    func clearThread() {
        entries.removeAll { if case .command(let c) = $0 { return !c.isLive } else { return true } }
        // Like Terminal.app's ⌘K: the classic view's scrollback goes too, so cleared text is really gone.
        classicView.feed(text: "\u{1B}[3J")
        classicShadow.feed(Array("\u{1B}[3J".utf8))
    }

    func terminate() { session.terminate() }

    // MARK: Bytes from the shell

    private func receive(_ slice: ArraySlice<UInt8>) {
        classicView.feed(byteArray: slice) // the classic terminal always gets every byte
        classicShadow.feed(Array(slice))
        for event in splitter.feed(slice) {
            switch event {
            case .promptStart:
                sawPrompt = true
                if let s = startupItem { s.finish(exit: nil); startupItem = nil }
                if integrationMissing {
                    integrationMissing = false
                    entries.append(.notice(UUID(), "Prompt marks arrived: bubbles are back on."))
                    focusActive()
                }
                resetCompose() // the compose bar shows only this prompt
                composeRows = 1
                if !script.isEmpty { session.send(script.removeFirst() + "\r") } else { scriptDone = true }
            case .prompt(let bytes):
                composeView.feed(byteArray: bytes[...])
                composeShadow.feed(bytes)
                updateComposeRows()
            case .commandStart(let cmd):
                let item = CommandItem(command: cmd, cols: session.cols, rows: session.rows)
                item.onRefresh = { [weak self] in self?.contentGrew() }
                item.pane = self
                item.cwd = cwd
                item.noteActivity() // a command that prints nothing at first gets the typing dots too
                running = item
                entries.append(.command(item))
                resumeFollowing() // a new command always brings the thread to the bottom
                if let c = cmd, policy.wantsPanel(c) { startPanel(item) }
                resetCompose()
                composeRows = 1
            case .output(let bytes):
                if let item = running {
                    // While the full terminal shows the program, the thread waits; output after it
                    // (e.g. git's summary after the commit-message editor) goes back into the bubble.
                    if !panelActive { item.feed(bytes) }
                } else if let s = startupItem {
                    s.feed(bytes)
                } else if !bytes.allSatisfy({ $0 == 0x0D || $0 == 0x0A }) {
                    let item = CommandItem(command: nil, cols: session.cols, rows: session.rows)
                    item.onRefresh = { [weak self] in self?.contentGrew() }
                    item.feed(bytes)
                    startupItem = item
                    entries.append(.command(item))
                }
            case .commandEnd(let code):
                running?.finish(exit: code)
                running = nil
                enforceMemoryBudget()
                if findVisible { recomputeMatches() }
                if panelActive { panelActive = false; panelByAltScreen = false; focusActive() }
            case .altScreen(let on):
                if on, !panelActive {
                    panelByAltScreen = true
                    if let item = running { startPanel(item) } else { panelActive = true; focusActive() } // fzf, ⌃X⌃E at the prompt
                } else if !on, panelByAltScreen {
                    panelByAltScreen = false
                    panelActive = false
                    focusActive()
                }
            }
        }
    }

    /// Finished output kept per pane; past this the oldest bubbles keep only their first 10 + last 20 lines.
    static let lineBudget = 50_000

    private func enforceMemoryBudget() {
        let items = entries.compactMap { e -> CommandItem? in if case .command(let c) = e { return c } else { return nil } }
        var total = items.reduce(0) { $0 + $1.lines.count }
        for item in items where total > Self.lineBudget && !item.isLive && !item.compacted {
            let before = item.lines.count
            item.compact()
            total -= before - item.lines.count
        }
    }

    /// The classic view is one terminal shown two ways: full pane (system look) or in-thread panel (theme).
    func restyleClassic() { Theme.style(classicView, role: showsPanel ? .panel : .classic) }

    private func startPanel(_ item: CommandItem) {
        item.panel = true
        panelActive = true
        focusActive()
    }

    /// Soft reset (DECSTR) + clear screen and scrollback. Not RIS (ESC c): that also resets the
    /// terminal's colours to its defaults, which painted a white compose bar on dark themes.
    private func resetCompose() {
        let clear = "\u{1B}[!p\u{1B}[H\u{1B}[2J\u{1B}[3J"
        composeView.feed(text: clear)
        composeShadow.terminal.feed(text: clear)
    }

    private func updateComposeRows() {
        let n = composeShadow.lines().count
        composeRows = max(1, min(Self.composeMaxRows, n))
    }

    private func shellExited() {
        ended = true
        running?.finish(exit: nil)
        running = nil
        panelActive = false
        entries.append(.notice(UUID(), "Session ended. Press ⌘W to close."))
        contentGrew()
    }

    // MARK: From the terminal views

    /// Diagnostics: sees every byte sent to the shell (probes only).
    var debugTap: (([UInt8]) -> Void)?

    func sendFromKeyboard(_ data: ArraySlice<UInt8>) {
        debugTap?(Array(data))
        if !ended { session.send(data) }
    }

    private var pendingResize: DispatchWorkItem?

    /// The visible terminal resizes itself at once; the shell, shadows and live bubble follow when the
    /// drag pauses, so a window drag doesn't reflow 10k-line scrollbacks on every column.
    func classicResized(cols: Int, rows: Int) {
        pendingResize?.cancel()
        guard classicView.inLiveResize else { applyResize(cols: cols, rows: rows); return }
        let work = DispatchWorkItem { [weak self] in self?.applyResize(cols: cols, rows: rows) }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func applyResize(cols: Int, rows: Int) {
        session.resize(cols: cols, rows: rows)
        classicShadow.resize(cols: cols, rows: rows)
        composeShadow.resize(cols: cols)
        running?.resize(cols: cols)
    }

    func cwdChanged(_ path: String) { cwd = path }

    func titleChanged(_ t: String) {
        title = t.isEmpty ? "Better Terminal" : t
        host?.objectWillChange.send()
    }
}
