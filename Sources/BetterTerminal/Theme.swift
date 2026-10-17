import AppKit
import CoreImage
import BTCore
import SwiftTerm
import SwiftUI

// SwiftTerm also exports `Color`; in this module it means the SwiftUI one.
typealias Color = SwiftUI.Color

/// Everything the Settings window can change. Stored as JSON in UserDefaults; export/import as a file.
struct ThemeData: Codable, Equatable {
    enum BackgroundKind: String, Codable, CaseIterable {
        case solid, image
        /// Themes saved before the gradient option was cut (0.4.3) still load, as a solid colour.
        init(from decoder: Decoder) throws {
            self = BackgroundKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .solid
        }
    }
    enum Timestamps: String, Codable, CaseIterable { case off, hover, always }

    var name = "iMessage Light"
    var mine = "#0A84FF"
    var mineText = "#FFFFFF"
    var output = "#E9E9EB"
    var outputText = "#000000"
    var error = "#FF453A"
    var cornerRadius = 18.0
    var maxMineWidth = 0.85

    var background = BackgroundKind.solid
    var backgroundColor = "#FFFFFF"
    var backgroundImage: String?          // file name inside App Support/backgrounds
    var blur = 0.0                        // 0...30
    var dim = 0.0                         // 0...0.8

    var fontName = "SF Mono"
    var fontSize = 13.0

    var timestamps = Timestamps.hover
    var collapseAfter = 40
    var panelPrograms = PanelPolicy.defaultPrograms.sorted()

    /// Dark thread background: chips, notices and the compose bar switch to dark styling.
    var isDark: Bool {
        switch background {
        case .solid: return (NSColor(hex: backgroundColor)?.luminance ?? 1) < 0.4
        case .image: return dim >= 0.4
        }
    }

    static let presets: [ThemeData] = [
        ThemeData(),
        ThemeData(name: "iMessage Dark", mine: "#0A84FF", mineText: "#FFFFFF", output: "#3A3A3C", outputText: "#FFFFFF",
                  error: "#FF453A", backgroundColor: "#000000"),
        ThemeData(name: "Midnight", mine: "#5E5CE6", mineText: "#FFFFFF", output: "#2A3552", outputText: "#D7E0F5",
                  error: "#FF6B6B", backgroundColor: "#0E1326"),
        ThemeData(name: "Paper", mine: "#2F6B4F", mineText: "#FFFDF7", output: "#F1EBDD", outputText: "#2B2B2B",
                  error: "#B3261E", cornerRadius: 10, backgroundColor: "#FBF8F1", fontName: "Menlo"),
    ]
}

extension ThemeData {
    /// Tolerant loading: a field missing from a saved theme (one saved by an older version, before a
    /// setting existed) takes its default instead of throwing away the whole saved theme.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeData()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? def }
        name = v(.name, d.name); mine = v(.mine, d.mine); mineText = v(.mineText, d.mineText)
        output = v(.output, d.output); outputText = v(.outputText, d.outputText); error = v(.error, d.error)
        cornerRadius = v(.cornerRadius, d.cornerRadius); maxMineWidth = v(.maxMineWidth, d.maxMineWidth)
        background = v(.background, d.background); backgroundColor = v(.backgroundColor, d.backgroundColor)
        backgroundImage = v(.backgroundImage, d.backgroundImage); blur = v(.blur, d.blur); dim = v(.dim, d.dim)
        fontName = v(.fontName, d.fontName); fontSize = v(.fontSize, d.fontSize)
        timestamps = v(.timestamps, d.timestamps); collapseAfter = v(.collapseAfter, d.collapseAfter)
        panelPrograms = v(.panelPrograms, d.panelPrograms)
    }
}

