import Foundation
import Testing
@testable import BTCore

private let ESC = "\u{1B}"
private let BEL = "\u{07}"
private func A() -> String { "\(ESC)]133;A\(BEL)" }
private func B() -> String { "\(ESC)]133;B\(BEL)" }
private func C(_ cmd: String? = nil) -> String {
    (cmd.map { "\(ESC)]1337;BTCmd=\(Data($0.utf8).base64EncodedString())\(BEL)" } ?? "") + "\(ESC)]133;C\(BEL)"
}
private func D(_ code: Int) -> String { "\(ESC)]133;D;\(code)\(BEL)" }

/// Feeds `stream` in chunks of `chunk` bytes (1 = worst case) and merges adjacent byte events.
private func split(_ stream: String, chunk: Int = .max) -> [SplitterEvent] {
    let s = Splitter()
    let bytes = Array(stream.utf8)
    var events: [SplitterEvent] = []
    var i = 0
    while i < bytes.count {
        let end = min(bytes.count, i + max(1, min(chunk, bytes.count)))
        events += s.feed(bytes[i..<end])
        i = end
    }
    var merged: [SplitterEvent] = []
    for e in events {
        switch (merged.last, e) {
        case (.output(let a)?, .output(let b)): merged[merged.count - 1] = .output(a + b)
        case (.prompt(let a)?, .prompt(let b)): merged[merged.count - 1] = .prompt(a + b)
        default: merged.append(e)
        }
    }
    return merged
}
private func out(_ s: String) -> SplitterEvent { .output(Array(s.utf8)) }
private func pr(_ s: String) -> SplitterEvent { .prompt(Array(s.utf8)) }

@Suite struct SplitterTests {
    let oneCommand = D(0) + A() + "~ % " + B() + "ls\r\n" + C("ls") + "a  b\r\n" + D(0) + A() + "~ % " + B()

    @Test func plainCommand() {
        #expect(split(oneCommand) == [
            .promptStart, pr("~ % ls\r\n"), .commandStart("ls"), out("a  b\r\n"), .commandEnd(0),
            .promptStart, pr("~ % "),
        ])
    }

    @Test func byteAtATimeGivesSameResult() {
        #expect(split(oneCommand, chunk: 1) == split(oneCommand))
        #expect(split(oneCommand, chunk: 3) == split(oneCommand))
    }

    @Test func carriageReturnProgressStaysInOneOutput() {
        let s = A() + B() + C("dl") + "\r10%\r20%\r30%" + D(0)
        #expect(split(s) == [.promptStart, .commandStart("dl"), out("\r10%\r20%\r30%"), .commandEnd(0)])
    }

    @Test func cursorUpRedrawStaysInOneOutput() {
        let body = "a 0%\r\nb 0%\r\n\(ESC)[2A\ra 9%\r\n\rb 9%\r\n"
        let s = A() + C("pull") + body + D(0)
        #expect(split(s, chunk: 1) == [.promptStart, .commandStart("pull"), out(body), .commandEnd(0)])
    }

    @Test func failureExitCode() {
        #expect(split(A() + C("false") + D(1)) == [.promptStart, .commandStart("false"), .commandEnd(1)])
    }

    @Test func spuriousDIsIgnored() {
        // First precmd and Ctrl-C at the prompt send D without a C.
        #expect(split(D(0) + A() + "% ^C\r\n" + D(130) + A()) == [.promptStart, pr("% ^C\r\n"), .promptStart])
    }

    @Test func alternateScreenIsReportedAndPassedThrough() {
        let on = "\(ESC)[?1049h", off = "\(ESC)[?1049l"
        let s = A() + C("vim") + on + "screen" + off + "bye" + D(0)
        #expect(split(s, chunk: 2) == [
            .promptStart, .commandStart("vim"), out(on), .altScreen(true), out("screen" + off), .altScreen(false),
            out("bye"), .commandEnd(0),
        ])
    }

    @Test func otherEscapesPassThroughUnchanged() {
        let body = "\(ESC)[31mred\(ESC)[0m \(ESC)]8;;https://x\(ESC)\\link\(ESC)]8;;\(ESC)\\ \(ESC)(B\(ESC)=end"
        #expect(split(A() + C() + body + D(0), chunk: 1) == [.promptStart, .commandStart(nil), out(body), .commandEnd(0)])
    }

    @Test func stTerminatedMarksWork() {
        let s = "\(ESC)]133;A\(ESC)\\" + "\(ESC)]133;C\(ESC)\\" + "x" + "\(ESC)]133;D;2\(ESC)\\"
        #expect(split(s, chunk: 1) == [.promptStart, .commandStart(nil), out("x"), .commandEnd(2)])
    }

    @Test func startupOutputBeforeFirstPrompt() {
        #expect(split("motd\r\n" + A()) == [out("motd\r\n"), .promptStart])
    }

    @Test func unicodeCommandText() {
        #expect(split(A() + C("echo café 🎉") + D(0)) == [.promptStart, .commandStart("echo café 🎉"), .commandEnd(0)])
    }

    @Test func nestedShellMarksKeepWorking() {
        // `zsh` started inside zsh: its own prompts arrive while the outer command runs.
        let s = A() + C("zsh") + D(0) + A() + "inner % " + C("echo hi") + "hi\r\n" + D(0) + A()
        #expect(split(s) == [
            .promptStart, .commandStart("zsh"), .commandEnd(0), .promptStart, pr("inner % "),
            .commandStart("echo hi"), out("hi\r\n"), .commandEnd(0), .promptStart,
        ])
    }

    @Test func noBytesAreLostOrAdded() {
        // Everything except our own marks must come out exactly once, in order.
        let noise = "\(ESC)[?25l\(ESC)[2K\r\(ESC)[1;32mok\(ESC)[m\(ESC)]0;title\(BEL)\(ESC)[?1049h\(ESC)[?1049l\u{1B}\u{1B}x"
        let s = A() + "p " + C("c") + noise + D(0)
        var got: [UInt8] = []
        for e in split(s, chunk: 1) {
            if case .output(let b) = e { got += b }
            if case .prompt(let b) = e { got += b }
        }
        #expect(got == Array(("p " + noise).utf8))
    }
}

