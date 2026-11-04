import AppKit
import BTCore
import SwiftTerm
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-selftest"), i + 1 < args.count {
            MainActor.assumeIsolated { SelfTest.run(output: args[i + 1]) }
        } else if let i = args.firstIndex(of: "--paste-text"), i + 1 < args.count {
            MainActor.assumeIsolated { PasteProbe.pasteText(args[i + 1]) }; exit(0)
        } else if args.contains("--paste-probe") {
            MainActor.assumeIsolated { PasteProbe.run() }; exit(0)
        } else if args.contains("--gate-tests") {
            MainActor.assumeIsolated { GateTests.run() }
        } else if args.contains("--bench") {
            MainActor.assumeIsolated { Bench.run() }
        } else if let i = args.firstIndex(of: "--window-selftest"), i + 1 < args.count {
            MainActor.assumeIsolated { WindowSelfTest.run(outputDir: args[i + 1]) }
        } else {
            BetterTerminalApp.main()
        }
    }
}

struct BetterTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var prefs = Prefs.shared

    var body: some Scene {
        // Opened files and URLs get a window opened with their LaunchTicket; ⌘N opens one with nil.
        WindowGroup(id: "pane", for: LaunchTicket.self) { $ticket in
            WindowView(ticket: ticket).frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 900, height: 650)
        // Opened files and URLs go to AppDelegate (OpenHandler); without this SwiftUI also opens an empty window per event.
        .handlesExternalEvents(matching: [])
        .commands { PaneCommands(prefs: prefs) }

        Settings { SettingsView() }
    }
}

struct PaneCommands: Commands {
    @ObservedObject var prefs: Prefs
    @FocusedObject private var window: WindowModel?
    @Environment(\.openWindow) private var openWindow

    private var pane: PaneModel? { window?.focused }