/// Persistent preferences: the theme plus the kill switch.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    /// Option held at launch, or `--classic`: classic everywhere for this run only (safe mode).
    /// Read once at startup (before any window), not lazily.
    private(set) var safeMode = NSEvent.modifierFlags.contains(.option)
    func forceSafeMode() { safeMode = true; objectWillChange.send() }

    /// Self-tests turn this off so they never change the user's saved settings.
    var persist = true

    @Published var classicEverywhereStored: Bool { didSet { if persist { d.set(classicEverywhereStored, forKey: "classicEverywhere") } } }
    @Published var defaultClassic: Bool { didSet { if persist { d.set(defaultClassic, forKey: "defaultClassic") } } }
    /// Right-click in a terminal: false = Mac menu (default); true = Windows Terminal style (copy if selected, else paste).
    @Published var rightClickCopyPaste: Bool { didSet { if persist { d.set(rightClickCopyPaste, forKey: "rightClickCopyPaste") } } }
    @Published var theme: ThemeData {
        didSet {
            guard theme != oldValue else { return }
            Theme.themeChanged()
            scheduleSave()
        }
    }

    /// Slider drags change the theme many times a second; write to disk once they settle.
    private var saveWork: DispatchWorkItem?
    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let j = try? JSONEncoder().encode(self.theme) else { return }
            self.d.set(j, forKey: "theme")
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    var classicEverywhere: Bool { safeMode || classicEverywhereStored }

    private init() {
        if CommandLine.arguments.contains("--classic") { safeMode = true }
        classicEverywhereStored = d.bool(forKey: "classicEverywhere")
        defaultClassic = d.bool(forKey: "defaultClassic")
        rightClickCopyPaste = d.bool(forKey: "rightClickCopyPaste")
        theme = d.data(forKey: "theme").flatMap { try? JSONDecoder().decode(ThemeData.self, from: $0) } ?? ThemeData()
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BetterTerminal")
    }
    /// Overridable so benchmarks never write into the user's App Support.
    static var backgroundsDirectory = supportDirectory.appendingPathComponent("backgrounds")
}

/// Reads the current theme. Views observe `Prefs.shared` so they redraw when it changes.
enum Theme {
    static var t: ThemeData { Prefs.shared.theme }

    /// Bumped on every theme change; part of render-cache keys.
    private(set) static var version = 0

    /// Colours and fonts resolved once per theme change (hex parsing and font lookup are not free).
    private struct Resolved {
        let font: NSFont, cellHeight: CGFloat, regular: Font, bold: Font
        let mine, mineText, output, outputText, error, secondary, composeBackground: Color
        let composeNSBackground, composeNSText, caret: NSColor
        let isDark: Bool
        let outputIsDark: Bool
        let panelNSBackground, panelNSText: NSColor

