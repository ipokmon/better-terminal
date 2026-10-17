import Foundation

/// Recognises bytes a terminal emulator generates as *replies* to queries from the program
/// (cursor position, device attributes, mode reports, OSC colour answers, DCS/APC strings).
///
/// The compose bar drops these so the shell gets exactly one answer (from the classic view),
/// but must forward everything else its terminal emits: pasted text (plain or bracketed
/// ESC[200~…ESC[201~), drag-and-drop text and kitty paste events use the same channel.
public enum TerminalReplies {
    public static func isQueryReply(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 3, data.first == 0x1B else { return false }
        let b = Array(data)
        switch b[1] {
        case 0x5D, 0x50, 0x5F, 0x5E: // OSC ] , DCS P , APC _ , PM ^ : replies only (pastes never start so)
            return true
        case 0x5B: // CSI
            guard let final = b.last else { return false }
            let params = b[2..<(b.count - 1)]
            let isParamByte: (UInt8) -> Bool = { (0x30...0x3F).contains($0) || $0 == 0x24 || $0 == 0x20 }
            guard params.allSatisfy(isParamByte) else { return false }
            switch final {
            case 0x52: return params.contains(0x3B)            // CPR  ESC[row;colR (bare ESC[1;5R-style keys never come here)
            case 0x63, 0x6E: return true                     // DA ESC[?…c / ESC[>…c, DSR ESC[0n
            case 0x79: return params.last == 0x24            // DECRPM ESC[?…;…$y
            case 0x75: return params.first == 0x3F           // kitty keyboard flags ESC[?…u
            case 0x74: return true                           // window reports ESC[…t
            default: return false
            }
        default:
            return false
        }
    }
}
