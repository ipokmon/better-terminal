# SPEC: better-terminal

**Created:** 2026-11-04 | **Last revised:** 2026-11-04

Created at this first Standard task; it covers the default-terminal slice only. Earlier behaviour (bubbles, panes, classic view) is described in README.md and docs/.

## Problem
The CEO wants Better Terminal to be the macOS default app for terminal things: double-clicked `.command`/`.sh`/`.tool` files and `ssh://`, `telnet://`, `x-man-page://` links. Until now Info.plist declared no document or URL types and the app had no open handling, so LaunchServices could not route anything to it.

## Non-goals
- Changing any system default handler, or `make install`. The main session does that after CEO approval.
- `telnet` itself: macOS no longer ships it; a telnet link runs `telnet` and the pane shows "command not found" unless the user installed one.
- Passwords in URLs, ssh URL parameters (`;fingerprint=`), or ssh paths.

## Acceptance criteria
- [x] AC1: `Resources/Info.plist` declares `CFBundleDocumentTypes` (role Shell) for `com.apple.terminal.shell-script`, `public.shell-script`, `public.unix-executable`, `com.apple.terminal.tool`, and `CFBundleURLTypes` for `ssh`, `telnet`, `x-man-page`. `plutil -lint` passes.
- [x] AC2: Opening a file runs it in a new window: `cd -- '<dir>' && '<path>'` in the user's login shell (zsh with Better Terminal's integration), on a cold launch and in a running app.
- [x] AC3: `ssh://user@host:port` runs `ssh -p port -- user@host`; `telnet://user@host:port` runs `telnet -l user -- host port`; `x-man-page://name` runs `man -- name`; `x-man-page://3/printf` runs `man 3 -- printf`.
- [x] AC4: Every command line is built from an argv by POSIX single-quoting each element (`OpenRequest.shellQuote`); a test round-trips hostile strings through real `/bin/zsh` and `/bin/sh`.
- [x] AC5: Malformed or unsafe input is rejected with a visible alert listing each reason, and nothing runs: relative paths, control characters (C0, DEL, C1, U+2028/U+2029) in any decoded component or argv element, unsupported schemes, missing/invalid hosts (colons only inside IPv6 `[brackets]`), hosts or users starting with `-`, users outside `[A-Za-z0-9._~+-]`, passwords, ports outside 1–65535, extra path/query/fragment, bad man names or sections.
- [x] AC6: Parsing and routing are pure functions in BTCore (`OpenRequest`, `OpenRoute`) with tests per scheme, for paths with spaces and quotes, and for each rejection.
- [x] AC7: One window per opened item: no extra empty window per open event, and a batch of N items opens N windows.
- [x] AC8: `make test` passes.

## Architecture
- `BTCore/OpenRequest.swift`: `OpenRequest.plan(for: URL) throws -> LaunchPlan` (directory + argv; `commandLine` quotes it). `OpenRoute.decide` picks how the plan gets its window.
- `BetterTerminal/OpenHandler.swift`: `AppDelegate.application(_:open:)` → plans → `WindowModel.pendingLaunches`. Each new `WindowModel` takes one plan for its first pane (`PaneModel.run` → `runScript`, sent at the first prompt). A window that appears opens the next window while plans remain queued, so one open at a time.
- The WindowGroup has `.handlesExternalEvents(matching: [])`: otherwise SwiftUI opens an extra empty window per open event. With it, a document launch gets no SwiftUI window, so `didFinishLaunching` uses SwiftUI's own File ▸ New Window.
- Document types use `LSHandlerRank` `Alternate`, so installing the app never makes it the default by itself.

## Assumptions
- "Exec it with the user's login shell" means type the quoted command into the pane's login shell, as Terminal.app does, rather than `exec` replacing the shell. The pane stays open afterwards so the output stays readable (Terminal.app's default profile closes or keeps it, depending on settings).
- Typed commands go into zsh history, as in Terminal.app.
- Opened items always get a new window; they never reuse an existing pane. That avoids appending to text the user had half typed. (Reusing the cold-launch window lost the command in testing; see STATUS.)
- A trailing `/` on ssh/telnet links (`ssh://h/`) is accepted and ignored: it is the empty path, not data.
- `--` before the destination in ssh/telnet/man is defence in depth on top of validation.

## Open questions
None.