@Suite struct ScreenTests {
    @Test func progressBarCollapsesToFinalState() {
        let s = Screen(cols: 40, rows: 10)
        s.feed(Array("\r10%\r20%\r100%\r\n".utf8))
        #expect(s.plainText() == "100%")
    }

    @Test func multiLineRedraw() {
        let s = Screen(cols: 40, rows: 10)
        s.feed(Array("a 0%\r\nb 0%\r\n\u{1B}[2A\ra 9%\r\n\rb 9%\r\n".utf8))
        #expect(s.plainText() == "a 9%\nb 9%")
    }

    @Test func coloursAndBoldAreKept() {
        let s = Screen(cols: 40, rows: 5)
        s.feed(Array("\u{1B}[31mred\u{1B}[0m \u{1B}[1mbold\u{1B}[0m".utf8))
        let runs = s.lines()[0]
        #expect(runs.first?.text == "red" && runs.first?.fg == .ansi256(code: 1))
        #expect(runs.contains { $0.text.hasPrefix("bold") && $0.bold })
    }

    @Test func longOutputKeepsScrollback() {
        let s = Screen(cols: 20, rows: 5)
        s.feed(Array((1...50).map { "line \($0)\r\n" }.joined().utf8))
        let t = s.plainText().split(separator: "\n")
        #expect(t.count == 50 && t.first == "line 1" && t.last == "line 50")
    }
}

@Suite struct ShellIntegrationTests {
    @Test func installWritesFourFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-int-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ShellIntegration.install(in: dir)
        for f in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            #expect(text.contains("BT_USER_ZDOTDIR"))
        }
        let rc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        #expect(rc.contains("133;D") && rc.contains("BTCmd") && rc.contains("unsetopt PROMPT_SP"))
    }
}

