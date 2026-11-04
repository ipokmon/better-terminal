# QA log

## 2026-11-04 | default-terminal handler, attempt 1 (28edc50) | FAIL

Run by the main session. Build model: Opus. QA model: Sonnet. Findings as relayed:
- HIGH (AC5): `rejectControlCharacters` checks the raw, still-encoded URL string, but `URLComponents.user` is percent-decoded and `validUser` (OpenRequest.swift ~158) only rejects `.whitespaces`, `@` and `:`. `ssh://us%0Aer@host`, `ssh://u%1B@host`, `ssh://u%03@host` and `telnet://u%0D@h` produce command lines with raw control bytes, which are typed into the PTY (Ctrl-U or a newline can turn the rest into a new command).
- MED: C1 and Unicode separators decoded from the user also pass, e.g. `%C2%85` (U+0085), `%E2%80%A8` (U+2028).
- LOW: tests miss a user starting with `-`, a bad telnet user, and the percent-encoded control-character cases.
- LOW (optional): the host pattern allows colons; `ssh://h/` silently drops the trailing slash.
