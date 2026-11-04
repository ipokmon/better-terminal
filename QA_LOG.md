# QA log

## 2026-11-04 | default-terminal handler, attempt 1 (28edc50) | FAIL

Run by the main session. Build model: Opus. QA model: Sonnet. Findings as relayed:
- HIGH (AC5): `rejectControlCharacters` checks the raw, still-encoded URL string, but `URLComponents.user` is percent-decoded and `validUser` (OpenRequest.swift ~158) only rejects `.whitespaces`, `@` and `:`. `ssh://us%0Aer@host`, `ssh://u%1B@host`, `ssh://u%03@host` and `telnet://u%0D@h` produce command lines with raw control bytes, which are typed into the PTY (Ctrl-U or a newline can turn the rest into a new command).
- MED: C1 and Unicode separators decoded from the user also pass, e.g. `%C2%85` (U+0085), `%E2%80%A8` (U+2028).
- LOW: tests miss a user starting with `-`, a bad telnet user, and the percent-encoded control-character cases.
- LOW (optional): the host pattern allows colons; `ssh://h/` silently drops the trailing slash.

## 2026-11-04 | default-terminal handler, attempt 2 (c582ada) | PASS WITH ISSUES

Run by this child session. Build model: Opus. QA model: Sonnet. qa-redteam, verbatim:
```
VERDICT: PASS WITH ISSUES
App: better-terminal | Commit: c582ada (branch feat/default-terminal-handler). Build model not stated. This is a Sonnet QA run.

Gate: `make test` and `swift test` both pass. 77 tests in 17 suites, 0 failures, including `DecodedComponentTests`. I made no source changes. My scratch harness is in the scratchpad dir only.

Attempt-1 findings, re-checked by running about 60 URLs through a copy of `OpenRequest.swift` compiled with swiftc in the scratchpad:
- HIGH (control chars in user): FIXED. These are all rejected:
  - `ssh://us%0Aer@host`
  - `u%1Bx`, `u%C2%85`, `u%E2%80%A8`
  - `telnet://u%0D@h`
  - `%2Dx` and `-x` users
  - `telnet://-l@h`
  - `ssh://u@h%0A`, `h%3Bid`, `h%20x`
  - `%E2%80%AEh` (RTL override)
  - `ssh://u%40x@h`
  - `x-man-page://ls%00`, `a%3Bb`
  - `x-man-page://3%2F-k`, `3/%2Dk`
  - `file:///tmp/a%0Ab`, `a%E2%80%A8b`
- MED (C1 / U+2028): FIXED. Both are rejected in user, man name and file path.
- LOW (host colons): FIXED. `ssh://[::1]:22` gives `ssh -p 22 -- ::1`. Unbracketed colons are rejected.
- LOW (`ssh://h/` drops the slash): not fixed. `ssh://h/` still yields `ssh -- h`. This is benign and arguably correct.
- LOW (missing tests): FIXED for user and decoded cases.

Acceptance criteria: I checked only that SPEC AC1-AC8 hold for the pure BTCore logic. Everything that needs the running app, LaunchServices or the Info.plist registration is UNTESTABLE for me. The constraints bar `open`, `make install` and lsregister.

Findings:
| Sev | Area | Finding | Evidence | Suggested fix |
|---|---|---|---|---|
| MED | Test coverage | The window-queue logic has no automated test. `OpenHandler.route`, `continueQueue`, `openWindowFromMenu`, `WindowModel.init` queue pop and `didFinishLaunching` can only be exercised by hand. Only the pure `OpenRoute.decide` is tested (OpenRequestTests.swift:174-189). Multi-item opens (queue pop order, no drop, no duplicate) have no test. | `grep` of the tests shows no use of `pendingLaunches`. | Move the queue into a small pure type in BTCore (enqueue, popFirst, drain) and test it. Or add a bt-selftest gate that enqueues 3 plans and checks that 3 windows each run one. |
| MED | Window queue (inspected, not run) | `WindowModel.init` pops a plan for any new window, including a user's Cmd-N. Also, `continueQueue` runs on every `WindowView.onAppear`. If `openWindow` fails to create a window, or a queued plan arrives while the user opens one, plans can be misrouted. They would run in an unrelated window, or sit queued with no window and then run later at an unexpected moment. | Views.swift:56-63, WindowModel.swift:50-54, OpenHandler.swift:34-45. | Accept this and document it, or tag each window request with a token. |
| LOW | Cold launch | `openWindowFromMenu` finds "New Window" by its English title. If the menu is not built yet at `didFinishLaunching`, or the system is localized, the plan is dropped. It does surface an alert listing the unrun commands, so it is not silent. I could not run the cold-launch path. | OpenHandler.swift:47-54. | Verify by hand with `open -a` on a `.command` file when the app is not running. |
| LOW | Alert text | Error descriptions echo the decoded raw user string, for example `invalidUser(user)`. Spoofing characters such as an RTL override can appear in the alert. This is display only, and nothing runs. | OpenRequest.swift:~190 | Use `debugDescription` for the user, as the control-character case already does. |
| LOW | Validation | `ssh://[:]` is accepted and yields host `:`. A zone id (`[fe80::1%25en0]`) is rejected. Neither is injectable, and `--` is present. | Scratch run. | Require a minimal IPv6 shape. Allow `%25` zones if wanted. |
| LOW | Behavior | An opened directory or a non-executable file produces a plan, for example `file:///` gives `cd / && '/'`. The shell then prints "permission denied" in the pane. File URLs with a host (`file://evil/tmp/x`) ignore the host. Opening any executable file runs it. That is the intended Terminal.app-like behavior, and quoting is correct (`$()`, `'` and a leading `-` are all inert). | Scratch run. | Optional: check the file exists and is not a directory. |

No other shell or option injection path found. Every argv element is single-quoted, `--` ends option parsing (ssh, telnet, man), and the final `validated` pass covers argv and the folder. Percent-decoding of host, user, man path and file URL path was covered above. Nothing runs when a request is rejected. `open()` collects errors into one alert and does not swallow them.

Not tested:
- The running app: Finder double-click, `open`, cold launch, multi-file open, the alert UI, the Info.plist document and URL type registration, `handlesExternalEvents(matching: [])`, and `.command` execution. I was not allowed to install or launch the app or touch LaunchServices.
- Whether telnet on this macOS accepts `--` (BSD getopt should).
- The SPEC UI criteria.

Confidence in verdict: med-high. The security fix is verified by running real inputs. The window-queue behavior is verified only by reading the code.
```
Note: the cold-launch, warm, batch-of-two and rejection paths were exercised by hand on 28edc50's app code (unchanged by c582ada) before QA; see STATUS.md.
