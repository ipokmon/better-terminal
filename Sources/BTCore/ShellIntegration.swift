import Foundation

/// zsh integration, injected through ZDOTDIR so the user's own dotfiles are never edited.
///
/// Each of our four startup files sources the user's file of the same name (with ZDOTDIR pointing at
/// the user's directory while it runs), then restores ours so nested zsh shells keep the marks.
/// The hooks emit OSC 133 A/B/C/D plus OSC 1337;BTCmd=<base64> with the exact command line.
public enum ShellIntegration {
    public static let version = "4"

    /// Writes the integration into `dir` (created if needed) and returns it.
    @discardableResult
    public static func install(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Remove superseded versions (zsh-1, zsh-2, …) next to ours.
        if dir.lastPathComponent.hasPrefix("zsh-") {
            let parent = dir.deletingLastPathComponent()
            for old in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            where old.hasPrefix("zsh-") && old != dir.lastPathComponent {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(old))
            }
        }
        for (name, body) in files {
            let url = dir.appendingPathComponent(name)
            let text = header + body
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return dir
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BetterTerminal/zsh-\(version)")
    }

    private static let header = "# Better Terminal shell integration v\(version). Generated on every launch; do not edit.\n"

    /// Source the user's copy of `file` with ZDOTDIR set to the user's directory, then switch back.
    private static func sourceUser(_ file: String) -> String {
        """
        _bt_ours=$ZDOTDIR
        ZDOTDIR=${BT_USER_ZDOTDIR:-$HOME}
        [[ -r "$ZDOTDIR/\(file)" ]] && builtin source "$ZDOTDIR/\(file)"
        BT_USER_ZDOTDIR=$ZDOTDIR
        ZDOTDIR=$_bt_ours
        unset _bt_ours

        """
    }

    static let files: [(String, String)] = [
        (".zshenv", sourceUser(".zshenv")),
        (".zprofile", sourceUser(".zprofile")),
        (".zshrc", """
        # macOS /etc/zshrc set HISTFILE from our ZDOTDIR; keep history in the user's usual place.
        [[ "$HISTFILE" == "$ZDOTDIR/.zsh_history" ]] && HISTFILE="${BT_USER_ZDOTDIR:-$HOME}/.zsh_history"
        \(sourceUser(".zshrc"))
        # Self-tests and benchmarks set BT_NO_HISTORY so their commands stay out of the user's history.
        [[ -n "${BT_NO_HISTORY-}" ]] && { unset HISTFILE; SAVEHIST=0 }
        # zsh's partial-line marker (PROMPT_SP) would land inside the output bubble.
        unsetopt PROMPT_SP 2>/dev/null

        _bt_urlencode() {
          local LC_ALL=C s=$1 out= c i
          for (( i = 1; i <= ${#s}; i++ )); do
            c=$s[i]
            case $c in
              [a-zA-Z0-9/._~-]) out+=$c ;;
              *) out+=$(builtin printf '%%%02X' "'$c") ;;
            esac
          done
          builtin print -rn -- "$out"
        }
        _bt_precmd_first() {
          local s=$?
          builtin printf '\\e]133;D;%s;bt=%s\\a\\e]133;A;bt=%s\\a' "$s" "${BT_NONCE-}" "${BT_NONCE-}"
          builtin printf '\\e]7;file://%s%s\\a' "${HOST}" "$(_bt_urlencode "$PWD")"
        }
        _bt_precmd_last() {
          # Prompt themes rebuild PS1 in precmd; re-append the B mark when it is missing.
          [[ "$PS1" == *$'\\e]133;B\\a'* ]] || PS1="$PS1%{"$'\\e]133;B\\a'"%}"
        }
        _bt_preexec() {
          builtin printf '\\e]1337;BTCmd=%s;%s\\a\\e]133;C;bt=%s\\a' "${BT_NONCE-}" \\
            "$(builtin print -rn -- "$1" | /usr/bin/base64)" "${BT_NONCE-}"
        }
        # Enter (not Ctrl-C) on a non-empty line: report the accepted text, so a line that never runs
        # (a parse error, for example) still gets a bubble with its error.
        _bt_line_finish() {
          [[ $KEYS == $'\\r' || $KEYS == $'\\n' ]] || return 0
          [[ -n ${BUFFER//[[:space:]]/} ]] || return 0
          builtin printf '\\e]1337;BTAccept=%s;%s\\a' "${BT_NONCE-}" "$(builtin print -rn -- "$BUFFER" | /usr/bin/base64)"
        }
        autoload -Uz add-zle-hook-widget 2>/dev/null && add-zle-hook-widget line-finish _bt_line_finish
        # Pasted snippets often carry "# comments"; bash accepts them at the prompt, zsh needs this.
        setopt interactive_comments
        typeset -ga precmd_functions preexec_functions
        precmd_functions=(_bt_precmd_first ${precmd_functions:#_bt_*} _bt_precmd_last)
        # First, so our C mark (with the command text) arrives before other tools' marks.
        preexec_functions=(_bt_preexec ${preexec_functions:#_bt_*})

        """),
        (".zlogin", sourceUser(".zlogin")),
    ]
}
