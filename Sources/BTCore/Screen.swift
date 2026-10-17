import Foundation
import SwiftTerm

/// A run of cells that share one style.
public struct StyledRun: Equatable, Sendable {
    public var text: String
    public var fg: Attribute.Color
    public var bg: Attribute.Color
    public var bold: Bool
    public var underline: Bool
}

public typealias StyledLine = [StyledRun]

/// A headless terminal grid behind one output bubble.
///
/// `\r`, cursor moves and erases edit this grid, so a progress bar redraws in place.
/// It never answers terminal queries: the classic terminal is the only one that talks back to the shell.
public final class Screen: TerminalDelegate {
    public private(set) var terminal: Terminal!

    public init(cols: Int, rows: Int, scrollback: Int = 10_000) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    public func feed(_ bytes: [UInt8]) {
        terminal.feed(byteArray: bytes)
        if resetsHistory(bytes) { invalidate() }
    }

    /// Clear-scrollback (ESC[3J), full reset (ESC c) and alternate-screen switches rewrite history,
    /// which the incremental line cache otherwise treats as settled.
    private var tail: [UInt8] = []
    private static let needles: [[UInt8]] = [[0x1B, 0x5B, 0x33, 0x4A], [0x1B, 0x63],
                                              Array("\u{1B}[?1049".utf8), Array("\u{1B}[?1047".utf8), Array("\u{1B}[?47".utf8)]
    private func resetsHistory(_ bytes: [UInt8]) -> Bool {
        guard bytes.contains(0x1B) || !tail.isEmpty else { return false }
        let hay = tail + bytes
        tail = hay.contains(0x1B) ? Array(hay.suffix(7)) : []
        for n in Self.needles where hay.count >= n.count {
            for i in 0...(hay.count - n.count) where hay[i] == 0x1B && hay[i..<(i + n.count)].elementsEqual(n) { return true }
        }
        return false
    }

    public func resize(cols: Int) {
        guard cols != terminal.cols, cols > 0 else { return }
        terminal.resize(cols: cols, rows: terminal.rows)
        invalidate()
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != terminal.cols || rows != terminal.rows else { return }
        terminal.resize(cols: cols, rows: rows)
        invalidate()
    }

    /// Lines that scrolled off the top because of the scrollback cap.
    public var droppedLines: Int { terminal.buffer.totalLinesTrimmed }

    /// The last `terminal.rows` lines: what a terminal scrolled to the bottom shows.
    public func visibleLines() -> [StyledLine] {
        Array(allLines().suffix(terminal.rows))
    }

    /// All lines (scrollback + screen) with trailing blank lines removed.
    ///
    /// Incremental: lines that scrolled into history never change (only a resize reflows them), so each
    /// call converts just the screen area plus newly scrolled lines. A live 10k-line bubble costs
    /// O(rows × cols) per refresh instead of O(scrollback × cols).
    public func lines() -> [StyledLine] {
        var out = allLines()
        while let last = out.last, last.allSatisfy({ $0.text.allSatisfy { $0 == " " } }) { out.removeLast() }
        return out
    }

    private var cache: [StyledLine] = []
    private var cacheTop = 0 // absolute row of cache[0]

    private func invalidate() { cache.removeAll(keepingCapacity: true); cacheTop = terminal.buffer.totalLinesTrimmed }

    private func allLines() -> [StyledLine] {
        let top = terminal.buffer.totalLinesTrimmed
        if top < cacheTop { invalidate() }
        if top > cacheTop { // capped scrollback dropped lines from the front
            cache.removeFirst(min(top - cacheTop, cache.count))
            cacheTop = top
        }
        // Re-read from where the screen area began last time; everything above is settled history.
        var row = cacheTop + max(0, cache.count - terminal.rows)
        cache.removeLast(cache.count - (row - cacheTop))
        while let line = terminal.getScrollInvariantLine(row: row) {
            cache.append(Self.runs(line, cols: terminal.cols))
            row += 1
        }
        return cache
    }

    /// Plain text of `lines()`, one string per line, right-trimmed.
    public func plainText() -> String {
        lines().map { line in
            var s = line.map(\.text).joined()
            while s.last == " " { s.removeLast() }
            return s
        }.joined(separator: "\n")
    }

    static func runs(_ line: BufferLine, cols: Int) -> StyledLine {
        // Stop after the last cell that shows something: a character or a non-default background.
        var n = min(cols, line.count)
        while n > 0 {
            let c = line[n - 1]
            let ch = c.getCharacter()
            let blankBg = c.attribute.bg == .defaultColor || c.attribute.bg == .defaultInvertedColor
            if (ch == " " || ch == "\u{0}") && blankBg { n -= 1 } else { break }
        }
        var result: StyledLine = []
        var col = 0
        while col < n {
            let cell = line[col]
            let a = cell.attribute
            if cell.width == 0 { col += 1; continue } // trailing half of a wide character
            var ch = cell.getCharacter()
            if ch == "\u{0}" { ch = " " }
            let bold = a.style.contains(.bold)
            let underline = a.style.contains(.underline)
            if let last = result.last, last.fg == a.fg, last.bg == a.bg, last.bold == bold, last.underline == underline {
                result[result.count - 1].text.append(ch) // in place: no copy of the run's string
            } else {
                result.append(StyledRun(text: String(ch), fg: a.fg, bg: a.bg, bold: bold, underline: underline))
            }
            col += 1
        }
        return result
    }

    // MARK: TerminalDelegate (only the required bits; responses are dropped on purpose)

    public func send(source: Terminal, data: ArraySlice<UInt8>) {}
    public func showCursor(source: Terminal) {}
    public func hideCursor(source: Terminal) {}
    public func setTerminalTitle(source: Terminal, title: String) {}
    public func setTerminalIconTitle(source: Terminal, title: String) {}
    public func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    public func sizeChanged(source: Terminal) {}
    public func bufferActivated(source: Terminal) {}
    public func bell(source: Terminal) {}
    public func selectionChanged(source: Terminal) {}
    public func isProcessTrusted(source: Terminal) -> Bool { false }
    public func mouseModeChanged(source: Terminal) {}
    public func hostCurrentDirectoryUpdated(source: Terminal) {}
    public func hostCurrentDocumentUpdated(source: Terminal) {}
    public func colorChanged(source: Terminal, idx: Int?) {}
    public func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
}
