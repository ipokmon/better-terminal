import Foundation

/// What a pane runs for a file or URL that macOS hands us (Finder double-click, `open x.command`,
/// an `ssh://` link). Built from an argv; `commandLine` quotes every element, so no path, user or
/// host is ever spliced into shell syntax unquoted.
public struct LaunchPlan: Equatable, Sendable {
    /// Folder to `cd` into first (files run from their own folder, like Terminal.app). nil: stay put.
    public let directory: String?
    public let argv: [String]

    public init(directory: String?, argv: [String]) {
        self.directory = directory
        self.argv = argv
    }

    /// The line typed into the pane's login shell.
    public var commandLine: String {
        let run = argv.map(OpenRequest.shellQuote).joined(separator: " ")
        guard let dir = directory else { return run }
        return "cd -- \(OpenRequest.shellQuote(dir)) && \(run)"
    }
}

public enum OpenRequestError: Error, Equatable, CustomStringConvertible {
    case notAbsolutePath(String)
    case controlCharacter(String)
    case unsupportedScheme(String)
    case malformedURL(String)
    case missingHost(String)
    case invalidHost(String)
    case invalidUser(String)
    case passwordInURL(String)
    case invalidPort(String)
    case unexpectedComponent(String)
    case invalidManPage(String)

    public var description: String {
        switch self {
        case .notAbsolutePath(let s): return "Not an absolute file path: \(s)"
        case .controlCharacter(let s): return "Contains a control character (newline, tab, escape…): \(s.debugDescription)"
        case .unsupportedScheme(let s): return "Better Terminal does not open this kind of link: \(s)"
        case .malformedURL(let s): return "Not a valid link: \(s)"
        case .missingHost(let s): return "The link names no host: \(s)"
        case .invalidHost(let s): return "Host name not allowed (letters, digits, . - _ only, not starting with -; IPv6 in [brackets]): \(s)"
        case .invalidUser(let s): return "User name not allowed (letters, digits, . _ ~ + - only, not starting with -): \(s)"
        case .passwordInURL(let s): return "Passwords in links are not supported; ssh asks for it instead: \(s)"
        case .invalidPort(let s): return "Port must be 1–65535: \(s)"
        case .unexpectedComponent(let s): return "The link has a path, query or fragment this scheme does not use: \(s)"
        case .invalidManPage(let s): return "Not a manual page name: \(s)"
        }
    }
}

public enum OpenRequest {
    /// POSIX single quoting: 'it'\''s'. Inside single quotes zsh and sh treat every byte literally
    /// (no $, `, \, ! or glob expansion), so this is safe for any string without control characters.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A script or executable: `cd` to its folder and run it by full path.
    public static func plan(forFile path: String) throws -> LaunchPlan {
        try rejectControlCharacters(path)
        guard path.hasPrefix("/") else { throw OpenRequestError.notAbsolutePath(path) }
        let dir = (path as NSString).deletingLastPathComponent
        return try validated(LaunchPlan(directory: dir.isEmpty ? "/" : dir, argv: [path]))
    }

    /// A file URL runs the file; ssh, telnet and x-man-page URLs run the matching program.
    public static func plan(for url: URL) throws -> LaunchPlan {
        if url.isFileURL { return try plan(forFile: url.path) }
        return try plan(forURLString: url.absoluteString)
    }

    public static func plan(forURLString string: String) throws -> LaunchPlan {
        try rejectControlCharacters(string)
        guard let c = URLComponents(string: string), let scheme = c.scheme?.lowercased() else {
            throw OpenRequestError.malformedURL(string)
        }
        switch scheme {
        case "ssh": return try validated(remoteLogin(c, string, program: "ssh"))
        case "telnet": return try validated(remoteLogin(c, string, program: "telnet"))
        case "x-man-page": return try validated(manPage(c, string))
        default: throw OpenRequestError.unsupportedScheme(string)
        }
    }

    /// Last line of defence: URL components arrive percent-decoded, so whatever the per-component
    /// checks missed, no argv element or folder may carry a control or line-separator character.
    public static func validated(_ plan: LaunchPlan) throws -> LaunchPlan {
        for s in plan.argv + (plan.directory.map { [$0] } ?? []) { try rejectControlCharacters(s) }
        return plan
    }

    // MARK: Schemes

