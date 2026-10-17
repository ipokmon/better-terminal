# Discovery: Better Terminal (`better-terminal`)

**Stage:** 1 · Discovery (approved by CEO 2026-10-15: native build; R11 = v2 on existing login)  **Date:** 2026-10-15  **Author:** Eng Lead
**Inputs:** `products/better-terminal/brief.md` (CEO answers 2026-10-15), spikes in `/tmp/bt-spike` (throwaway, not committed; the scripts are reproduced below).

Confidence legend: **V** = verified here 2026-10-15 · **W** = web-cited · **M** = from memory (unverified).

## Summary (PM)
- **No existing terminal can do iMessage bubbles,** even with themes or plugins. Warp's "blocks" come closest, but they can't be restyled and it has cloud/telemetry baggage. **Recommendation: a thin custom build.**
- **Both risky parts are proven on this Mac (V):**
  - zsh marks where each command and its output start and end (OSC 133), and progress-bar redraws stay inside one command's output.
  - A native SwiftUI app builds with the tools already installed and renders bubbles to a PNG, which is the screenshot path.
- **Stack:** native SwiftUI + SwiftTerm (MIT), plus an injected zsh integration that leaves `~/.zshrc` untouched. It needs **no installs, no sudo, no listener and no API key**. Memory is ≤ 150 MB idle.
- **Full-screen programs** (vim, htop, Claude Code) get an embedded terminal panel, triggered by the alternate-screen switch. Claude Code can get real bubbles later through its structured stream mode (R11, optional).

## Build vs adopt
**Recommendation:** build: native SwiftUI + SwiftTerm, zsh OSC 133 integration, one emulator per output bubble.  **Fallback:** Tauri 2 + portable-pty + xterm.js (needs Rust and node installs).  **Why:** nothing can be adopted or configured into bubbles; native is the lightest, needs zero installs, and looks most like iMessage.

## Decisions needed from CEO
1. **Pursue to Design with the native Swift build?** Recommend yes. Fallback: Tauri/web stack (adds Rust + node installs).
2. **Claude Code chat mode (R11):** recommend a later milestone (v2) that uses your existing Claude Code login, with no new API key. Fallback: drop it and keep the embedded panel only.

## Requirements (MoSCoW user stories)
| ID | As a… | I want… | So that… | Priority |
|---|---|---|---|---|
| R1 | CEO | each command I type shown as a blue bubble on the right, and its output as a grey bubble on the left | I can tell input from output at a glance | Must |
| R2 | CEO | progress bars, spinners and counters to edit **one** bubble in place | a download doesn't become 100 near-identical messages | Must |
| R3 | CEO | full terminal parity: my normal zsh, tabs, split panes, copy/paste, Ctrl-C, ssh, colours, fonts, scrollback | I can use it as my only terminal | Must |
| R4 | CEO | full-screen programs (vim, htop, less, Claude Code) to run in an embedded terminal panel inside the thread | nothing breaks | Must |
| R5 | CEO | a classic-view switch, per tab and global, with no restart and no lost session | I can always fall back to a plain terminal | Must |
| R6 | CEO | settings for bubble colours (mine, output, errors) and the thread background (a colour or an image) | it looks how I like | Must |
| R7 | CEO | one click (and a shortcut) to copy a screenshot of the visible thread to the clipboard | I can paste it into chat or a doc | Must |
| R8 | CEO | an exit badge on each output bubble (✓/✗ + code) and the command's duration | failures stand out | Should |
| R9 | CEO | very long output cut off after N lines, with "show all" | the thread stays readable and fast | Should |
| R10 | CEO | line-by-line programs (python, node, psql, an ssh shell) bubbled per line | REPLs read like a chat too | Could |
| R11 | CEO | a Claude Code "chat mode" that renders Claude's structured stream as real bubbles | Claude Code feels like iMessage too | Could (later milestone) |
| R12 | Sec | no telemetry, no account, no network listener, no auto-update calls; scrollback stays in memory unless I turn saving on | terminal output (which can hold secrets) never leaves the Mac | Must |
| R13 | CEO | Windows / Linux / iPhone | | Won't (macOS only, CEO 2026-10-15) |

