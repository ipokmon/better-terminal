# Better Terminal

A Mac terminal that shows your commands as **blue bubbles** and their output as **grey bubbles**, like a Messages thread. Underneath it's your normal zsh, with all your usual settings.

Requires macOS 14+ and the Swift 6 toolchain (Command Line Tools are enough). Build with `make app`, or `make install` to copy it to `~/Applications`. Uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).

## Everyday use
- **Run things:** type in the bar at the bottom and press Return. Progress bars update inside one bubble. Under each bubble, a **✓** means the command worked, and a **red pill** means it failed (it shows the exit code). Ctrl-C shows as *interrupted*.
- **Waiting:** when a running command goes quiet (resolving, downloading, thinking), a "typing" bubble with three dots shows that it's still working.
- **Passwords:** when a program asks for one (sudo, ssh), a 🔑 bubble appears. Type the password and press Return. It stays hidden, as in any terminal.
- **Errors explain themselves:** a failed command gets a red-edged bubble and a short hint. Examples: the folder it ran in when a file wasn't found, "isn't installed or isn't on your PATH", or "check quotes and brackets". Lines zsh can't even read still get a bubble with the error.
- **Pasted snippets with `# comments`** run as they would in bash: the comments are ignored.
- **Full-screen programs** such as vim, htop, fzf (Ctrl-R) and `claude` open in a framed panel inside the thread. When they finish, the panel turns into a chip.
- **Long output** collapses to its first 10 and last 20 lines. Click *Show all* to expand it (up to the last 2,000 lines). The full history is always in the classic view.

## Right-click
- **In the terminal** (the bar at the bottom, the classic view, or the vim panel): Copy, Paste, Select All, Clear Thread, Screenshot, and switching to classic view. Copy is greyed out until you select text.
- **On a blue bubble:** Copy, Copy Command, Paste Command into Prompt, Run Again.
- **On a grey bubble:** Copy, Copy Output, Copy Command and Output, and Paste Clipboard into Prompt.
- **Prefer Windows Terminal's behaviour?** Settings ▸ General ▸ "Right-click in the terminal" ▸ *Copies the selection, or pastes*. With that on, right-click copies selected text, or pastes if nothing is selected.
- When a program uses the mouse itself (for example vim with `:set mouse=a`), right-clicks go to that program, the same as in Terminal.app.

## Shortcuts
| | |
|---|---|
| ⌘\ | Classic view for this pane: a normal terminal, nothing lost. Press again for bubbles |
| ⌘⇧\ | Classic view everywhere |
| ⌘T / ⌘N | New tab (opens in the current folder) / new window |
| ⌘D / ⌘⇧D | Split side by side / top and bottom |
| ⌘⌥ + arrow keys, ⌘] / ⌘[ | Move between panes |
| ⌘W | Close pane (asks first if something is running) |
| ⌘F, ⌘G / ⌘⇧G | Find in the thread, next / previous match |
| ⌘⇧S | Copy a screenshot of this pane to the clipboard (Edit ▸ Copy Screenshot of Window for all panes) |
| ⌘K | Clear the thread and the scrollback |
| ⌘+ / ⌘− / ⌘0 | Text size |
| ⌘, | Settings: colours, background, font, presets |
| Window ▸ Bring Window to This Screen | Moves the window to the display your pointer is on |

## If something looks wrong
- Press **⌘\\**. The classic terminal always has everything.
- **Safe mode** (every pane classic) for one run: hold Option while opening the app, or run this in a terminal:
  `open -a "Better Terminal" --args --classic`
- To make classic view the permanent default, run this over SSH:
  `defaults write com.mini.better-terminal classicEverywhere -bool true`

## Using it through Jump Desktop (from the Windows PC)
- Set Jump's keyboard so the **Windows key acts as ⌘** and **Ctrl stays Ctrl**. If Ctrl is mapped to ⌘, Ctrl-C copies instead of stopping a command.
- Windows may grab some combinations before they reach the Mac, for example Win+Shift+S (Windows' own screenshot tool). If a shortcut does nothing, use the menu item instead.
- New windows open on the display your mouse pointer is on, which is the Jump Desktop screen, not the projector.

## Privacy and cost
No network access, no account, no telemetry. Threads stay in memory only and disappear when you quit. Screenshots go to the clipboard only.
Measured cost:
- Idle: 0% CPU, about 30 MB with 3 panes.
- Heaviest test (a 24 MP background with a blur drag): about 310 MB peak.
- No API key, $0.

## For developers
- `make test`: unit tests and a live zsh test.
- `make selftest`: bubble render plus a 28-check window test, shown on your screen.
- `make gate`: the Launch tests T2–T7 with real zsh.
- `make install`, and `make icon` to rebuild the icon.
`BetterTerminal --bench` runs the benchmark. The design and every build deviation are in `docs/design/architecture.md`.
