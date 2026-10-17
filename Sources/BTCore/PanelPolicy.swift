import Foundation

/// Decides which commands open as a full terminal panel instead of an output bubble.
///
/// Programs on the alternate screen (vim, htop, less) are detected from the byte stream.
/// This list covers programs that redraw in place *without* the alternate screen (Claude Code)
/// or that host another shell (ssh, tmux), where bubbles would turn into a mess.
public struct PanelPolicy: Sendable {
    public var programs: Set<String>

    public static let defaultPrograms: Set<String> = [
        "claude", "ssh", "mosh", "tmux", "screen", "bash", "sh", "fish", "su", "python3 -i",
        "top", "watch", "telnet", "nc", "ftp", "sftp",
    ]

    public init(programs: Set<String> = PanelPolicy.defaultPrograms) { self.programs = programs }

    public func wantsPanel(_ command: String) -> Bool {
        var words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Skip leading VAR=value assignments and wrappers that run another program.
        while let w = words.first, w.contains("=") && !w.hasPrefix("=") || ["sudo", "env", "exec", "command", "nohup", "time"].contains(w) {
            if w == "sudo", words.count > 1, ["-i", "-s"].contains(words[1]) { return true }
            words.removeFirst()
            while let f = words.first, f.hasPrefix("-") { words.removeFirst() } // wrapper flags
        }
        guard let first = words.first else { return false }
        let program = (first as NSString).lastPathComponent
        let args = Array(words.dropFirst())
        let operands = args.filter { !$0.hasPrefix("-") }
        // Shells are interactive only without a script or -c command (`bash build.sh` keeps its bubble).
        if ["bash", "sh", "zsh", "fish", "dash", "ksh"].contains(program) {
            return programs.contains(program) && operands.isEmpty && !args.contains("-c")
        }
        // ssh is interactive only without a remote command (`ssh host uptime` keeps its bubble).
        // Flags that take a value are skipped with their value; the first operand is the host.
        if program == "ssh" {
            guard programs.contains("ssh") else { return false }
            let valueFlags: Set<String> = ["-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"]
            var i = 0, positional = 0
            while i < args.count {
                if valueFlags.contains(args[i]) { i += 2; continue }
                if !args[i].hasPrefix("-") { positional += 1 }
                i += 1
            }
            return positional <= 1
        }
        if programs.contains(program) { return true }
        if programs.contains(words.prefix(2).joined(separator: " ")) { return true }
        // Interactive containers: docker/kubectl/podman exec|run with -it / -ti
        if ["docker", "podman", "kubectl"].contains(program),
           words.contains(where: { $0 == "exec" || $0 == "run" }),
           words.contains(where: { $0 == "-it" || $0 == "-ti" || $0 == "--tty" }) {
            return true
        }
        return false
    }
}
