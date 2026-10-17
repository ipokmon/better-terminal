import Foundation

/// What the splitter found in the PTY byte stream, in order.
public enum SplitterEvent: Equatable, Sendable {
    /// OSC 133;A: a new prompt is being drawn. The compose bar starts fresh.
    case promptStart
    /// Prompt and line-editor bytes (between A and C). Markers are stripped.
    case prompt([UInt8])
    /// OSC 133;C: the typed command started. Text comes from our OSC 1337;BTCmd mark, when present.
    case commandStart(String?)
    /// Program output (between C and D, or before the first prompt). Markers are stripped.
    case output([UInt8])
    /// OSC 133;D: the command finished, with its exit status when the shell sent one.
    case commandEnd(Int32?)
    /// The program switched to (true) or away from (false) the alternate screen.
    case altScreen(Bool)
}

/// Routes a PTY byte stream into prompt / output / marker events.
///
/// It never rewrites bytes: everything except our own OSC 133 / BTCmd marks is passed on unchanged.
/// Escape sequences split across `feed` calls are held back until complete, so a route change
/// never cuts one in half. The caller feeds the raw stream to the classic terminal separately.
public final class Splitter {
    public enum State: Equatable, Sendable { case startup, prompt, running }

    public private(set) var state: State = .startup
    public private(set) var altScreen = false

    private var pending: [UInt8] = []
    private var run: [UInt8] = []
    private var events: [SplitterEvent] = []
    private var pendingCommand: String?
    /// Text the user accepted with Enter (BTAccept mark). If no C follows before the next prompt, the
    /// line never ran (e.g. a zsh parse error): it still gets a bubble, with the error as output.
    private var accepted: String?
    private var acceptedOutput: [UInt8] = []
    private var acceptedExit: Int32?
    /// When set, only OSC 133 / BTCmd marks carrying `bt=<nonce>` count. Marks from other tools
    /// (iTerm2's or p10k's shell integration) and fakes printed by programs are passed through as text.
    private let nonce: String?

    private static let maxOSC = 1024 * 1024 // long pasted commands still fit in one BTCmd mark
    private static let maxCSI = 256

    public init(nonce: String? = nil) { self.nonce = nonce }