    /// ssh://user@host:port → `ssh -p port -- user@host`; telnet://user@host:port → `telnet -l user -- host port`.
    /// `--` ends option parsing, so even a host that slipped past validation cannot become an option.
    private static func remoteLogin(_ c: URLComponents, _ raw: String, program: String) throws -> LaunchPlan {
        guard c.password == nil else { throw OpenRequestError.passwordInURL(raw) }
        guard c.path.isEmpty || c.path == "/", c.query == nil, c.fragment == nil else {
            throw OpenRequestError.unexpectedComponent(raw)
        }
        let host = try validHost(c.host, raw)
        let user = try c.user.map(validUser)
        let port = try c.port.map { p -> String in
            guard (1...65535).contains(p) else { throw OpenRequestError.invalidPort(raw) }
            return String(p)
        }
        if program == "ssh" {
            let dest = user.map { "\($0)@\(host)" } ?? host
            return LaunchPlan(directory: nil, argv: ["ssh"] + (port.map { ["-p", $0] } ?? []) + ["--", dest])
        }
        return LaunchPlan(directory: nil,
                          argv: ["telnet"] + (user.map { ["-l", $0] } ?? []) + ["--", host] + (port.map { [$0] } ?? []))
    }

    /// x-man-page://ls → `man -- ls`; x-man-page://3/printf → `man 3 -- printf`.
    private static func manPage(_ c: URLComponents, _ raw: String) throws -> LaunchPlan {
        guard c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
              let first = c.host, !first.isEmpty else { throw OpenRequestError.invalidManPage(raw) }
        let rest = c.path.split(separator: "/").map(String.init)
        switch rest.count {
        case 0:
            return LaunchPlan(directory: nil, argv: ["man", "--", try validManName(first, raw)])
        case 1:
            guard isSection(first) else { throw OpenRequestError.invalidManPage(raw) }
            return LaunchPlan(directory: nil, argv: ["man", first, "--", try validManName(rest[0], raw)])
        default:
            throw OpenRequestError.invalidManPage(raw)
        }
    }

    // MARK: Validation

    static func rejectControlCharacters(_ s: String) throws {
        // C0, DEL and C1: the PTY and zsh's line editor act on these even inside quotes.
        // U+2028/U+2029: line and paragraph separators, which some terminals and tools treat as newlines.
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }) {
            throw OpenRequestError.controlCharacter(s)
        }
    }

    private static let alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    private static let hostCharacters = CharacterSet(charactersIn: alnum + ".-_")
    private static let ipv6Characters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
    private static let userCharacters = CharacterSet(charactersIn: alnum + "._~+-")
    private static let manCharacters = CharacterSet(charactersIn: alnum + ".-_+:")
    private static let sectionCharacters = CharacterSet(charactersIn: alnum)
    private static let maxSectionLength = 8

    private static func validHost(_ host: String?, _ raw: String) throws -> String {
        guard let h = host, !h.isEmpty else { throw OpenRequestError.missingHost(raw) }
        // Colons only inside an IPv6 literal's brackets: [fe80::1] → fe80::1.
        if h.hasPrefix("["), h.hasSuffix("]") {
            let inner = String(h.dropFirst().dropLast())
            guard inner.contains(":"), inner.unicodeScalars.allSatisfy(ipv6Characters.contains) else {
                throw OpenRequestError.invalidHost(inner)
            }
            return inner
        }
        guard !h.hasPrefix("-"), h.unicodeScalars.allSatisfy(hostCharacters.contains) else {
            throw OpenRequestError.invalidHost(h)
        }
        return h
    }

    private static func validUser(_ user: String) throws -> String {
        // Allowlist on the percent-decoded user: %0A, %1B, %C2%85 and the like decode to raw control bytes.
        guard !user.isEmpty, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy(userCharacters.contains)
        else { throw OpenRequestError.invalidUser(user) }
        return user
    }

    private static func validManName(_ name: String, _ raw: String) throws -> String {
        guard !name.isEmpty, !name.hasPrefix("-"), name.unicodeScalars.allSatisfy(manCharacters.contains) else {
            throw OpenRequestError.invalidManPage(raw)
        }
        return name
    }

    private static func isSection(_ s: String) -> Bool {
        guard let f = s.first, f.isASCII, f.isNumber, s.count <= maxSectionLength else { return false }
        return s.unicodeScalars.allSatisfy(sectionCharacters.contains)
    }
}

/// How an accepted open request gets its pane window. Pure, so the app's window bookkeeping is testable.
/// Every request runs in a new window's first pane (WindowModel takes it from a queue as it appears).
public enum OpenRoute: Equatable, Sendable {
    /// An earlier request is still waiting for its window; that window asks for the next one.
    case waitForQueuedWindow
    /// Open a window now through SwiftUI's openWindow.
    case openWindow
    /// No window has appeared yet (launched to open this, so SwiftUI made none): use File ▸ New Window.
    case openWindowFromMenu
    /// Still launching: applicationDidFinishLaunching opens the window.
    case waitForLaunch

    public static func decide(queueIsEmpty: Bool, canOpenWindows: Bool, finishedLaunching: Bool) -> OpenRoute {
        if !queueIsEmpty { return .waitForQueuedWindow }
        if canOpenWindows { return .openWindow }
        return finishedLaunching ? .openWindowFromMenu : .waitForLaunch
    }
}
