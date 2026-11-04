import Foundation
import Testing
@testable import BTCore

private func plan(_ url: String) throws -> LaunchPlan { try OpenRequest.plan(forURLString: url) }

private func rejects(_ url: String, _ error: OpenRequestError) {
    #expect(throws: error) { try plan(url) }
}

/// Runs `printf '%s\0' <quoted args>` in a real zsh and returns the arguments zsh actually saw.
private func zshArguments(_ args: [String], shell: String = "/bin/zsh") throws -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["-f", "-c", "printf '%s\\0' " + args.map(OpenRequest.shellQuote).joined(separator: " ")]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
}

@Suite struct ShellQuoteTests {
    @Test func plainAndQuoted() {
        #expect(OpenRequest.shellQuote("abc") == "'abc'")
        #expect(OpenRequest.shellQuote("it's") == #"'it'\''s'"#)
        #expect(OpenRequest.shellQuote("") == "''")
    }

    @Test(arguments: ["/bin/zsh", "/bin/sh"])
    func roundTripsThroughARealShell(shell: String) throws {
        let nasty = ["a b", "it's", #""dq""#, "$HOME", "`id`", "$(id)", "*", "~", "!!", "a\\b", "-n", "'", "''", "é 日本", ";rm -rf x", "&&", "|"]
        #expect(try zshArguments(nasty, shell: shell) == nasty)
    }
}

@Suite struct FilePlanTests {
    @Test func runsFromItsFolder() throws {
        let p = try OpenRequest.plan(forFile: "/Users/me/bin/build.command")
        #expect(p.directory == "/Users/me/bin")
        #expect(p.argv == ["/Users/me/bin/build.command"])
        #expect(p.commandLine == "cd -- '/Users/me/bin' && '/Users/me/bin/build.command'")
    }

    @Test func spacesAndQuotes() throws {
        let p = try OpenRequest.plan(forFile: "/tmp/My Scripts/it's \"here\" $x.sh")
        #expect(p.directory == "/tmp/My Scripts")
        #expect(p.commandLine == #"cd -- '/tmp/My Scripts' && '/tmp/My Scripts/it'\''s "here" $x.sh'"#)
        #expect(try zshArguments([p.directory!] + p.argv) == ["/tmp/My Scripts", "/tmp/My Scripts/it's \"here\" $x.sh"])
    }

    @Test func fileURLDecodesPercentEscapes() throws {
        let p = try OpenRequest.plan(for: URL(fileURLWithPath: "/tmp/a b/run.tool"))
        #expect(p.argv == ["/tmp/a b/run.tool"])
        #expect(p.directory == "/tmp/a b")
    }

    @Test func fileAtRoot() throws {
        #expect(try OpenRequest.plan(forFile: "/x.sh").directory == "/")
    }

    @Test func rejectsRelativePath() {
        #expect(throws: OpenRequestError.notAbsolutePath("x.sh")) { try OpenRequest.plan(forFile: "x.sh") }
    }

    @Test(arguments: ["/tmp/a\nb.sh", "/tmp/a\rb", "/tmp/\u{1B}[31m.sh", "/tmp/a\u{7F}", "/tmp/\u{9B}x", "/tmp/a\tb", "/tmp/\u{03}"])
    func rejectsControlCharacters(path: String) {
        #expect(throws: OpenRequestError.controlCharacter(path)) { try OpenRequest.plan(forFile: path) }
    }
}

@Suite struct SSHPlanTests {
    @Test func fullURL() throws {
        let p = try plan("ssh://bob@example.com:2222")
        #expect(p.argv == ["ssh", "-p", "2222", "--", "bob@example.com"])
        #expect(p.directory == nil)
        #expect(p.commandLine == "'ssh' '-p' '2222' '--' 'bob@example.com'")
    }

    @Test func hostOnly() throws {
        #expect(try plan("ssh://example.com").argv == ["ssh", "--", "example.com"])
        #expect(try plan("ssh://example.com/").argv == ["ssh", "--", "example.com"])
        #expect(try plan("SSH://example.com").argv == ["ssh", "--", "example.com"])
    }

    @Test func ipv6Literal() throws {
        #expect(try plan("ssh://me@[::1]:22").argv == ["ssh", "-p", "22", "--", "me@::1"])
    }

    @Test func rejectsOptionInjection() {
        rejects("ssh://-oProxyCommand=evil", .invalidHost("-oProxyCommand=evil"))
        rejects("ssh://-oProxyCommand=evil@host", .invalidUser("-oProxyCommand=evil"))
    }