    public func feed<S: Sequence>(_ bytes: S) -> [SplitterEvent] where S.Element == UInt8 {
        for b in bytes { step(b) }
        // Hand back plain text now so live output stays live. A partial escape sequence waits.
        flushRun()
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    // MARK: - Byte state machine

    private func step(_ b: UInt8) {
        if pending.isEmpty {
            if b == 0x1B { pending.append(b) } else { run.append(b) }
            return
        }
        // CAN / SUB abort any sequence (xterm behaviour).
        if b == 0x18 || b == 0x1A {
            pending.append(b); passThrough(); return
        }
        if pending.count == 1 && b != 0x1B { // ESC + its first byte decides the kind of sequence
            pending.append(b)
            if b == 0x5B || b == 0x5D || (0x20...0x2F).contains(b) { return } // CSI, OSC, or intermediates follow
            passThrough() // two-byte sequence, e.g. ESC c, ESC =
            return
        }
        let kind = pending.count > 1 ? pending[1] : 0
        if b == 0x1B {
            // Inside an OSC this may be the start of ST (ESC \): wait for the next byte.
            if kind == 0x5D, pending.last != 0x1B { pending.append(b); return }
            // Anywhere else an ESC ends the unfinished sequence and starts a new one, so an
            // interrupted colour code (`ESC[1` + Ctrl-C) cannot swallow our next mark.
            passThrough(); pending = [0x1B]; return
        }
        if kind == 0x5D, pending.last == 0x1B {
            if b == 0x5C { pending.append(b); completeOSC(payloadEnd: pending.count - 2); return } // ESC \ = ST
            // ESC + something else: the OSC was never terminated. Abort it, re-read ESC + b.
            pending.removeLast(); passThrough()
            step(0x1B); step(b)
            return
        }
        pending.append(b)
        switch kind {
        case 0x5D: // ESC ] : OSC, ends with BEL (or ST, above)
            if b == 0x07 && pending.count > 2 {
                completeOSC(payloadEnd: pending.count - 1)
            } else if pending.count > Self.maxOSC {
                passThrough()
            }
        case 0x5B: // ESC [ : CSI, ends with a final byte 0x40...0x7E
            if pending.count > 2 && (0x40...0x7E).contains(b) {
                completeCSI()
            } else if pending.count > Self.maxCSI {
                passThrough()
            }
        default: // ESC, optional intermediates 0x20...0x2F, then one final byte
            if !(0x20...0x2F).contains(b) || pending.count > 8 {
                passThrough()
            }
        }
    }

    private func passThrough() {
        run.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    private func completeCSI() {
        // Alternate screen: ESC [ ? 47 / 1047 / 1049 h|l (possibly with other params, e.g. ?1049;1h)
        if pending.count > 3, pending[2] == 0x3F, let final = pending.last, final == 0x68 || final == 0x6C {
            let params = String(decoding: pending[3..<(pending.count - 1)], as: UTF8.self).split(separator: ";")
            if params.contains(where: { $0 == "47" || $0 == "1047" || $0 == "1049" }) {
                let on = final == 0x68
                passThrough()
                if on != altScreen {
                    altScreen = on
                    flushRun()
                    events.append(.altScreen(on))
                }
                return
            }
        }
        passThrough()
    }

    private func completeOSC(payloadEnd: Int) {
        let payload = String(decoding: pending[2..<payloadEnd], as: UTF8.self)
        if payload.hasPrefix("133;"), ours(payload) {
            pending.removeAll(keepingCapacity: true)
            handle133(payload.dropFirst(4))
        } else if payload.hasPrefix("1337;BTAccept=") {
            var body = payload.dropFirst("1337;BTAccept=".count)
            if let n = nonce {
                guard body.hasPrefix(n + ";") else { passThrough(); return }
                body = body.dropFirst(n.count + 1)
            } else if let semi = body.lastIndex(of: ";") {
                body = body[body.index(after: semi)...]
            }
            pending.removeAll(keepingCapacity: true)
            flushRun()
            if state == .prompt {
                accepted = Data(base64Encoded: String(body)).flatMap { String(data: $0, encoding: .utf8) }
                acceptedOutput.removeAll()
                acceptedExit = nil
            }
        } else if payload.hasPrefix("1337;BTCmd=") {
            var body = payload.dropFirst("1337;BTCmd=".count)
            if let n = nonce { // BTCmd=<nonce>;<base64>
                guard body.hasPrefix(n + ";") else { passThrough(); return }
                body = body.dropFirst(n.count + 1)
            } else if let semi = body.lastIndex(of: ";") { // no nonce configured: ignore any prefix
                body = body[body.index(after: semi)...]
            }
            pending.removeAll(keepingCapacity: true)
            pendingCommand = Data(base64Encoded: String(body)).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            passThrough()
        }
    }

    /// A 133 mark counts when no nonce is configured, or when it carries ours (`…;bt=<nonce>`).
    private func ours(_ payload: String) -> Bool {
        guard let n = nonce else { return true }
        return payload.split(separator: ";").contains { $0 == "bt=\(n)" }
    }

    private func handle133<S: StringProtocol>(_ body: S) {
        let parts = body.split(separator: ";", omittingEmptySubsequences: false).filter { !$0.hasPrefix("bt=") }
        guard let mark = parts.first else { return }
        switch mark {
        case "A":
            flushRun()
            if let cmd = accepted { // accepted with Enter but never started: show it with what zsh printed
                accepted = nil
                // Drop the newline zsh echoes after Enter (and the mode codes around it, like ESC[?2004l),
                // so the error starts the bubble.
                acceptedOutput = Self.droppingLeadingBlank(acceptedOutput)
                let shown = Self.hasVisibleText(acceptedOutput) // redraw codes alone don't count as output
                events.append(.commandStart(cmd))
                if shown { events.append(.output(acceptedOutput)) }
                events.append(.commandEnd(shown ? acceptedExit : nil))
                acceptedOutput.removeAll()
            }
            state = .prompt
            pendingCommand = nil // a label never carries over to a later command
            altScreen = false    // a killed full-screen program must not block the next one
            events.append(.promptStart)
        case "B":
            break // still the prompt / line editor
        case "C":
            guard state != .running else { return }
            flushRun()
            accepted = nil // it really started: the normal path takes over
            acceptedOutput.removeAll()
            state = .running
            events.append(.commandStart(pendingCommand))
            pendingCommand = nil
        case "D":
            // A D outside a running command (first prompt, Ctrl-C at the prompt) carries no output: ignore it,
            // except to remember the status of an accepted line that never started.
            guard state == .running else {
                if accepted != nil { flushRun(); acceptedExit = parts.count > 1 ? Int32(parts[1]) : nil }
                return
            }
            flushRun()
            state = .prompt
            altScreen = false
            let code = parts.count > 1 ? Int32(parts[1]) : nil
            events.append(.commandEnd(code))
        default:
            break
        }
    }

    /// `bytes` without leading CR/LF and CSI sequences (cursor/mode codes before the first text).
    static func droppingLeadingBlank(_ bytes: [UInt8]) -> [UInt8] {
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D || bytes[i] == 0x0A { i += 1; continue }
            if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                var j = i + 2
                while j < bytes.count, !(0x40...0x7E).contains(bytes[j]) { j += 1 }
                i = j + 1
                continue
            }
            break
        }
        return Array(bytes[min(i, bytes.count)...])
    }

    /// True when `bytes` contain a printable character outside escape sequences
    /// (zle's redraws, ESC[K, ESC[?2004l, are not output).
    static func hasVisibleText(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B, i + 1 < bytes.count {
                i += 2
                switch bytes[i - 1] {
                case 0x5B: while i < bytes.count, !(0x40...0x7E).contains(bytes[i]) { i += 1 }; i += 1 // CSI
                case 0x5D: while i < bytes.count, bytes[i] != 0x07, !(bytes[i] == 0x5C && bytes[i - 1] == 0x1B) { i += 1 }; i += 1 // OSC
                default: break
                }
                continue
            }
            if b > 0x20 && b != 0x7F { return true }
            i += 1
        }
        return false
    }

    private func flushRun() {
        guard !run.isEmpty else { return }
        switch state {
        case .prompt:
            if accepted != nil { acceptedOutput += run }
            events.append(.prompt(run))
        case .startup, .running:
            events.append(.output(run))
        }
        run.removeAll(keepingCapacity: true)
    }
}
