import AppKit
import BTCore
import SwiftUI

/// `BetterTerminal --gate-tests`: the Launch gate's automatable end-to-end tests (architecture.md T2–T7),
/// in a real window on the pointer's screen, with real zsh. Writes no settings and no shell history.
@MainActor
enum GateTests {
    static var ok = true
    static func check(_ id: String, _ cond: Bool, _ what: String) {
        print("\(cond ? "PASS" : "FAIL")  \(id)  \(what)")
        if !cond { ok = false }
    }
    static func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    static func until(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let d = Date().addingTimeInterval(timeout)
        while !cond() && Date() < d { pump(0.03) }
        return cond()
    }

    static func items(_ p: PaneModel) -> [CommandItem] {
        p.entries.compactMap { if case .command(let c) = $0 { return c } else { return nil } }
    }
    static func text(_ c: CommandItem) -> String { c.lines.map { $0.map(\.text).joined() }.joined(separator: "\n") }

    /// Runs one command and waits for it to finish. Returns its bubble.
    static func run(_ p: PaneModel, _ cmd: String, timeout: Double = 30) -> CommandItem? {
        let before = items(p).count
        p.runScript([cmd])
        _ = until(timeout) { items(p).count > before && items(p).last?.isLive == false && p.running == nil }
        let new = items(p).dropFirst(before)
        return new.count == 1 ? new.first : new.last
    }

    /// Starts an interactive program, waits for the panel, then types `quit`.
    static func panelProgram(_ p: PaneModel, _ cmd: String, quit: String) -> (opened: Bool, closed: Bool, chip: Bool) {
        let before = items(p).count
        p.runScript([cmd])
        let opened = until(10) { p.showsPanel }
        pump(0.6)
        p.sendFromKeyboard(Array(quit.utf8)[...])
        let closed = until(10) { !p.panelActive && p.running == nil }
        let item = items(p).dropFirst(before).first
        return (opened, closed, item?.panel == true && item?.isLive == false)
    }

    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Prefs.shared.persist = false
        Prefs.shared.theme = ThemeData()

        let model = WindowModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Better Terminal: Launch tests (closes by itself)"
        window.contentView = NSHostingView(rootView: WindowView(model: model))
        WindowModel.moveToPointerScreen(window, force: true)
        window.orderFrontRegardless()
        let p = model.focused
        _ = until(10) { p.composeText.contains("%") }

        let tmp = "/tmp/bt-gate-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // T2: live progress output stays one bubble, finishes cleanly.
        if let c = run(p, "curl -# -o /dev/null file:///usr/share/dict/words") {
            check("T2", c.exitCode == 0 && text(c).contains("100"), "curl progress bar: one bubble, ends at 100%")
        } else { check("T2", false, "curl ran") }
        if let c = run(p, "git clone --progress /tmp/bt-src/SwiftTerm \(tmp)/clone") {
            check("T2", c.exitCode == 0 && text(c).contains("done"), "git clone with progress: one bubble, exit 0")
        } else { check("T2", false, "git clone ran") }
        if let c = run(p, "pip3 --version") { check("T2", c.exitCode == 0 && text(c).contains("pip"), "pip3 --version") }
        if let c = run(p, "brew --version") { check("T2", c.exitCode == 0 && text(c).contains("Homebrew"), "brew --version") }

        // T3: full-screen programs open in the panel and leave a chip.
        for (cmd, quit) in [("less /etc/hosts", "q"), ("man zsh", "q"), ("top", "q"), ("vim -u NONE -N", ":q!\r")] {
            let r = panelProgram(p, cmd, quit: quit)
            check("T3", r.opened && r.closed && r.chip, "\(cmd): panel opened, closed on quit, chip left")
        }

        // T4: kill switch, per pane mid-command, global, and safe mode.
        p.runScript(["sleep 1.5"])
        _ = until(5) { p.running != nil }
        p.toggleClassic()
        let midClassic = p.showsFullClassic
        p.toggleClassic()
        _ = until(5) { p.running == nil }
        check("T4", midClassic && !p.showsFullClassic && items(p).last?.exitCode == 0, "⌘\\ mid-command switches and comes back; the command finishes")
        Prefs.shared.classicEverywhereStored = true; pump(0.2)
        let global = model.panes.allSatisfy(\.showsFullClassic)
        Prefs.shared.classicEverywhereStored = false; pump(0.2)
        check("T4", global && !p.showsFullClassic, "⌘⇧\\ classic everywhere on and off")