    @Test func rejectsBadHosts() {
        rejects("ssh://", .missingHost("ssh://"))
        rejects("ssh://bob@", .missingHost("ssh://bob@"))
        rejects("ssh://ho%20st", .invalidHost("ho st"))
        rejects("ssh://ho$t", .invalidHost("ho$t"))
    }

    @Test func rejectsBadUsers() {
        rejects("ssh://a%20b@host", .invalidUser("a b"))
        rejects("ssh://a%40b@host", .invalidUser("a@b"))
    }

    @Test func rejectsPassword() {
        rejects("ssh://bob:hunter2@host", .passwordInURL("ssh://bob:hunter2@host"))
    }

    @Test func rejectsBadPorts() {
        rejects("ssh://host:0", .invalidPort("ssh://host:0"))
        rejects("ssh://host:65536", .invalidPort("ssh://host:65536"))
        rejects("ssh://host:abc", .malformedURL("ssh://host:abc"))
    }

    @Test func rejectsExtraComponents() {
        rejects("ssh://host/etc/passwd", .unexpectedComponent("ssh://host/etc/passwd"))
        rejects("ssh://host?x=1", .unexpectedComponent("ssh://host?x=1"))
        rejects("ssh://host#frag", .unexpectedComponent("ssh://host#frag"))
    }

    @Test func rejectsControlCharacters() {
        rejects("ssh://host\n", .controlCharacter("ssh://host\n"))
    }
}

@Suite struct TelnetPlanTests {
    @Test func fullURL() throws {
        #expect(try plan("telnet://bob@towel.example:23").argv == ["telnet", "-l", "bob", "--", "towel.example", "23"])
    }

    @Test func hostOnly() throws {
        #expect(try plan("telnet://towel.example").argv == ["telnet", "--", "towel.example"])
    }

    @Test func rejectsOptionInjection() {
        rejects("telnet://-x", .invalidHost("-x"))
    }
}

@Suite struct ManPagePlanTests {
    @Test func name() throws {
        #expect(try plan("x-man-page://ls").argv == ["man", "--", "ls"])
        #expect(try plan("x-man-page://git-commit").argv == ["man", "--", "git-commit"])
        #expect(try plan("x-man-page://c++").argv == ["man", "--", "c++"])
    }

    @Test func sectionAndName() throws {
        #expect(try plan("x-man-page://3/printf").argv == ["man", "3", "--", "printf"])
        #expect(try plan("x-man-page://1ssl/openssl").argv == ["man", "1ssl", "--", "openssl"])
    }

    @Test func rejects() {
        for bad in ["x-man-page://", "x-man-page://-k", "x-man-page://ls/extra/more", "x-man-page://abc/printf",
                    "x-man-page://3/-k", "x-man-page://ls?x", "x-man-page://bob@ls", "x-man-page://ls$x"] {
            #expect(throws: OpenRequestError.self, "\(bad)") { try plan(bad) }
        }
    }
}

@Suite struct SchemeTests {
    @Test func rejectsOtherSchemes() {
        rejects("http://example.com", .unsupportedScheme("http://example.com"))
        rejects("not a url", .malformedURL("not a url"))
    }

    @Test func errorsAreReadable() {
        #expect(OpenRequestError.invalidPort("ssh://h:0").description.contains("1–65535"))
    }
}

@Suite struct OpenRouteTests {
    @Test func runningAppOpensAWindowPerTicket() {
        #expect(OpenRoute.decide(canOpenWindows: true, finishedLaunching: true) == .openWindow)
    }

    @Test func beforeLaunchFinishesItWaits() {
        #expect(OpenRoute.decide(canOpenWindows: false, finishedLaunching: false) == .waitForLaunch)
        #expect(OpenRoute.decide(canOpenWindows: true, finishedLaunching: false) == .waitForLaunch)
    }

    /// No opener after launch: the plan must not sit in the queue (QA attempt 2, MED).
    @Test func noOpenerAfterLaunchFails() {
        #expect(OpenRoute.decide(canOpenWindows: false, finishedLaunching: true) == .cannotOpen)
    }
}

private func filePlan(_ name: String) -> LaunchPlan { LaunchPlan(directory: "/tmp", argv: ["/tmp/\(name)"]) }

/// Ticketed queue: a window runs only the plan queued for it (QA attempt 2, MED).
@Suite struct LaunchQueueTests {
    @Test func eachTicketClaimsItsOwnPlan() {
        var q = LaunchQueue()
        let a = q.enqueue(filePlan("a")), b = q.enqueue(filePlan("b")), c = q.enqueue(filePlan("c"))
        #expect(q.tickets == [a, b, c])
        // Windows may appear in any order; each still gets its own plan.
        #expect(q.claim(b) == filePlan("b"))
        #expect(q.claim(c) == filePlan("c"))
        #expect(q.claim(a) == filePlan("a"))
        #expect(q.isEmpty)
    }