        init(_ t: ThemeData) {
            let size = CGFloat(t.fontSize)
            let custom = t.fontName != "SF Mono" ? NSFont(name: t.fontName, size: size) : nil
            font = custom ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            cellHeight = ceil(font.ascender - font.descender + font.leading)
            if custom != nil {
                regular = .custom(t.fontName, size: size); bold = .custom(t.fontName, size: size).weight(.bold)
            } else {
                regular = .system(size: size, design: .monospaced); bold = .system(size: size, weight: .bold, design: .monospaced)
            }
            isDark = t.isDark
            outputIsDark = (NSColor(hex: t.output)?.luminance ?? 1) < 0.45
            panelNSBackground = NSColor(hex: t.output) ?? .textBackgroundColor
            panelNSText = NSColor(hex: t.outputText) ?? .textColor
            mine = Color(hex: t.mine); mineText = Color(hex: t.mineText)
            output = Color(hex: t.output); outputText = Color(hex: t.outputText); error = Color(hex: t.error)
            secondary = isDark ? Color(white: 0.62) : Color(white: 0.45)
            composeBackground = isDark ? Color(white: 0.11) : .white
            composeNSBackground = isDark ? NSColor(white: 0.11, alpha: 1) : .white
            composeNSText = isDark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.1, alpha: 1)
            caret = NSColor(hex: t.mine) ?? .systemBlue
        }
    }
    private static var resolved = Resolved(Prefs.shared.theme)

    static func themeChanged() {
        resolved = Resolved(Prefs.shared.theme)
        version += 1
    }

    /// Changes only when something the terminal views draw with changes.
    static var terminalStyleKey: String { "\(t.fontName)|\(t.fontSize)|\(resolved.isDark)|\(t.mine)|\(t.output)|\(t.outputText)" }

    static var font: NSFont { resolved.font }
    static var cellHeight: CGFloat { resolved.cellHeight }
    static func swiftUIFont(bold: Bool = false) -> Font { bold ? resolved.bold : resolved.regular }

    static var mine: Color { resolved.mine }
    static var mineText: Color { resolved.mineText }
    static var output: Color { resolved.output }
    static var outputText: Color { resolved.outputText }
    static var error: Color { resolved.error }
    static var radius: CGFloat { CGFloat(t.cornerRadius) }
    static var composeBackground: Color { resolved.composeBackground }
    static var composeNSBackground: NSColor { resolved.composeNSBackground }
    static var composeNSText: NSColor { resolved.composeNSText }
    static var secondary: Color { resolved.secondary }
    static var panelNSBackground: NSColor { resolved.panelNSBackground }
    static var panelNSText: NSColor { resolved.panelNSText }

    static let fontChoices = ["SF Mono", "Menlo", "Monaco", "Courier New", "Andale Mono"]

    enum TerminalRole { case classic, panel, compose }

    /// The full classic view keeps the system's terminal look; the compose bar and the in-thread panel
    /// follow the bubble theme (no white slab inside a dark thread).
    static func style(_ v: TerminalView, role: TerminalRole) {
        if v.font != font { v.font = font }
        switch role {
        case .classic: v.nativeBackgroundColor = .textBackgroundColor; v.nativeForegroundColor = .textColor
        case .panel: v.nativeBackgroundColor = resolved.panelNSBackground; v.nativeForegroundColor = resolved.panelNSText
        case .compose: v.nativeBackgroundColor = composeNSBackground; v.nativeForegroundColor = composeNSText
        }
        v.caretColor = resolved.caret
        v.optionAsMetaKey = true
    }

    // MARK: ANSI colours for bubbles

    private static let base16: [(Double, Double, Double)] = [
        (0, 0, 0), (0.80, 0.18, 0.18), (0.20, 0.62, 0.20), (0.73, 0.60, 0.05),
        (0.15, 0.40, 0.85), (0.70, 0.25, 0.70), (0.10, 0.60, 0.65), (0.75, 0.75, 0.75),
        (0.45, 0.45, 0.45), (0.95, 0.30, 0.30), (0.30, 0.80, 0.30), (0.90, 0.80, 0.20),
        (0.35, 0.55, 1.00), (0.90, 0.40, 0.90), (0.25, 0.80, 0.85), (1, 1, 1),
    ]

    /// For dark output bubbles: black becomes light grey, blues/reds lighten so `ls` folders stay readable.
    private static let base16Dark: [(Double, Double, Double)] = [
        (0.62, 0.62, 0.62), (1.00, 0.42, 0.42), (0.45, 0.88, 0.45), (0.95, 0.85, 0.35),
        (0.45, 0.65, 1.00), (0.90, 0.55, 0.95), (0.40, 0.88, 0.92), (0.90, 0.90, 0.90),
        (0.70, 0.70, 0.70), (1.00, 0.55, 0.55), (0.55, 0.95, 0.55), (1.00, 0.92, 0.45),
        (0.60, 0.75, 1.00), (0.95, 0.65, 1.00), (0.55, 0.95, 1.00), (1, 1, 1),
    ]
    /// For light output bubbles: white and yellow darken so they show on light grey.
    private static let base16LightFix: [Int: (Double, Double, Double)] = [3: (0.62, 0.48, 0.0), 7: (0.45, 0.45, 0.45), 11: (0.70, 0.55, 0.0), 15: (0.30, 0.30, 0.30)]

    static func ansi(_ code: UInt8) -> Color {
        let c = Int(code)
        if c < 16 {
            let x = resolved.outputIsDark ? base16Dark[c] : (base16LightFix[c] ?? base16[c])
            return Color(red: x.0, green: x.1, blue: x.2)
        }
        if c < 232 {
            let i = c - 16
            let steps: [Double] = [0, 95, 135, 175, 215, 255]
            return Color(red: steps[i / 36] / 255, green: steps[(i / 6) % 6] / 255, blue: steps[i % 6] / 255)
        }
        let g = Double(8 + (c - 232) * 10) / 255
        return Color(red: g, green: g, blue: g)
    }

    static func color(_ c: Attribute.Color, fallback: Color?) -> Color? {
        switch c {
        case .ansi256(let code): return ansi(code)
        case .trueColor(let r, let g, let b): return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        default: return fallback
        }
    }

    /// Marks every case-insensitive match of `query` with a yellow background.
    static func highlight(_ text: AttributedString, _ query: String) -> AttributedString {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return text }
        var out = text
        var start = out.startIndex
        while start < out.endIndex, let r = out[start...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[r].backgroundColor = Color.yellow.opacity(0.85)
            out[r].foregroundColor = .black
            start = r.upperBound
        }
        return out
    }

    static func attributed(_ lines: ArraySlice<StyledLine>, defaultText: Color? = nil) -> AttributedString {
        var out = AttributedString()
        let text = defaultText ?? outputText
        for (i, line) in lines.enumerated() {
            if i > 0 { out.append(AttributedString("\n")) }
            // Screen.runs already stops at the last visible cell, so there is nothing to trim here.
            for r in line {
                var a = AttributedString(r.text)
                a.foregroundColor = color(r.fg, fallback: text)
                if let bg = color(r.bg, fallback: nil) { a.backgroundColor = bg }
                a.font = swiftUIFont(bold: r.bold)
                if r.underline { a.underlineStyle = .single }
                out.append(a)
            }
        }
        return out
    }
}