        // T5: parity with a normal terminal.
        p.sendFromKeyboard(Array("ech\t".utf8)[...])
        check("T5", until(5) { p.composeText.contains("echo") }, "Tab completion in the compose bar (ech → echo)")
        p.sendFromKeyboard([0x15][...]) // Ctrl-U clears the line
        _ = run(p, "echo bt-history-marker")
        p.sendFromKeyboard([0x12][...]); p.sendFromKeyboard(Array("bt-hist".utf8)[...])
        check("T5", until(5) { p.composeText.contains("bt-history-marker") }, "Ctrl-R finds the earlier command")
        p.sendFromKeyboard([0x07][...]); pump(0.2); p.sendFromKeyboard([0x15][...]); pump(0.2) // Ctrl-G, Ctrl-U

        p.runScript(["sleep 30"])
        _ = until(5) { p.running != nil }
        pump(0.3)
        p.sendFromKeyboard([0x03][...])
        _ = until(5) { p.running == nil }
        check("T5", items(p).last?.exitCode == 130, "Ctrl-C stops a command (exit 130, shown as interrupted)")

        p.runScript(["sleep 30"])
        _ = until(5) { p.running != nil }
        pump(0.3)
        p.sendFromKeyboard([0x1A][...]) // Ctrl-Z
        _ = until(5) { p.running == nil }
        let suspendCode = items(p).last?.exitCode
        let suspended = suspendCode == 128 + SIGTSTP // 146 on macOS (SIGTSTP = 18)
        p.runScript(["fg"])
        _ = until(5) { p.running != nil }
        pump(0.3)
        p.sendFromKeyboard([0x03][...])
        _ = until(5) { p.running == nil }
        check("T5", suspended && items(p).last?.exitCode == 130,
              "Ctrl-Z suspends (exit \(suspendCode.map(String.init) ?? "-")), fg resumes, Ctrl-C ends it (exit \(items(p).last?.exitCode.map(String.init) ?? "-"))")

        if let c = run(p, #"for i in 196 46 21 226; do printf "\e[38;5;${i}m█\e[0m"; done; echo"#) {
            let codes = Set(c.lines.flatMap { $0 }.compactMap { r -> UInt8? in if case .ansi256(let k) = r.fg { return k } else { return nil } })
            check("T5", codes.isSuperset(of: [196, 46, 21, 226]), "256-colour output keeps its colours")
        }
        if let c = run(p, "echo 'café 🎉 日本語 ✓'") { check("T5", text(c).contains("café 🎉 日本語 ✓"), "Unicode and emoji") }

        let body = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let before = items(p).count
        p.composeView.pasteText("cat <<'BTEOF'\n" + body + "\nBTEOF")
        p.sendFromKeyboard(Array("\r".utf8)[...])
        _ = until(15) { items(p).count > before && items(p).last?.isLive == false }
        if let c = items(p).last {
            check("T5", c.lines.count == 1000 && text(c).hasSuffix("line 1000"), "Pasting 1,000 lines runs as one command, one bubble (\(c.lines.count) lines)")
        }

        // T5: right-click menus (CEO request). No real clipboard is read or written here.
        let menu = p.composeView.buildMenu()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        check("T5", titles == ["Copy", "Paste", "Select All", "Clear Thread", "Copy Screenshot of Pane", "Classic View"],
              "Right-click menu in the compose bar: \(titles.joined(separator: ", "))")
        let copyItem = menu.items[0], pasteItem = menu.items[1]
        let copyOffWithoutSelection = !p.classicView.validateUserInterfaceItem(copyItem) && p.classicView.validateUserInterfaceItem(pasteItem)
        p.classicView.selectAll(nil)
        check("T5", copyOffWithoutSelection && p.classicView.hasSelection && p.classicView.validateUserInterfaceItem(copyItem),
              "Copy is enabled only with a selection; Paste always")
        _ = until(5) { p.composeText.hasSuffix("%") }
        p.pasteIntoPrompt("echo via-right-click-paste")
        _ = until(5) { p.composeText.contains("via-right-click-paste") }
        let beforePaste = items(p).count
        p.sendFromKeyboard(Array("\r".utf8)[...])
        _ = until(5) { items(p).count > beforePaste && items(p).last?.isLive == false }
        check("T5", items(p).last.map { text($0) == "via-right-click-paste" } == true, "Bubble menu: Paste into Prompt types the text, Return runs it")
        let beforeAgain = items(p).count
        p.runAgain("echo run-again-ok")
        _ = until(5) { items(p).count > beforeAgain && items(p).last?.isLive == false }
        check("T5", items(p).last.map { $0.command == "echo run-again-ok" && $0.outputText == "run-again-ok" } == true,
              "Bubble menu: Run Again runs the command; Copy Output text is exact")