    var body: some Commands {
        // The menu bar exists before any window, so this is how a document launch opens its first one.
        let _ = AppActions.registerOpener(openWindow)
        CommandGroup(after: .newItem) {
            Button("New Tab") { AppActions.newTab(from: NSApp.keyWindow) }
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Split Side by Side") { window?.split(.sideBySide) }
                .keyboardShortcut("d", modifiers: .command).disabled(window == nil)
            Button("Split Top and Bottom") { window?.split(.stacked) }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(window == nil)
            Button("Close Pane") { closePane() }
                .keyboardShortcut("w", modifiers: .command).disabled(window == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { pane?.showFind() }
                .keyboardShortcut("f", modifiers: .command).disabled(pane == nil)
            Button("Find Next") { pane?.findStep(1) }
                .keyboardShortcut("g", modifiers: .command).disabled(pane?.findVisible != true)
            Button("Find Previous") { pane?.findStep(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(pane?.findVisible != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Screenshot of Pane") { if let p = pane { Screenshot.copy(pane: p) } }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(pane == nil)
            Button("Copy Screenshot of Window") { if let w = window { Screenshot.copyWindow(w) } }
                .disabled(window == nil) // menu only: a 4-key shortcut is hard to send from Windows
            Button("Clear Thread") { pane?.clearThread() }
                .keyboardShortcut("k", modifiers: .command).disabled(pane == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Bring Window to This Screen") {
                if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { WindowModel.model(for: $0) != nil }) {
                    WindowModel.moveToPointerScreen(w)
                    w.makeKeyAndOrderFront(nil)
                }
            }
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Toggle Classic View") { pane?.toggleClassic() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(pane == nil || prefs.classicEverywhere)
            Toggle("Classic View Everywhere", isOn: $prefs.classicEverywhereStored)
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(prefs.safeMode)
            Toggle("New Panes Start in Classic View", isOn: $prefs.defaultClassic)
            Divider()
            Button("Bigger Text") { prefs.theme.fontSize = min(24, prefs.theme.fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { prefs.theme.fontSize = max(9, prefs.theme.fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Default Text Size") { prefs.theme.fontSize = ThemeData().fontSize }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Menu("Select Pane") {
                Button("Left") { window?.moveFocus(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Right") { window?.moveFocus(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Up") { window?.moveFocus(.up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Down") { window?.moveFocus(.down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Next") { window?.cycleFocus(1) }.keyboardShortcut("]", modifiers: .command)
                Button("Previous") { window?.cycleFocus(-1) }.keyboardShortcut("[", modifiers: .command)
            }
            .disabled(window == nil)
        }
    }

    private func closePane() {
        guard let w = window else { return }
        let p = w.focused
        if p.isBusy {
            let alert = NSAlert()
            alert.messageText = "Close this pane?"
            alert.informativeText = "“\(p.running?.label ?? "A command")” is still running. Closing the pane stops it."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if !w.close(p) { w.window?.close() }
    }
}

/// Bridges AppKit callers (the tab bar's + button) to SwiftUI's openWindow.
@MainActor
enum AppActions {
    static var openPaneWindow: (() -> Void)?
    /// Opens a pane window for a queued file or URL (see OpenHandler).
    static var openTicketWindow: ((LaunchTicket) -> Void)?

    static func registerOpener(_ open: OpenWindowAction) {
        openTicketWindow = { open(id: "pane", value: $0) }
        if openPaneWindow == nil { openPaneWindow = { open(id: "pane") } }
    }

    /// Opens a pane window as a tab of `parent`, in the folder of `parent`'s focused pane.
    static func newTab(from parent: NSWindow?) {
        // The key window is the parent; if AppKit has none at this moment, the pane window used last.
        let parent = [parent, NSApp.mainWindow, WindowModel.lastActiveWindow].compactMap { $0 }
            .first { WindowModel.model(for: $0) != nil } ?? WindowModel.allModels.compactMap(\.window).first
        WindowModel.pendingTabParent = parent
        WindowModel.pendingCwd = WindowModel.model(for: parent)?.focused.cwd
        openPaneWindow?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var scrollMonitor: Any?

    /// Keys typed while the thread (not a terminal) has focus go to the focused pane's terminal.
    /// Only editable text (the Find field) keeps its keys. Read-only text, such as a bubble you clicked
    /// or selected, must not: it swallowed Return and ⌘V (CEO report: "Enter after paste does nothing").
    static func ownsTyping(_ r: NSResponder?) -> Bool {
        r is TerminalView || (r as? NSTextView)?.isEditable == true
    }

    static func installKeyMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { routeKey($0) }
    }

    /// The key monitor's decision. Returns the event to let it through, nil when it was handled here.
    static func routeKey(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, !ownsTyping(window.firstResponder),
              let target = MainActor.assumeIsolated({ WindowModel.model(for: window)?.focused.activeView })
        else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘V while the thread has focus: paste into the active terminal.
        if mods == .command, event.charactersIgnoringModifiers == "v" {
            window.makeFirstResponder(target)
            target.paste(event)
            return nil
        }
        // Other ⌘ shortcuts stay with the menus; plain typing goes to the terminal.
        guard !mods.contains(.command) else { return event }
        window.makeFirstResponder(target)
        target.keyDown(with: event)
        return nil
    }

    /// Implementing this in the responder chain makes macOS show the + button in the tab bar.
    @objc func newWindowForTab(_ sender: Any?) {
        MainActor.assumeIsolated { AppActions.newTab(from: NSApp.keyWindow) }
    }

    private var keyMonitor: Any?
    private var clickMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["BT_CHECK_NEW_WINDOW"] != nil { Prefs.shared.persist = false }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        if CommandLine.arguments.contains("--classic") { Prefs.shared.forceSafeMode() }
        keyMonitor = AppDelegate.installKeyMonitor()
        MainActor.assumeIsolated { OpenHandler.didFinishLaunching() }
        // Scrolling up in a thread stops it following new output.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                guard event.scrollingDeltaY != 0, let model = WindowModel.model(for: event.window) else { return }
                for pane in model.panes where !pane.showsFullClassic {
                    guard let a = pane.anchorView else { continue }
                    if a.bounds.contains(a.convert(event.locationInWindow, from: nil)) {
                        pane.userScrolled(up: event.scrollingDeltaY > 0)
                        break
                    }
                }
            }
            return event
        }
        // BT_CHECK_NEW_WINDOW=1: click File ▸ New Window and File ▸ New Tab through the real menus, report
        // windows vs tabs, quit. Verifies the real SwiftUI path (no history or settings written).
        if ProcessInfo.processInfo.environment["BT_CHECK_NEW_WINDOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("CHECK timed out"); exit(2) } // never hang
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                func click(_ title: String) {
                    for top in NSApp.mainMenu?.items ?? [] {
                        if let sub = top.submenu, let i = sub.items.firstIndex(where: { $0.title == title }) {
                            sub.performActionForItem(at: i); return
                        }
                    }
                    print("CHECK menu item not found: \(title)")
                }
                func panes() -> [NSWindow] { NSApp.windows.filter { w in MainActor.assumeIsolated { WindowModel.model(for: w) != nil } } }
                func groups() -> Int { Set(panes().map { ObjectIdentifier($0.tabGroup ?? NSWindowTabGroup()) }).count }
                let w0 = panes().count
                click("New Window")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let w1 = panes().count, g1 = groups()
                    NSApp.activate(ignoringOtherApps: true)
                    panes().first?.makeKeyAndOrderFront(nil)
                    print("CHECK before New Tab: keyWindow=\(NSApp.keyWindow != nil) mainWindow=\(NSApp.mainWindow != nil) lastActive=\(MainActor.assumeIsolated { WindowModel.lastActiveWindow } != nil)")
                    click("New Tab")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let w2 = panes().count, g2 = groups()
                        print("CHECK start: \(w0) window(s)")
                        print("CHECK after New Window: \(w1) windows in \(g1) separate group(s) -> \(w1 == w0 + 1 && g1 == w1 ? "PASS separate window" : "FAIL")")
                        print("CHECK after New Tab: \(w2) windows in \(g2) group(s) -> \(w2 == w1 + 1 && g2 == g1 ? "PASS joined as a tab" : "FAIL")")
                        MainActor.assumeIsolated { WindowModel.allModels.forEach { $0.closeAll() } }
                        exit(0)
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["BT_DUMP_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AppDelegate.dumpMenu(NSApp.mainMenu, depth: 0)
                NSApp.terminate(nil)
            }
        }
        // A click inside a pane makes it the focused pane (terminal views don't report focus changes).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard let model = WindowModel.model(for: event.window) else { return }
                for pane in model.panes {
                    guard let a = pane.anchorView else { continue }
                    if a.bounds.contains(a.convert(event.locationInWindow, from: nil)) { pane.didGainFocus(); break }
                }
            }
            return event
        }
    }

    /// Finder, `open` and links hand us scripts and ssh/telnet/x-man-page URLs, on a cold launch too.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenHandler.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting stops every running command and drops the threads (they live in memory): ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = MainActor.assumeIsolated { WindowModel.allModels.flatMap(\.panes).filter(\.isBusy) }
        guard !busy.isEmpty else { return .terminateNow }
        let names = MainActor.assumeIsolated { busy.compactMap { $0.running?.label }.prefix(3).joined(separator: ", ") }
        return Self.confirm("Quit Better Terminal?",
                            "\(busy.count) command\(busy.count == 1 ? " is" : "s are") still running (\(names)). Quitting stops \(busy.count == 1 ? "it" : "them") and clears every thread.",
                            button: "Quit") ? .terminateNow : .terminateCancel
    }

    static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Hang up every shell on quit, so zsh saves history and background jobs get SIGHUP.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { WindowModel.allModels.forEach { $0.closeAll() } }
    }

    /// BT_DUMP_MENU=1: prints every menu item with its shortcut (to check for clashes), then quits.
    static func dumpMenu(_ menu: NSMenu?, depth: Int) {
        for item in menu?.items ?? [] where !item.isSeparatorItem {
            var keys = ""
            if !item.keyEquivalent.isEmpty {
                let m = item.keyEquivalentModifierMask
                keys = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "")
                    + (m.contains(.command) ? "⌘" : "") + item.keyEquivalent
            }
            print(String(repeating: "  ", count: depth) + item.title + (keys.isEmpty ? "" : "  [\(keys)]"))
            if let sub = item.submenu { dumpMenu(sub, depth: depth + 1) }
        }
    }
}

/// `BetterTerminal --render-selftest out.png`: runs a fixed script in a real zsh through the real pane
/// model, renders the bubble thread to a PNG and prints a text summary. No window, no network.
@MainActor
enum SelfTest {
    static func run(output: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Prefs.shared.persist = false
        Prefs.shared.theme = ThemeData()
        let model = PaneModel()
        model.classicResized(cols: 72, rows: 24)
        model.script = [
            "cd /tmp && echo hello from Better Terminal",
            #"for i in 1 2 3 4 5 6 7 8 9 10; do printf "\rdownloading %3d%%" $((i*10)); sleep 0.03; done; echo"#,
            #"printf "\e[32mgreen\e[0m \e[1;31mbold red\e[0m \e[4munderline\e[0m\n""#,
            "ls /nonexistent-path",
            "seq 1 60",
            #"printf "\e[?1049hfull screen\e[?1049l""#,
        ]
        let deadline = Date().addingTimeInterval(20)
        while !model.scriptDone && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // last refresh
        model.terminate()

        for case .command(let item) in model.entries {
            let text = item.lines.map { $0.map(\.text).joined().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            print("[\(item.command ?? "(startup)")] exit=\(item.exitCode.map(String.init) ?? "-") panel=\(item.panel) lines=\(text.count) first=\(text.first ?? "")")
        }
        let view = ThreadSnapshot(model: model).frame(width: 640)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("render failed"); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: output))
        print("rendered \(output) (\(png.count) bytes), done=\(model.scriptDone)")
        exit(model.scriptDone ? 0 : 1)
    }
}

