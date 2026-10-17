import Foundation
import SwiftTerm

/// One shell in a PTY. Bytes from the shell arrive on the main queue through `onData`.
public final class Session: LocalProcessDelegate {
    public var onData: (ArraySlice<UInt8>) -> Void = { _ in }
    public var onExit: (Int32?) -> Void = { _ in }

    /// Random per session; our shell marks carry it so programs can't fake them (see Splitter).
    public let nonce: String = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()

    public private(set) var cols: Int
    public private(set) var rows: Int
    private var process: LocalProcess!

    public init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        process = LocalProcess(delegate: self, dispatchQueue: .main)
    }

    public var isRunning: Bool { process.running }
    public var shellPid: pid_t { process.shellPid }

    /// Starts the user's login shell with our zsh integration.
    public func start(shell: String = "/bin/zsh", integration: URL? = ShellIntegration.defaultDirectory,
                      currentDirectory: String? = nil, extraEnvironment: [String: String] = [:]) throws {
        var env = ProcessInfo.processInfo.environment
        let userZdotdir = env["ZDOTDIR"]
        for key in ["ZDOTDIR", "BT_USER_ZDOTDIR", "TERM_SESSION_ID", "ITERM_SESSION_ID", "VSCODE_INJECTION"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "BetterTerminal"
        env["TERM_PROGRAM_VERSION"] = BTVersion.string
        env["BT_NONCE"] = nonce
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if let dir = integration, shell.hasSuffix("zsh") {
            try ShellIntegration.install(in: dir)
            env["ZDOTDIR"] = dir.path
            if let u = userZdotdir { env["BT_USER_ZDOTDIR"] = u }
        }
        for (k, v) in extraEnvironment { env[k] = v }
        let cwd = currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["PWD"] = cwd // zsh keeps this logical path (/tmp, not /private/tmp) when it matches the real folder
        env.removeValue(forKey: "OLDPWD")
        let name = "-" + (shell as NSString).lastPathComponent // leading dash = login shell
        process.startProcess(executable: shell, args: [], environment: env.map { "\($0.key)=\($0.value)" },
                             execName: name, currentDirectory: cwd)
    }

    public func send(_ bytes: ArraySlice<UInt8>) { process.send(data: bytes) }
    public func send(_ text: String) { send(Array(text.utf8)[...]) }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        var size = getWindowSize()
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    /// Hangs up the shell like closing a terminal window: zsh saves history and sends SIGHUP to its
    /// jobs. (An interactive zsh ignores SIGTERM, which is all `LocalProcess.terminate()` sends.)
    /// True while the program reads a line with echo off: a password prompt (sudo, ssh, `read -s`).
    /// The shell's own line editor and full-screen programs turn canonical mode off, so they don't count.
    public var isReadingSecret: Bool {
        var t = termios()
        guard process.running, tcgetattr(process.childfd, &t) == 0 else { return false }
        return t.c_lflag & tcflag_t(ECHO) == 0 && t.c_lflag & tcflag_t(ICANON) != 0
    }

    public func terminate() {
        let pid = process.shellPid
        if pid > 0 { kill(pid, SIGHUP) } // never pid 0: that would signal our own process group
        process.terminate()
    }

    // MARK: LocalProcessDelegate

    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) { onExit(exitCode) }
    public func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) { onExit(nil) }
    public func dataReceived(slice: ArraySlice<UInt8>) { onData(slice) }
    public func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }
}

public enum BTVersion {
    public static let string = "0.5.3"
}