        // T5: Return reaches the prompt even when a bubble's read-only text has focus (CEO report).
        let readOnly = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        readOnly.isEditable = false
        window.contentView?.addSubview(readOnly)
        _ = until(5) { p.composeText.hasSuffix("%") }
        p.pasteIntoPrompt("echo enter-after-bubble-focus")
        _ = until(5) { p.composeText.contains("enter-after-bubble-focus") }
        window.makeFirstResponder(readOnly)
        let beforeEnter = items(p).count
        let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, characters: "\r",
                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        if let passed = AppDelegate.routeKey(ret) { window.sendEvent(passed) }
        _ = until(5) { items(p).count > beforeEnter && items(p).last?.isLive == false }
        check("T5", items(p).last.map { text($0) == "enter-after-bubble-focus" } == true,
              "Return runs the prompt even when a bubble's text has focus")
        readOnly.removeFromSuperview()

        // T5: still-working dots, 🔑 password prompts, errors that used to vanish, hints (CEO requests).
        p.runScript(["echo start; sleep 2; echo end"])
        _ = until(5) { p.running != nil }
        let gotQuiet = until(2) { p.running?.quiet == true }
        _ = until(5) { p.running == nil }
        check("T5", gotQuiet && items(p).last?.quiet == false && text(items(p).last!) == "start\nend",
              "Typing dots appear while a command is quiet and go away when it finishes")