## Spike results (V, run on the mini as ops, 2026-10-15)
### S1. Separating input from output (zsh semantic prompt marks)
A 6-line zsh hook emits the standard **OSC 133** marks: `A` = prompt start, `B` = command input starts, `C` = output starts, `D;<exit>` = command finished. A stdlib Python PTY harness ran 5 commands through an interactive zsh and captured the raw bytes.

| Check | Result |
|---|---|
| Marks seen, in order | `A B C D;0` for each command; `D;1` for `false`; a spurious `D;0` before the first prompt (ignore a `D` with no matching `C`) |
| Output segmented between `C` and `D` | yes, for all 4 commands, with the correct exit code |
| `\r` progress bar (`printf "\rprogress N0%%"` x5) | all 5 redraws are inside **one** C…D segment, so one bubble |
| Cursor-up redraw (`\e[2A`) | inside one segment, so one bubble |
| Gotcha | zsh's `PROMPT_SP` (the inverse `%` + padding it prints before each prompt) lands *inside* the output segment. Fix: emit `D` from the first line of `precmd` and strip it, or set `unsetopt PROMPT_SP` in the integration |

**Conclusion:** the bubble split rests on a standard, well-understood mechanism. The integration is a small zsh snippet that the app injects through `ZDOTDIR` (the same way VS Code and Ghostty do it), so `~/.zshrc` is never edited.

### S2. Native app + bubbles + screenshot with the installed toolchain
- Installed: Swift 6.4 Command Line Tools (macOS 27 SDK), python3 3.9.6, zsh 5.9. **Not installed:** Xcode, node/npm, Rust/cargo. No third-party terminal in `/Applications`.
- A SwiftPM package with SwiftUI builds with **Command Line Tools only** (`swift build`, 1.3 s), with no Xcode and no installs.
- It drew a blue input bubble and a grey output bubble and rendered them **off-screen to a PNG** with `ImageRenderer` (15 KB @2x). This is the screenshot-to-clipboard path. It renders the app's own view, so it needs **no Screen Recording permission** (M: clipboard write via `NSPasteboard` not yet exercised).

## Market scan
No existing terminal draws chat bubbles, and none of the candidates can be turned into one through config or a plugin (W, desk research 2026-10-15). Most dates come from search summaries. RAM figures weren't found.