    @Test func nothingRunsTwice() {
        var q = LaunchQueue()
        let a = q.enqueue(filePlan("a"))
        #expect(q.claim(a) != nil)
        #expect(q.claim(a) == nil)
    }

    @Test func plainNewWindowGetsNothing() {
        var q = LaunchQueue()
        _ = q.enqueue(filePlan("a"))
        #expect(q.claim(nil) == nil)
        #expect(q.claim(LaunchTicket()) == nil) // a restored or foreign ticket
        #expect(q.count == 1)
    }

    @Test func drainReturnsLeftoversInOrderAndEmpties() {
        var q = LaunchQueue()
        let a = q.enqueue(filePlan("a"))
        _ = q.enqueue(filePlan("b"))
        _ = q.enqueue(filePlan("c"))
        _ = q.claim(a)
        #expect(q.drain() == [filePlan("b"), filePlan("c")])
        #expect(q.isEmpty)
        #expect(q.drain().isEmpty)
    }

    @Test func ticketsAreUnique() {
        var q = LaunchQueue()
        let t = (0..<100).map { q.enqueue(filePlan("\($0)")) }
        #expect(Set(t).count == 100)
    }
}

@Suite struct AlertTextTests {
    @Test func decodedUserIsEscapedInAlerts() {
        let d = OpenRequestError.invalidUser("\u{202E}evil\u{1B}").description
        #expect(!d.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x1B })
        #expect(d.contains(#"\u{202E}evil\u{1B}"#))
    }

    @Test func displaySafeEscapesOnlyNonASCII() {
        #expect(OpenRequest.displaySafe("a b'$") == "a b'$")
        #expect(OpenRequest.displaySafe("\u{2028}é") == #"\u{2028}\u{E9}"#)
    }

    @Test func plainTextStaysReadable() {
        #expect(OpenRequestError.invalidHost("ho st").description.hasSuffix("ho st"))
    }
}

/// Percent-decoded components must be validated after decoding (QA attempt 1, HIGH/MED).
@Suite struct DecodedComponentTests {
    static let encodedControls = ["%0A", "%0D", "%1B", "%03", "%15", "%7F", "%C2%85", "%E2%80%A8"]

    @Test(arguments: encodedControls)
    func sshUserRejectsEncodedControl(code: String) {
        #expect(throws: OpenRequestError.self) { try plan("ssh://u\(code)x@host") }
    }

    @Test(arguments: encodedControls)
    func telnetUserRejectsEncodedControl(code: String) {
        #expect(throws: OpenRequestError.self) { try plan("telnet://u\(code)x@host") }
    }

    @Test func userAllowlist() throws {
        #expect(try plan("ssh://a.b_c~d+e-f@host").argv == ["ssh", "--", "a.b_c~d+e-f@host"])
        rejects("ssh://a%2Fb@host", .invalidUser("a/b"))
        rejects("ssh://%C3%A9@host", .invalidUser("é"))
    }

    @Test func userStartingWithDash() {
        rejects("ssh://-l@host", .invalidUser("-l"))
        rejects("telnet://-l@host", .invalidUser("-l"))
    }

    @Test func badTelnetUser() {
        rejects("telnet://a%20b@host", .invalidUser("a b"))
        rejects("telnet://bob:pw@host", .passwordInURL("telnet://bob:pw@host"))
    }

    @Test func colonOnlyInsideIPv6Brackets() throws {
        rejects("ssh://ho%3Ast", .invalidHost("ho:st"))
        #expect(try plan("ssh://[fe80::1]").argv == ["ssh", "--", "fe80::1"])
    }

    @Test(arguments: ["/tmp/a\u{2028}b.sh", "/tmp/a\u{2029}b.sh", "/tmp/a\u{85}b.sh"])
    func filePathRejectsUnicodeSeparators(path: String) {
        #expect(throws: OpenRequestError.controlCharacter(path)) { try OpenRequest.plan(forFile: path) }
    }

    @Test func finalPassChecksEveryArgvElement() {
        #expect(throws: OpenRequestError.controlCharacter("a\nb")) {
            try OpenRequest.validated(LaunchPlan(directory: nil, argv: ["ok", "a\nb"]))
        }
        #expect(throws: OpenRequestError.controlCharacter("/d\u{1B}")) {
            try OpenRequest.validated(LaunchPlan(directory: "/d\u{1B}", argv: ["ok"]))
        }
    }
}