        p.runScript([#"read -s "x?Password: "; echo; echo got-$x"#])
        let secret = until(5) { p.running?.awaitingSecret == true }
        if let a = model.window?.contentView, let img = Screenshot.capture(a, panes: [p]) { WindowSelfTest.save(img, "build/m5-password-prompt.png") }
        p.sendFromKeyboard(Array("abc\r".utf8)[...])
        _ = until(5) { p.running == nil }
        check("T5", secret && items(p).last.map { text($0).contains("got-abc") && !$0.awaitingSecret } == true,
              "🔑 shows while a password is asked (read -s) and clears after Return")

        if let c = run(p, "echo )") {
            check("T5", c.command == "echo )" && c.exitCode == 1 && text(c).contains("parse error") && (c.hint ?? "").hasPrefix("✏️"),
                  "A line zsh can't parse still gets a bubble with its error and a hint")
        }
        let beforeComment = items(p).count
        _ = until(5) { p.composeText.hasSuffix("%") }
        p.pasteIntoPrompt("# just a comment with it's apostrophe\necho after-comment")
        _ = until(5) { p.composeText.contains("after-comment") }
        p.sendFromKeyboard(Array("\r".utf8)[...])
        _ = until(5) { items(p).count > beforeComment && items(p).last?.isLive == false }
        let commentItems = items(p).dropFirst(beforeComment).map { "[\($0.label)] exit=\($0.exitCode.map(String.init) ?? "-") out=\(text($0).debugDescription)" }
        check("T5", items(p).count == beforeComment + 1 && items(p).last.map { text($0) == "after-comment" && $0.exitCode == 0 } == true,
              "Pasted snippets with # comments run as one command (comments ignored) \(commentItems)")
        if let c = run(p, "cat bt-no-such-file.txt") {
            check("T5", (c.hint ?? "").contains("📁 Ran in"), "Missing file: hint names the folder (\(c.hint ?? "none"))")
        }
        if let c = run(p, "bt-no-such-command") {
            check("T5", c.exitCode == 127 && (c.hint ?? "").hasPrefix("🔎"), "Unknown command: hint says it isn't installed or on PATH")
        }
        if let a = model.window?.contentView, let img = Screenshot.capture(a, panes: [p]) { WindowSelfTest.save(img, "build/m5-errors.png") }

        // T5: a pasted multi-line script keeps the compose bar one line while it runs (CEO report).
        check("T5", CommandItem.oneLine("# Step 1\ncd /tmp\n\n# Step 2\nsleep 1\necho done") == "cd /tmp (+4 lines)",
              "Multi-line command label: first real line + count (\(CommandItem.oneLine("# Step 1\ncd /tmp\n\n# Step 2\nsleep 1\necho done")))")
        let beforeScript = items(p).count
        _ = until(5) { p.composeText.hasSuffix("%") } // paste once the prompt is ready, as a person would
        p.pasteIntoPrompt("# Step 1: go somewhere\ncd /tmp\n\n# Step 2: wait a bit\nsleep 1.5\necho script-done")
        _ = until(5) { p.composeText.contains("script-done") }
        p.sendFromKeyboard(Array("\r".utf8)[...])
        _ = until(5) { p.running != nil }
        pump(0.9)
        let rowsWhileRunning = p.composeRows
        if let a = model.window?.contentView, let img = Screenshot.capture(a, panes: [p]) { WindowSelfTest.save(img, "build/m5-multiline-running.png") }
        _ = until(6) { items(p).count > beforeScript && items(p).last?.isLive == false }
        check("T5", rowsWhileRunning == 1 && items(p).count == beforeScript + 1 && items(p).last.map { text($0) == "script-done" } == true,
              "While a pasted script runs, the compose bar is one line (rows: \(rowsWhileRunning)); the script finishes")

        // T6: splits and resize.
        model.split(.sideBySide)
        let q = model.focused
        _ = until(10) { q.composeText.contains("%") }
        let colsBefore = q.sessionCols
        window.setContentSize(NSSize(width: 760, height: 560)); pump(0.6)
        check("T6", q.sessionCols < colsBefore && q.sessionCols > 10, "Window resize reaches the shell (\(colsBefore) → \(q.sessionCols) columns)")
        if let c = run(q, "tput cols") { check("T6", text(c).trimmingCharacters(in: .whitespaces) == "\(q.sessionCols)", "The shell sees the new width (tput cols = \(text(c)))") }
        check("T6", model.close(q) && model.panes.count == 1, "Closing the split keeps the first pane")

        // T6: ⌘N opens a window, ⌘T opens a tab (CEO report: ⌘N opened a tab).
        func openPaneWindow() -> (NSWindow, WindowModel) {
            let m = WindowModel()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: WindowView(model: m))
            w.orderFrontRegardless()
            _ = until(3) { m.window === w }
            pump(0.3)
            return (w, m)
        }
        let (newWin, newModel) = openPaneWindow()                      // like ⌘N
        let separate = (window.tabbedWindows?.contains(newWin) ?? false) == false
        WindowModel.pendingTabParent = window
        let (tabWin, tabModel) = openPaneWindow()                      // like ⌘T
        let tabbed = window.tabbedWindows?.contains(tabWin) ?? false
        check("T6", separate && tabbed, "⌘N opens a separate window (\(separate)); ⌘T opens a tab (\(tabbed))")
        for (w, m) in [(tabWin, tabModel), (newWin, newModel)] { m.closeAll(); w.orderOut(nil) }

        // T7: settings round-trip (what is saved is what loads).
        var t = ThemeData.presets[2]; t.blur = 7; t.fontSize = 15; t.panelPrograms = ["claude", "ssh"]
        let data = try? JSONEncoder().encode(t)
        let back = data.flatMap { try? JSONDecoder().decode(ThemeData.self, from: $0) }
        check("T7", back == t, "Theme settings save and load unchanged")
        // A theme saved by 0.4.2 or earlier, with the cut gradient option, still loads (as solid).
        let legacy = ##"{"name":"Midnight","background":"gradient","gradientTop":"#0B1020","gradientBottom":"#1A1033","fontSize":14}"##
        let old = try? JSONDecoder().decode(ThemeData.self, from: Data(legacy.utf8))
        check("T7", old?.background == .solid && old?.fontSize == 14, "A theme saved with the removed gradient option still loads")

        print(ok ? "GATE ALL PASS" : "GATE SOME FAILED")
        model.closeAll()
        window.orderOut(nil)
        exit(ok ? 0 : 1)
    }
}