| Candidate | License | Latest | Telemetry / account | Input/output split | Can it do bubbles? |
|---|---|---|---|---|---|
| **Warp** | Client AGPL-3.0 (open-sourced 2026-04-28), cloud proprietary | 2026 | No login needed. Telemetry can be turned off, but some AI features need it on ([warp.dev](https://www.warp.dev/blog/open-source-and-login-for-warp)) | Native "blocks", the closest UX | No theme or plugin API for block layout. Only by forking a large Rust codebase. Cloud and AI parts fail R12 |
| **Wave Terminal** | Apache-2.0 | v0.14.5, Apr 2026 | Opt-out telemetry plus a diagnostics ping ([docs](https://docs.waveterm.dev/telemetry)) | Panes are whole xterm.js terminals, not per-command blocks (M) | No |
| **iTerm2** | GPL-2.0+ (M) | 3.7.4, ~2026-10-08 | None. AI is opt-in | OSC 133 marks | Python API controls the app but can't change how output is drawn (M). No |
| **Ghostty** | MIT | 1.3.1 (1.4.0 due 2026-10-23) | None | Full OSC 133 | No plugin API (config and shaders only). No |
| **Kitty** | GPL-3.0 (M) | 0.49.2, 2026-10-01 | None | OSC 133 (M) | "Kittens" are scripts and TUIs, with no UI widget layer. No |
| **Tabby** | MIT (M) | v1.0.238, 2026-10-06 | Optional sync | Unknown | Plugins can reach the DOM, but output is still one xterm.js grid, so bubbles would mean deep hacks |
| WezTerm / Alacritty / Hyper / Zed | MIT / Apache / MIT / GPL | WezTerm nightlies only, Hyper stalled since 2023 | None | WezTerm has OSC 133 | No |

### Comparison of the realistic paths
| Criterion | **Native SwiftUI + SwiftTerm** (rec.) | Tauri 2 + portable-pty + xterm.js | Fork Warp |
|---|---|---|---|
| License | ours + MIT (SwiftTerm v1.99.0, very active, W) | ours + MIT/Apache | AGPL-3.0 (our changes must stay AGPL) |
| Installs needed | **none** (builds with the CLT already here, V) | Rust toolchain + node (CEO approval) | Rust toolchain; huge build |
| Apple Silicon | native (V) | native | native |
| RAM idle (3 tabs) | ~100–150 MB (M) | ~150–250 MB (M) | ~300 MB+ (M) |
| Per-bubble emulator for live redraw (R2) | one SwiftTerm `Terminal` per bubble (headless model) | one `@xterm/headless` per bubble | re-architect blocks |
| Screenshot (R7) | `ImageRenderer` of own view, no permission (V) | webview capture API | custom |
| Effort to v1 | medium | medium | high, and we'd carry a fork |
| Look and feel | real Mac app; iMessage-like for free (SwiftUI) | web look | Warp's look |
| Upgrade path | swap the emulator for libghostty-vt when its official Swift package ships (announced 2026-07-02, "coming soon", W) | n/a | n/a |

### Claude Code chat mode (R11), feasibility
`claude -p --input-format stream-json --output-format stream-json --verbose` runs one long-lived multi-turn session over JSONL. The Agent SDK documents streaming input. The CLI docs cover only the output side, and that gap is tracked in [anthropics/claude-code#24594](https://github.com/anthropics/claude-code/issues/24594) (W). It's feasible, but the input contract is under-documented, so it stays a later milestone. **Spend note:** `--bare` mode needs an `ANTHROPIC_API_KEY` (a new key = a CEO spend decision). Non-bare mode should use the CEO's existing Claude Code login. Design will verify that before relying on it.

## Live output: how one bubble edits itself (R2)
Each output bubble is backed by its own small terminal-emulator grid, not by appended text. `\r`, cursor-up/down, erase-line and colours are applied to that grid, so a progress bar redraws inside its bubble exactly as it would in a normal terminal. While the command runs, the bubble shows a subtle "live" dot and grows only when real new lines appear. On `D` it freezes, shows the exit badge and duration (R8), and long output collapses (R9). Full-screen programs switch the terminal to the **alternate screen** (`ESC[?1049h`). That switch is the trigger to show an embedded full terminal panel until `ESC[?1049l` (R4).

## AI opportunities
None in v1. The product calls no model, needs no API key and costs $0. R11 (Claude Code chat mode) uses the CEO's existing Claude Code, not a new key.

## Memory budget
Target: **≤ 150 MB idle with 3 tabs, ≤ 400 MB peak** with long scrollback. Native Swift keeps this low. An Electron shell would start around 200–300 MB (M). Scrollback is capped per tab (default 10k lines; older output is dropped). This leaves the ~19.5 GB local LLM untouched.

## Host-rule check
- No listener, no daemon. It's a normal app run by `ops` in the GUI session (Jump Desktop), so no new host exception is needed.
- No sudo, and no system-software install for the recommended path. Swift package dependencies (for example SwiftTerm) are fetched by SwiftPM into the repo's build directory and pinned in `Package.resolved`.
- No telemetry, no updater.
- It never touches `~tv`, `~agent` or `~/Downloads`. The screenshot goes to the clipboard only.