/// The background behind the bubbles.
struct ThreadBackground: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let t = prefs.theme
        ZStack {
            switch t.background {
            case .solid:
                Color(hex: t.backgroundColor)
            case .image:
                if let name = t.backgroundImage, let img = BackgroundCache.image(name: name, blur: t.blur) {
                    GeometryReader { g in
                        Image(decorative: img, scale: 1).resizable().scaledToFill()
                            .frame(width: g.size.width, height: g.size.height).clipped()
                    }
                } else {
                    Color(hex: t.backgroundColor)
                }
            }
            Color.black.opacity(t.dim)
        }
    }
}

/// Background pictures: decoded once, downsampled to ≤2560 px, blurred once per blur value.
/// (Decoding a 24 MP camera file in every view pass would cost ~100 MB per pane.)
@MainActor
enum BackgroundCache {
    private static var key = ""
    private static var cached: CGImage?
    private static let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    static func image(name: String, blur: Double) -> CGImage? {
        let k = "\(name)|\(Int(blur))"
        if k == key { return cached }
        // A blurred picture needs far fewer pixels: blur at ≤960 px (the view scales it up), which
        // keeps a slider drag at a few MB instead of hundreds.
        let maxPixels = blur > 0 ? 960 : 2560
        let url = Prefs.backgroundsDirectory.appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              var img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { key = k; cached = nil; return nil }
        if blur > 0 {
            let input = CIImage(cgImage: img)
            let ci = input.clampedToExtent().applyingGaussianBlur(sigma: blur * Double(maxPixels) / 1280)
            if let out = context.createCGImage(ci, from: input.extent) { img = out }
            context.clearCaches()
        }
        key = k
        cached = img
        return img
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex) ?? .gray) }
}
