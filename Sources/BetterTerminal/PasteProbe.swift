import AppKit
import SwiftUI

/// `BetterTerminal --paste-probe`: paste through the real ⌘V path (system clipboard), then press a real
/// Return key event in the compose bar, and report what the shell did. The user's clipboard is saved
/// first and restored at the end.
@MainActor
enum PasteProbe {
    /// `--paste-text <file>`: pastes the file's text into a test pane (no clipboard), presses Return,
    /// and prints what happened. For diagnosing "I pasted X and it didn't work".
    static func pasteText(_ path: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Prefs.shared.persist = false
        let model = WindowModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Better Terminal: paste diagnosis (closes by itself)"
        window.contentView = NSHostingView(rootView: WindowView(model: model))
        WindowModel.moveToPointerScreen(window, force: true)
        window.orderFrontRegardless()
        let p = model.focused
        _ = GateTests.until(10) { p.composeText.contains("%") }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        p.pasteIntoPrompt(text.hasSuffix("\n") ? String(text.dropLast()) : text)
        GateTests.pump(0.8)
        print("COMPOSE after paste:\n\(p.composeText)\n")
        let before = GateTests.items(p).count
        p.sendFromKeyboard(Array("\r".utf8)[...])
        GateTests.pump(3)
        print("COMPOSE after Return:\n\(p.composeText)\n")
        for c in GateTests.items(p).dropFirst(before) {
            print("BUBBLE exit=\(c.exitCode.map(String.init) ?? "running") command=\(c.command?.debugDescription ?? "nil")\n\(GateTests.text(c))\n")
        }
        print("running: \(p.running != nil)")
        model.closeAll()
    }

    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Prefs.shared.persist = false
        Prefs.shared.theme = ThemeData()
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
        defer {
            pb.clearContents()
            pb.writeObjects(saved.map { d in let i = NSPasteboardItem(); d.forEach { i.setData($0.value, forType: $0.key) }; return i })
            print("clipboard restored (\(saved.count) item(s))")
        }

        let model = WindowModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Better Terminal: paste probe (closes by itself)"
        window.contentView = NSHostingView(rootView: WindowView(model: model))
        WindowModel.moveToPointerScreen(window, force: true)
        window.makeKeyAndOrderFront(nil)
        let p = model.focused
        _ = GateTests.until(10) { p.composeText.contains("%") }
        GateTests.pump(0.3)

        for (label, clip) in [("plain", "echo probe-plain"), ("trailing newline", "echo probe-newline\n"), ("CRLF", "echo probe-crlf\r\n")] {
            pb.clearContents(); pb.setString(clip, forType: .string)
            window.makeFirstResponder(p.composeView)
            let before = GateTests.items(p).count
            var bytes: [UInt8] = []
            p.debugTap = { bytes += $0 }
            p.composeView.paste(NSApp) // the real ⌘V path
            GateTests.pump(0.5)
            let afterPaste = p.composeText
            let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36)!
            window.sendEvent(ret)
            let ran = GateTests.until(4) { GateTests.items(p).count > before && GateTests.items(p).last?.isLive == false }
            p.debugTap = nil
            let shown = bytes.map { $0 == 0x1B ? "␛" : $0 == 0x0D ? "⏎" : $0 == 0x0A ? "␊" : String(UnicodeScalar($0)) }.joined()
            print("\(ran ? "RAN " : "STUCK") \(label): compose after paste = \(afterPaste.debugDescription); bytes to shell = \(shown)")
            if !ran { p.sendFromKeyboard([0x03][...]); GateTests.pump(0.5) } // Ctrl-C to recover
        }
        // Focus on read-only text, as after clicking or selecting in a bubble; then real ⌘V and Return
        // through NSApp (so the app's key monitor sees them, like real typing).
        let monitor = AppDelegate.installKeyMonitor()
        let bubbleText = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        bubbleText.string = "selectable bubble text"
        bubbleText.isEditable = false
        bubbleText.isSelectable = true
        window.contentView?.addSubview(bubbleText)
        pb.clearContents(); pb.setString("echo probe-from-bubble-focus", forType: .string)
        window.makeFirstResponder(bubbleText)
        let responderBefore = String(describing: type(of: window.firstResponder!))
        let before = GateTests.items(p).count
        func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            // Through the app's own key routing (what the local monitor runs for real typing), then to the
            // window if not handled. A background test app can't receive real key events.
            if let passed = AppDelegate.routeKey(e) { window.sendEvent(passed) }
            GateTests.pump(0.2)
        }
        key("v", 9, .command)
        GateTests.pump(0.5)
        let afterPaste = p.composeText
        key("\r", 36)
        let ran = GateTests.until(4) { GateTests.items(p).count > before && GateTests.items(p).last?.isLive == false }
        print("\(ran ? "RAN " : "STUCK") focus on read-only bubble text: compose after ⌘V = \(afterPaste.debugDescription); first responder before = \(responderBefore)")
        if let m = monitor { NSEvent.removeMonitor(m) }
        model.closeAll()
        window.orderOut(nil)
    }
}