@Suite struct PanelPolicyTests {
    let p = PanelPolicy()
    @Test(arguments: ["claude", "claude --resume", "/opt/homebrew/bin/claude", "ssh pc", "tmux a", "sudo -i",
                      "FOO=1 claude", "docker exec -it web sh", "kubectl exec -ti pod -- bash", "env -i bash",
                      "bash", "bash -l", "ssh -p 2222 user@host", "ssh -i ~/.ssh/k pc"])
    func panel(_ c: String) { #expect(p.wantsPanel(c)) }

    @Test(arguments: ["ls -la", "git status", "curl -O x", "brew upgrade", "sudo ls", "docker ps", "echo ssh", "make test",
                      "bash build.sh", "sh -c 'echo hi'", "ssh host uptime", "ssh -p 22 host ls /tmp", "zsh script.zsh"])
    func bubble(_ c: String) { #expect(!p.wantsPanel(c)) }
}

@Suite struct TerminalRepliesTests {
    private func b(_ s: String) -> ArraySlice<UInt8> { Array(s.utf8)[...] }
    @Test(arguments: ["\u{1B}[12;40R", "\u{1B}[?1;2c", "\u{1B}[>0;276;0c", "\u{1B}[0n", "\u{1B}[?2004;1$y",
                      "\u{1B}]11;rgb:0000/0000/0000\u{07}", "\u{1B}P>|SwiftTerm\u{1B}\\", "\u{1B}[?0u", "\u{1B}[8;24;80t"])
    func replies(_ s: String) { #expect(TerminalReplies.isQueryReply(b(s))) }

    @Test(arguments: ["echo hi", "\u{1B}[200~echo hi\u{1B}[201~", "multi\nline\n", "\u{1B}[A", "x", "\u{1B}OA", "ls -la ~/Projects"])
    func notReplies(_ s: String) { #expect(!TerminalReplies.isQueryReply(b(s))) }
}

@Suite struct ScreenIncrementalTests {
    /// The incremental cache must always equal a fresh full conversion.
    private func fresh(_ s: Screen, _ bytes: [UInt8], cols: Int, rows: Int, scrollback: Int) -> [String] {
        let f = Screen(cols: cols, rows: rows, scrollback: scrollback); f.feed(bytes)
        return f.lines().map { $0.map(\.text).joined() }
    }

    @Test func matchesFullConversionAcrossUpdates() {
        let s = Screen(cols: 30, rows: 5, scrollback: 100)
        var all: [UInt8] = []
        let chunks = ["a\r\nb\r\nc\r\n", "\r10%", "\r50%", "\r\nline\r\n", "\u{1B}[2A\rX\r\n", String(repeating: "row\r\n", count: 20), "\r99%"]
        for c in chunks {
            let b = Array(c.utf8); all += b; s.feed(b)
            #expect(s.lines().map { $0.map(\.text).joined() } == fresh(s, all, cols: 30, rows: 5, scrollback: 100))
        }
    }

    @Test func cappedScrollbackDropsFromTheFront() {
        let s = Screen(cols: 20, rows: 4, scrollback: 10)
        for i in 1...50 { s.feed(Array("n\(i)\r\n".utf8)); _ = s.lines() }
        let t = s.lines().map { $0.map(\.text).joined() }
        #expect(t.last == "n50" && t.count == 13 && s.droppedLines > 0)
    }

    @Test func resizeRebuilds() {
        let s = Screen(cols: 10, rows: 4, scrollback: 50)
        s.feed(Array("abcdefghijklmno\r\n".utf8)); _ = s.lines()
        s.resize(cols: 20)
        #expect(s.plainText().contains("abcdefghij"))
    }

    @Test func backgroundOnlyCellsAreKept() {
        let s = Screen(cols: 20, rows: 3)
        s.feed(Array("ok\u{1B}[42m   \u{1B}[0m".utf8))
        #expect(s.lines()[0].contains { $0.bg != .defaultColor && $0.text == "   " })
    }
}

@Suite struct RobustnessTests {
    private let E = "\u{1B}", G = "\u{07}"
    private func run(_ s: Splitter, _ text: String) -> [SplitterEvent] { s.feed(Array(text.utf8)) }
    private func ends(_ ev: [SplitterEvent]) -> Bool { ev.contains(.commandEnd(0)) }

    @Test func interruptedCSIDoesNotSwallowTheEndMark() {
        let s = Splitter()
        _ = run(s, "\(E)]133;A\(G)\(E)]133;C\(G)partial \(E)[1")
        #expect(ends(run(s, "\(E)]133;D;0\(G)\(E)]133;A\(G)")))
    }

    @Test func unterminatedOSCDoesNotSwallowTheEndMark() {
        let s = Splitter()
        _ = run(s, "\(E)]133;A\(G)\(E)]133;C\(G)\(E)]0;title never ends")
        #expect(ends(run(s, "\(E)]133;D;0\(G)")))
    }

    @Test func cancelAbortsASequence() {
        let s = Splitter()
        _ = run(s, "\(E)]133;A\(G)\(E)]133;C\(G)\(E)[12\u{18}x")
        #expect(ends(run(s, "\(E)]133;D;0\(G)")))
    }

    @Test func nonceIgnoresForeignAndFakeMarks() {
        let s = Splitter(nonce: "n1")
        let ev = run(s, "\(E)]133;A;bt=n1\(G)\(E)]1337;BTCmd=n1;\(Data("ls".utf8).base64EncodedString())\(G)\(E)]133;C\(G)\(E)]133;C;bt=n1\(G)fake: \(E)]133;D;0\(G) real\(E)]133;D;0;bt=n1\(G)")
        #expect(ev.contains(.commandStart("ls")))
        #expect(ev.filter { if case .commandEnd = $0 { return true } else { return false } }.count == 1)
        let text = ev.compactMap { if case .output(let b) = $0 { return String(decoding: b, as: UTF8.self) } else { return nil } }.joined()
        #expect(text.contains("fake:") && text.contains("133;D;0"))
    }

    @Test func labelNeverCarriesOverToTheNextCommand() {
        let s = Splitter()
        _ = run(s, "\(E)]133;A\(G)\(E)]1337;BTCmd=\(Data("ssh h".utf8).base64EncodedString())\(G)")
        let ev = run(s, "\(E)]133;A\(G)\(E)]133;C\(G)")
        #expect(ev.contains(.commandStart(nil)))
    }

    @Test func altScreenResetsAfterAKilledProgram() {
        let s = Splitter()
        _ = run(s, "\(E)]133;A\(G)\(E)]133;C\(G)\(E)[?1049h")   // vim killed: no ?1049l
        _ = run(s, "\(E)]133;D;137\(G)\(E)]133;A\(G)")
        #expect(run(s, "\(E)]133;C\(G)\(E)[?1049h").contains(.altScreen(true)))
    }

    @Test func clearRefreshesTheIncrementalCache() {
        let sc = Screen(cols: 20, rows: 4, scrollback: 50)
        sc.feed(Array((1...10).map { "old \($0)\r\n" }.joined().utf8)); _ = sc.lines()
        sc.feed(Array("\u{1B}[H\u{1B}[2J\u{1B}[3Jnew\r\n".utf8))
        #expect(sc.plainText() == "new")
    }
}

@Suite struct AcceptedLineTests {
    private let E = "\u{1B}", G = "\u{07}"
    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    @Test func parseErrorGetsABubble() {
        let s = Splitter()
        let ev = s.feed(Array("\(E)]133;A\(G)% bad )\(E)]1337;BTAccept=\(b64("bad )"))\(G)\r\nzsh: parse error near `)'\r\n\(E)]133;D;1\(G)\(E)]133;A\(G)% ".utf8))
        #expect(ev.contains(.commandStart("bad )")))
        #expect(ev.contains(.commandEnd(1)))
        let out = ev.compactMap { if case .output(let b) = $0 { return String(decoding: b, as: UTF8.self) } else { return nil } }.joined()
        #expect(out.contains("parse error"))
    }

    @Test func normalCommandIsNotDoubled() {
        let s = Splitter()
        let ev = s.feed(Array("\(E)]133;A\(G)% ls\(E)]1337;BTAccept=\(b64("ls"))\(G)\r\n\(E)]1337;BTCmd=\(b64("ls"))\(G)\(E)]133;C\(G)a b\r\n\(E)]133;D;0\(G)\(E)]133;A\(G)".utf8))
        #expect(ev.filter { if case .commandStart = $0 { return true } else { return false } }.count == 1)
    }

    @Test func silentAcceptedLineHasNoBadge() {
        let s = Splitter()
        let ev = s.feed(Array("\(E)]133;A\(G)% # note\(E)]1337;BTAccept=\(b64("# note"))\(G)\r\n\(E)]133;D;0\(G)\(E)]133;A\(G)".utf8))
        #expect(ev.contains(.commandStart("# note")) && ev.contains(.commandEnd(nil)))
    }
}

@Suite struct VisibleTextTests {
    @Test func redrawCodesAreNotOutput() {
        #expect(!Splitter.hasVisibleText(Array("\r\n\u{1B}[K\u{1B}[?2004l\u{1B}]7;file://x/y\u{07}\r".utf8)))
        #expect(Splitter.hasVisibleText(Array("\u{1B}[K zsh: parse error\r\n".utf8)))
    }

    @Test func leadingNewlineAndModeCodesAreDropped() {
        #expect(Splitter.droppingLeadingBlank(Array("\u{1B}[?2004l\r\r\nzsh: parse error\r\n".utf8)) == Array("zsh: parse error\r\n".utf8))
    }

    @Test func commentOnlyLineHasNoStaleExitCode() {
        let E = "\u{1B}", G = "\u{07}", s = Splitter()
        let ev = s.feed(Array("\(E)]133;A\(G)% \(E)]1337;BTAccept=\(Data("# note".utf8).base64EncodedString())\(G)\r\n\(E)[?2004l\(E)]133;D;127\(G)\(E)]133;A\(G)".utf8))
        #expect(ev.contains(.commandStart("# note")) && ev.contains(.commandEnd(nil)) && !ev.contains(.commandEnd(127)))
    }
}
