# Brief — Better Terminal (`better-terminal`)

**Stage:** 0 · Intake  **Date:** 2026-10-15  **Wave:** 2 (after the current Discovery/Design gates)

## Problem
In a normal terminal, the CEO's commands and the program output all run together as one wall of text. It is hard to tell at a glance what was typed and what came back, especially across long sessions.

## Users
- Primary: CEO (terminal sessions on the mini via Jump Desktop, and possibly on the MacBooks)
- Secondary: none planned (`tv` is the household account and doesn't use a terminal)

## Job to be done
"When I'm working in a terminal, I want my commands and their output shown as separate, clearly styled messages, like an iMessage thread, so I can follow what happened without rereading everything."

## Must-haves (CEO notes, 2026-10-15)
- A terminal that opens in its own window, with tabs or splits, styled like iMessage: **my input in blue bubbles on the right, output in grey bubbles on the left**.
- Settings: change the bubble colours and the background behind the bubbles (a solid colour or an image).
- One-click **screenshot of the visible conversation to the clipboard**.
- Full terminal parity: split panes, tabs, and everything a normal terminal session can do (2026-10-15).
- **Classic-view kill switch:** a toggle that instantly reverts to a plain terminal look, per tab and globally, with no restart and nothing lost from the session (2026-10-15).
- Platform: **macOS only** for now (2026-10-15).
- **Progress bars, spinners and counters update one bubble in place.** They must never turn into a stack of near-identical messages (2026-10-15). See "Live output" below.

## Why now
It fixes daily friction for the CEO. It is also self-contained: it doesn't depend on `hub`, uses no AI and stores no household data.

## Rough shape
**Probably a thin custom build, but Discovery checks adopt and configure first.**
- Adopt/configure candidates: Wave Terminal (Apache-2.0, has block UI), iTerm2 (GPL, shell-integration marks + custom themes), Ghostty (MIT). None of them offer iMessage-style bubbles as far as I know. Discovery will confirm whether a theme or plugin can get close enough.
- Build sketch: a native Mac app (Tauri or SwiftUI) running the user's own shell in a PTY. Shell integration (standard OSC 133 prompt/command/output markers for zsh) splits each command into an input bubble and an output bubble. No network listener, so it fits the host rules.
- Known hard case: full-screen programs (vim, htop, less, **Claude Code itself**) can't be split into bubbles. The plan is to show them as a normal terminal panel inside the thread while they run, then go back to bubbles when they exit.
- Screenshot: renders the visible thread to a PNG and copies it to the clipboard. The image stays local and nothing is uploaded.

## Data class and model routing (ADR 0003)
- Data class: **none** (a local developer tool). Terminal output can still contain secrets, so it gets no telemetry, no sync, and logs or scrollback are stored only if the CEO turns that on.
- Routing: **no model**. No Claude API key is needed, so the spend is $0.

## Intake score (1–5)
| Value to us | Effort (5 = easy) | Platform fit | Privacy/risk (5 = safe) | **Total /20** |
|---|---|---|---|---|
| 4 | 2 | 4 | 5 | **15** |

Effort is a 2 because reliably splitting input from output, handling full-screen programs and making the PTY feel fast is real work. Fit is a 4 because it's a desktop app, not a LaunchDaemon service, which is a new pattern for this studio but a harmless one.

## Recommendation
**Discover now, time-boxed to one short session.** First test whether Wave or iTerm2 with a theme gets close enough (adopt > build). If nothing does, write a thin-build spec.
Fallback: **Backlog** until `hub` passes its Discovery gate, if you'd rather keep focus there.

## Open questions for CEO (answered 2026-10-15)
1. **Where?** macOS only for now.
2. **"Same window"?** Tabs and split panes with full terminal parity, plus a classic-view kill switch.
3. **Full-screen programs** as an embedded terminal panel? Yes. The CEO would like them in bubbles too if possible (nice to have, not required).

## Live output (progress bars, spinners): recommended approach
- **Each output bubble gets its own small terminal screen** instead of plain appended text. Progress bars redraw by returning to the start of a line (`\r`) or moving the cursor up a few lines. Examples: curl, pip, brew, `docker pull`, which draws several bars at once. Because the bubble is a real mini terminal, those redraws edit the same bubble, just as they would in a normal terminal.
- **While a command runs**, its bubble shows a subtle "live" indicator and grows only when new lines really appear. When the command finishes, the bubble settles to its final state, for example "100% done". It also gets a small exit badge, ✓ or ✗ with the exit code, and how long the command took.
- **Very chatty output** (for example a build that prints thousands of lines) gets cut off after N lines, with "show all" to expand. This keeps the thread readable and the app fast.
- Discovery will test this against curl, pip, brew, npm, `docker pull` and `git clone`.

## Full-screen programs in bubbles: what Discovery will test
- **Generic full-screen programs (vim, htop, less):** these can't be bubbled. They redraw a character grid in place rather than printing messages. The best we can do is style the embedded panel to match the theme, using the same background and rounded "bubble" framing.
- **Line-by-line programs (python, node, ssh shells, psql):** these can be bubbled per line. Discovery checks how reliable that is.
- **Claude Code specifically: possible as an optional later milestone.** Claude Code has a structured streaming mode (`claude -p --output-format stream-json`). A native chat view could render your messages, Claude's replies and tool output as real bubbles, instead of scraping the screen. This would be a separate mode, not a replacement for the normal Claude Code screen.