/// Non-scrolling copy of the thread for rendering to an image.
struct ThreadSnapshot: View {
    @ObservedObject var model: PaneModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.entries) { entry in
                if case .command(let item) = entry { CommandView(item: item) }
            }
        }
        .padding(16)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

/// `BetterTerminal --window-selftest dir`: an off-screen window with two split panes running real zsh,
/// a theme change, focus moves, and pane/window screenshots written to `dir` and to a private pasteboard.
@MainActor
enum WindowSelfTest {
    static func run(outputDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Prefs.shared.persist = false
        Prefs.shared.theme = ThemeData.presets.first { $0.name == "Midnight" }!
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("\(cond ? "PASS" : "FAIL")  \(what)"); if !cond { ok = false } }
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func waitFor(_ p: PaneModel) { let d = Date().addingTimeInterval(15); while !p.scriptDone && Date() < d { pump(0.05) } }

        let model = WindowModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WindowView(model: model))
        WindowModel.moveToPointerScreen(window, force: true) // visible on the CEO's screen (CEO request), not the projector
        window.title = "Better Terminal: self-test (closes by itself)"
        window.orderFrontRegardless()
        pump(0.5)

        let left = model.focused
        left.runScript(["cd /tmp", "echo left pane", #"for i in 1 2 3 4; do printf "\rbuilding %d/4" $i; sleep 0.05; done; echo"#, "false"])
        waitFor(left)

        model.split(.sideBySide)
        let right = model.focused
        check(model.panes.count == 2 && right !== left, "split side by side makes a second pane and focuses it")
        check(right.cwd == "/tmp", "split opens in the current folder (\(right.cwd ?? "nil"))")
        right.runScript(["echo right pane", "uname -s"])
        waitFor(right)
        pump(0.5)

        check(left.composeText.hasSuffix("%") || left.composeText.hasSuffix("#") || left.composeText.hasSuffix(">"),
              "left compose bar shows the prompt (\(left.composeText.debugDescription))")
        check(!right.composeText.isEmpty, "right compose bar shows the prompt (\(right.composeText.debugDescription))")
        model.moveFocus(.left)
        check(model.focused === left, "⌘⌥← moves focus to the left pane")
        model.moveFocus(.right)
        check(model.focused === right, "⌘⌥→ moves focus back to the right pane")

        let texts: (PaneModel) -> [String] = { p in
            p.entries.compactMap { if case .command(let c) = $0 { return c.lines.map { $0.map(\.text).joined() }.joined(separator: "|") } else { return nil } }
        }
        check(texts(left).contains { $0.contains("building 4/4") } && !texts(left).contains { $0.contains("building 1/4|") },
              "progress bar is one bubble in the left pane")
        check(texts(right).contains { $0.contains("Darwin") }, "right pane has its own shell and thread")

        // Pane screenshot → file + private pasteboard (the user's clipboard is not touched)
        let pb = NSPasteboard(name: NSPasteboard.Name("bt-selftest-\(getpid())"))
        if let a = left.anchorView, let img = Screenshot.capture(a, panes: [left]) {
            check(Screenshot.write(img, to: pb), "pane screenshot written to a pasteboard")
            let types = pb.pasteboardItems?.first?.types ?? []
            check(types.contains(.png) && types.contains(.tiff), "pasteboard has PNG and TIFF")
            save(img, outputDir + "/m2-pane-screenshot.png")
            check(img.size.width > 300 && img.size.width < 800, "pane screenshot is one pane wide (\(Int(img.size.width)) pt)")
        } else { check(false, "pane screenshot captured") }
        if let c = window.contentView, let img = Screenshot.capture(c, panes: model.panes) {
            save(img, outputDir + "/m2-window-screenshot.png")
            check(img.size.width >= 1000, "window screenshot spans both panes (\(Int(img.size.width)) pt)")
        } else { check(false, "window screenshot captured") }
        pb.releaseGlobally()

        // M3: find in thread
        right.showFind()
        right.findQuery = "darwin"
        check(right.findVisible && right.findMatches.count == 1, "⌘F finds 'darwin' once in the right pane")
        check(right.currentMatch == right.findMatches.first, "the match is selected")
        right.findQuery = "no-such-text"
        check(right.findMatches.isEmpty, "a missing word has no matches")
        right.closeFind()
        check(!right.findVisible && right.followBottom == false, "Done closes the find bar")
        right.resumeFollowing()

        // M3: scroll position
        right.runScript(["sleep 0.6; seq 1 5"])
        let d1 = Date().addingTimeInterval(5)
        while right.running == nil && Date() < d1 { pump(0.02) }
        right.userScrolled(up: true) // while the command runs
        check(!right.followBottom, "scrolling up stops following")
        waitFor(right)
        pump(0.3)
        check(right.newBelow, "new output while scrolled up shows 'Jump to latest'")
        right.resumeFollowing()
        check(right.followBottom && !right.newBelow, "'Jump to latest' resumes following")

        // M3: full-screen program in the in-thread panel
        try? "line one\nline two\n".write(toFile: "/tmp/bt-panel-test.txt", atomically: true, encoding: .utf8)
        left.runScript(["vim -u NONE -N /tmp/bt-panel-test.txt"])
        let deadline = Date().addingTimeInterval(8)
        while !left.panelActive && Date() < deadline { pump(0.05) }
        pump(0.8)
        check(left.showsPanel && !left.showsFullClassic, "vim runs in the in-thread panel, not the full pane")
        if let a = left.anchorView, let img = Screenshot.capture(a, panes: [left]) { save(img, outputDir + "/m3-panel-screenshot.png") }
        left.sendFromKeyboard(Array(":q!\r".utf8)[...])
        let d2 = Date().addingTimeInterval(8)
        while left.panelActive && Date() < d2 { pump(0.05) }
        pump(0.3)
        let lastPanel = left.entries.reversed().compactMap { if case .command(let c) = $0 { return c } else { return nil } }.first
        check(!left.showsPanel && lastPanel?.panel == true && lastPanel?.isLive == false, "after :q the panel closes and leaves a chip")
        try? FileManager.default.removeItem(atPath: "/tmp/bt-panel-test.txt")

        // Paste into the compose bar goes through SwiftTerm's paste path (CEO report: paste did nothing).
        right.composeView.pasteText("echo pasted-ok")
        right.runScript([])
        right.sendFromKeyboard(Array("\r".utf8)[...])
        let dp = Date().addingTimeInterval(5)
        while !right.entries.contains(where: { if case .command(let c) = $0 { return c.command == "echo pasted-ok" && !c.isLive } else { return false } }) && Date() < dp { pump(0.05) }
        check(right.entries.contains { if case .command(let c) = $0 { return c.command == "echo pasted-ok" && c.lines.first.map { $0.map(\.text).joined().hasPrefix("pasted-ok") } == true } else { return false } },
              "text pasted into the compose bar reaches the shell and runs")

        // Close the right pane: the left one takes focus and keeps its thread.
        check(model.close(right), "closing a pane with a sibling keeps the window")
        check(model.panes.count == 1 && model.focused === left, "the remaining pane is focused")
        check(!model.close(left), "closing the last pane asks the window to close")

        // Classic toggle keeps every byte (the classic terminal saw everything).
        left.toggleClassic(); pump(0.3)
        check(left.showsClassic, "⌘\\ switches the pane to classic view")
        if let a = left.anchorView, let img = Screenshot.capture(a, panes: [left]) {
            save(img, outputDir + "/m2-classic-screenshot.png")
            check(true, "classic view screenshot captured")
        } else { check(false, "classic view screenshot captured") }
        left.toggleClassic()

        // M3: new tab in the current folder
        WindowModel.pendingCwd = left.cwd
        let tabModel = WindowModel()
        check(tabModel.focused.cwd == left.cwd, "a new tab starts in the current folder")
        tabModel.closeAll()

        model.closeAll()
        window.orderOut(nil)
        print(ok ? "ALL PASS" : "SOME FAILED")
        exit(ok ? 0 : 1)
    }

    static func save(_ img: NSImage, _ path: String) {
        if let t = img.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// `BetterTerminal --bench`: an off-screen window with 3 panes running real zsh; prints CPU time and
/// memory footprint for idle, a big output flood, a long progress bar, many commands and a theme change.
@MainActor
enum Bench {
    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Prefs.shared.persist = false
        Prefs.shared.theme = ThemeData()
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func waitFor(_ p: PaneModel, _ t: Double = 120) { let d = Date().addingTimeInterval(t); while !p.scriptDone && Date() < d { pump(0.02) } }
        var peak = 0.0
        func measure(_ name: String, _ body: () -> Void) {
            let c0 = cpuSeconds(), t0 = Date()
            body()
            let wall = Date().timeIntervalSince(t0), cpu = cpuSeconds() - c0, mb = footprintMB()
            peak = max(peak, mb)
            print(String(format: "BENCH %-34@ wall %6.2f s  app CPU %6.2f s (%5.1f%%)  footprint %6.1f MB", name as NSString, wall, cpu, wall > 0 ? cpu / wall * 100 : 0, mb))
        }

        let model = WindowModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WindowView(model: model))
        WindowModel.moveToPointerScreen(window, force: true) // visible on the CEO's screen (CEO request), not the projector
        window.title = "Better Terminal: self-test (closes by itself)"
        window.orderFrontRegardless()
        model.split(.sideBySide); model.split(.stacked)
        let panes = model.panes
        let a = panes[0]
        pump(2)
        print(String(format: "BENCH start: 3 panes, footprint %.1f MB", footprintMB()))

        measure("idle 10 s (3 panes)") { pump(10) }
        measure("seq 1 200000 (one bubble)") { a.runScript(["seq 1 200000"]); waitFor(a); pump(0.5) }
        measure("progress bar 100 Hz for 8 s") {
            a.runScript([#"for i in $(seq 1 800); do printf "\r%3d%% [%-50s]" $((i/8)) "$(printf '#%.0s' $(seq 1 $((i/16+1))))"; sleep 0.01; done; echo"#])
            waitFor(a); pump(0.3)
        }
        measure("300 short commands") { a.runScript((1...300).map { "echo line \($0)" }); waitFor(a); pump(0.5) }
        measure("find: type 6 letters, 300+ commands") {
            a.showFind()
            for q in ["l", "li", "lin", "line", "line ", "line 2"] { a.findQuery = q; pump(0.02) }
            pump(0.2); a.closeFind(); a.resumeFollowing(); pump(0.2)
        }
        measure("seq 1 200000 then Show all") {
            a.runScript(["seq 1 200000"]); waitFor(a); pump(0.3)
            if case .command(let big)? = a.entries.last { big.expanded = true }
            pump(1.0)
        }
        // A 24 MP picture, like a Ricoh GR III frame, as the thread background; then a blur slider drag.
        let bgDir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-bench-bg-\(getpid())")
        try? FileManager.default.createDirectory(at: bgDir, withIntermediateDirectories: true)
        Prefs.backgroundsDirectory = bgDir
        if let ctx = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            for i in 0..<40 { ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1)); ctx.fill(CGRect(x: i * 150, y: 0, width: 150, height: 4000)) }
            if let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(bgDir.appendingPathComponent("big.jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
            }
        }
        measure("24 MP background + blur drag x20") {
            var t = Prefs.shared.theme; t.background = .image; t.backgroundImage = "big.jpg"; Prefs.shared.theme = t; pump(0.5)
            for b in 0..<20 { var t2 = Prefs.shared.theme; t2.blur = Double(b); Prefs.shared.theme = t2; pump(0.05) }
            pump(0.5)
        }
        try? FileManager.default.removeItem(at: bgDir)
        measure("theme change x20") {
            for i in 0..<20 { Prefs.shared.theme = ThemeData.presets[i % ThemeData.presets.count]; pump(0.05) }
            pump(0.5)
        }
        measure("idle 10 s after load") { pump(10) }
        print(String(format: "BENCH peak footprint %.1f MB; entries in pane A: %d", peak, a.entries.count))
        model.closeAll()
        exit(0)
    }
}
