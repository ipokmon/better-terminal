# STATUS: better-terminal

**State:** QA
**Last session:** 2026-11-04 | **Last QA:** PASS WITH ISSUES (2026-11-04, attempt 2, c582ada)

## Working (verified)
- Default-terminal handling (branch `feat/default-terminal-handler`): Info.plist document and URL types; `application(_:open:)` for files and ssh/telnet/x-man-page URLs; pure parser `OpenRequest` with 30+ tests. `make test`: 77 tests pass.
- End to end with the locally built bundle (`make app`, then `open -a build/…`, not installed; the build copy was unregistered from LaunchServices afterwards): cold launch with a `.command` in a folder named `it's $x` ran it from that folder, 3/3 runs, one window each; warm open, a batch of two files (two windows), and `x-man-page://3/printf` (`man 3 -- printf`) worked; an `ssh://-oProxyCommand=…` link showed the rejection alert and ran nothing.

## In progress
- Waiting for the main session: merge, `make install`, then (with CEO approval) set Better Terminal as the LaunchServices default for the types and schemes.

## Known issues
| Sev | Issue | Since |
|---|---|---|
| low | `telnet` is not shipped with macOS; telnet links show "command not found" unless one is installed | 2026-11-04 |
| med | Window queue untested automatically; a plan can land in a window the user opens with ⌘N at the same moment (QA attempt 2) | 2026-11-04 |
| low | Cold launch finds File ▸ New Window by its English title (alerts if missing) | 2026-11-04 |
| low | Reusing the window SwiftUI opens at a document launch lost the typed command (seen 3/3, cause not found); avoided by always opening a fresh window | 2026-11-04 |

## Blocked on / needs CEO
- Setting the default handler (main session asks).

## Mocked or stubbed (must be replaced before ship)
None.

## Next 3 actions
1. Main session merges and runs `make install`.
2. CEO approves the default-handler change.
3. Check Finder double-click of a `.command` and an `ssh://` link from a browser once it is the default.

## Session log (newest first, 1-2 lines each)
- 2026-11-04: QA attempt 1 FAIL (percent-decoded control chars in ssh/telnet user). Fixed: user allowlist, colons only in IPv6 brackets, U+2028/2029 rejected, final control-char pass on every argv element; 8 new tests.
- 2026-11-04: added default-terminal handling (document/URL types, open handler, OpenRequest parser + tests). SPEC/STATUS created.
