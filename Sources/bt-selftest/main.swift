import Foundation
import BTCore

// Drives a real zsh (with the integration) through Session + Splitter, then prints every bubble.
// Usage: bt-selftest [command ...]   (defaults to a fixed script)
let commands = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : [
    "echo hello world",
    #"for i in 1 2 3 4 5; do printf "\rprogress %d0%%" $i; sleep 0.05; done; echo"#,
    #"printf "bar1 0%%\nbar2 0%%\n"; sleep 0.05; printf "\e[2A\rbar1 100%%\n\rbar2 100%%\n""#,
    "false",
    #"printf "\e[?1049h\e[Hfullscreen\e[?1049l"; echo back"#,
    #"printf "\e[31mred\e[0m \e[1mbold\e[0m\n""#,
]

struct Bubble { var command: String?; var screen: Screen; var exit: Int32?; var alt = false }
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bt-selftest-\(getpid())")
let session = Session(cols: 80, rows: 24)
var splitter = Splitter()
var bubbles: [Bubble] = []
var prompts = 0
var queue = commands
var done = false

session.onData = { slice in
    for e in splitter.feed(slice) {
        switch e {
        case .promptStart:
            prompts += 1
            if queue.isEmpty { done = true } else { session.send(queue.removeFirst() + "\r") }
        case .prompt: break
        case .commandStart(let cmd): bubbles.append(Bubble(command: cmd, screen: Screen(cols: 80, rows: 24)))
        case .output(let b):
            if bubbles.isEmpty { bubbles.append(Bubble(command: nil, screen: Screen(cols: 80, rows: 24))) }
            bubbles[bubbles.count - 1].screen.feed(b)
        case .commandEnd(let code): if !bubbles.isEmpty { bubbles[bubbles.count - 1].exit = code }
        case .altScreen(let on): if on, !bubbles.isEmpty { bubbles[bubbles.count - 1].alt = true }
        }
    }
}
session.onExit = { _ in done = true }
splitter = Splitter(nonce: session.nonce)
try session.start(integration: tmp, extraEnvironment: ["BT_USER_ZDOTDIR": "/var/empty", "BT_NO_HISTORY": "1"])

let deadline = Date().addingTimeInterval(20)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
session.terminate()
try? FileManager.default.removeItem(at: tmp)

print("prompts: \(prompts), bubbles: \(bubbles.count), timed out: \(!done)")
for b in bubbles {
    print("── [\(b.command ?? "(startup)")] exit=\(b.exit.map(String.init) ?? "-") alt=\(b.alt)")
    print(b.screen.plainText().split(separator: "\n", omittingEmptySubsequences: false).map { "   │ " + $0 }.joined(separator: "\n"))
}
exit(done ? 0 : 1)
