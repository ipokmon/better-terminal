import AppKit
import BTCore
import SwiftTerm
import SwiftUI

/// Hosts an existing terminal NSView (owned by the pane model) inside SwiftUI.
struct TerminalHost: NSViewRepresentable {
    let view: TerminalView
    func makeNSView(context: Context) -> TerminalView { view }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

/// Reports the NSWindow (and an anchor NSView) a SwiftUI view lives in.
struct ViewAnchor: NSViewRepresentable {
    var onAttach: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = AnchorNSView()
        v.onAttach = onAttach
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AnchorNSView: NSView {
        var onAttach: (NSView) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onAttach(self) }
        }
    }
}

struct PaneFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Root of a window: the split tree.
struct WindowView: View {
    @StateObject private var model: WindowModel
    @Environment(\.openWindow) private var openWindow

    /// `ticket`: set when OpenHandler opened this window for a queued file or URL; nil for ⌘N, tabs, splits.
    init(model: WindowModel? = nil, ticket: LaunchTicket? = nil) {
        _model = StateObject(wrappedValue: model ?? WindowModel(plan: OpenHandler.claim(ticket)))
    }

    var body: some View {
        NodeView(node: model.root, window: model)
            .coordinateSpace(name: "window")
            .onPreferenceChange(PaneFramesKey.self) { frames in
                MainActor.assumeIsolated { model.frames = frames }
            }
            .background(ViewAnchor { v in
                MainActor.assumeIsolated { if let w = v.window { model.attach(w) } }
            })
            .navigationTitle(model.title)
            .focusedSceneObject(model)
            .onAppear {
                let open = openWindow
                AppActions.openPaneWindow = { open(id: "pane") }
            }
            .onDisappear { model.closeAll() }
    }
}

struct NodeView: View {
    let node: WindowModel.Node
    @ObservedObject var window: WindowModel

    var body: some View {
        switch node {
        case .pane(let p):
            PaneView(model: p, window: window)
        case .split(_, let axis, let a, let b):
            if axis == .sideBySide {
                HSplitView {
                    NodeView(node: a, window: window)
                    NodeView(node: b, window: window)
                }
            } else {
                VSplitView {
                    NodeView(node: a, window: window)
                    NodeView(node: b, window: window)
                }
            }
        }
    }
}

struct PaneView: View {
    @ObservedObject var model: PaneModel
    @ObservedObject var window: WindowModel
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if !model.showsFullClassic {
                    VStack(spacing: 0) {
                        if model.findVisible { FindBar(model: model) }
                        ThreadList(model: model)
                        if model.showsPanel {
                            PanelHint(model: model)
                        } else {
                            ComposeBar(model: model)
                        }
                    }
                    .background(ThreadBackground())
                    .zIndex(1)
                }
                // One classic terminal per pane, never re-parented: hidden behind the thread, a framed
                // panel over the lower part of the thread, or the whole pane. It always sizes the PTY.
                TerminalHost(view: model.classicView)
                    .padding(model.showsPanel ? 10 : 0)
                    .background(model.showsPanel ? Theme.output : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: model.showsPanel ? 14 : 0))
                    .overlay {
                        if model.showsPanel {
                            RoundedRectangle(cornerRadius: 14).stroke(Theme.mine.opacity(0.7), lineWidth: 1.5)
                        }
                    }
                    .shadow(color: .black.opacity(model.showsPanel ? 0.25 : 0), radius: 12, y: 4)
                    .padding(.horizontal, model.showsPanel ? 14 : 16)
                    .padding(.top, model.showsPanel ? max(80, geo.size.height * 0.22) : 8)
                    .padding(.bottom, model.showsPanel ? 52 : 8)
                    .opacity(model.showsClassic ? 1 : 0)
                    .allowsHitTesting(model.showsClassic)
                    .zIndex(model.showsClassic ? 2 : 0)
                if window.panes.count > 1 && window.focused !== model {
                    Color.black.opacity(0.06).allowsHitTesting(false).zIndex(3)
                }
                if let toast = model.toast {
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .frame(maxHeight: .infinity)
                        .zIndex(4)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
        .animation(.easeOut(duration: 0.18), value: model.showsPanel)
        // A hidden NSView skips drawing; opacity 0 alone still redraws the classic view on every byte.
        .onAppear { model.classicView.isHidden = !model.showsClassic }
        .onChange(of: model.showsClassic) { _, shown in model.classicView.isHidden = !shown }
        .onChange(of: model.showsPanel) { _, _ in model.restyleClassic() }
        .background(Color(nsColor: .textBackgroundColor))
        .background(ViewAnchor { v in MainActor.assumeIsolated { model.anchorView = v } })
        .background(GeometryReader { g in
            Color.clear.preference(key: PaneFramesKey.self, value: [model.id: g.frame(in: .named("window"))])
        })
        .frame(minWidth: 200, minHeight: 120)
        .simultaneousGesture(TapGesture().onEnded { window.focused = model })
        .toolbar {
            if window.focused === model {
                ToolbarItemGroup {
                    Button { Screenshot.copy(pane: model) } label: { Image(systemName: "camera") }
                        .help("Copy screenshot of this pane (⌘⇧S)")
                    Button { model.toggleClassic() } label: {
                        Image(systemName: model.showsFullClassic ? "bubble.left.and.bubble.right" : "terminal")
                    }
                    .help(model.showsFullClassic ? "Bubble view (⌘\\)" : "Classic view (⌘\\)")
                    .disabled(prefs.classicEverywhere)
                }
            }
        }
    }
}

/// Replaces the compose bar while a program runs in the panel.
struct PanelHint: View {
    @ObservedObject var model: PaneModel
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "macwindow")
            Text("\(model.running?.label ?? "Program") is running in the panel · keys go to it · ⌘\\ for the full pane")
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.caption).foregroundStyle(Theme.secondary)
        .frame(maxWidth: .infinity).frame(height: 40)
    }
}

struct ThreadList: View {
    @ObservedObject var model: PaneModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let current = model.currentMatch // once per pass, not once per bubble
                let query = model.findVisible ? model.findQuery : ""
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.entries) { entry in
                        EntryView(entry: entry, current: entry.id == current, query: query)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { model.bottomAppeared() }
                        .onDisappear { model.bottomDisappeared() }
                }
                .padding(16)
            }
            .onChange(of: model.scrollTick) { if model.followBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.jumpTick) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.findTick) {
                if let id = model.currentMatch { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .overlay(alignment: .bottomTrailing) {
                if model.newBelow && !model.followBottom {
                    Button { model.resumeFollowing() } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.mine, in: Capsule())
                            .foregroundStyle(Theme.mineText)
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.newBelow && !model.followBottom)
        }
    }
}

/// The ⌘F bar over the thread.
struct FindBar: View {
    @ObservedObject var model: PaneModel
    var body: some View {
        let n = model.findMatches.count
        HStack(spacing: 8) {
            FindField(model: model).frame(maxWidth: 280)
            Text(model.findQuery.isEmpty ? "" : (n == 0 ? "No matches" : "\(min(model.findIndex, n - 1) + 1) of \(n)"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button { model.findStep(-1) } label: { Image(systemName: "chevron.up") }.disabled(n == 0).help("Previous (⌘⇧G)")
            Button { model.findStep(1) } label: { Image(systemName: "chevron.down") }.disabled(n == 0).help("Next (⌘G)")
            Spacer()
            Button("Done") { model.closeFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

/// NSSearchField: focuses itself, Return = next, Shift-Return = previous, Escape = close.
struct FindField: NSViewRepresentable {
    @ObservedObject var model: PaneModel

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Find in thread"
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }
    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != model.findQuery { f.stringValue = model.findQuery }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: PaneModel
        init(model: PaneModel) { self.model = model }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSSearchField else { return }
            MainActor.assumeIsolated {
                model.findQuery = f.stringValue
                let m = model.findMatches.count
                if m > 0 { model.findStep(m - 1) } // jump to the newest match
            }
        }
        func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            MainActor.assumeIsolated {
                switch sel {
                case #selector(NSResponder.insertNewline(_:)):
                    model.findStep(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); return true
                case #selector(NSResponder.cancelOperation(_:)):
                    model.closeFind(); return true
                default: return false
                }
            }
        }
    }
}

struct EntryView: View {
    let entry: ThreadEntry
    var current = false
    var query = ""
    var body: some View {
        switch entry {
        case .command(let item):
            CommandView(item: item, query: query)
                .padding(current ? 6 : 0)
                .overlay {
                    if current { RoundedRectangle(cornerRadius: Theme.radius + 6).stroke(Color.orange, lineWidth: 2.5) }
                }
        case .notice(_, let text):
            Text(text).font(.caption).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity)
        }
    }
}

struct CommandView: View {
    @ObservedObject var item: CommandItem
    var query = ""
    @ObservedObject private var prefs = Prefs.shared
    static let headLines = 10, tailLines = 20, expandedLimit = 2_000

    var body: some View {
        let t = prefs.theme
        VStack(alignment: .leading, spacing: 4) {
            if let cmd = item.command {
                if t.timestamps == .always {
                    Text(item.started.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity)
                }
                HStack {
                    Spacer(minLength: 0)
                    Text(Theme.highlight(AttributedString(cmd), query))
                        .font(Theme.swiftUIFont())
                        .foregroundStyle(Theme.mineText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.mine, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .accessibilityLabel("You ran: \(cmd)")
                        .contextMenu { commandMenu(cmd) }
                        .help(t.timestamps == .hover ? item.started.formatted(date: .abbreviated, time: .standard) : "")
                }
                .containerRelativeFrameCompat(fraction: t.maxMineWidth)
                .padding(.top, 4)
            }
            if item.panel {
                Label("\(item.label)\(item.isLive ? " · running in full terminal" : " · \(Self.format(item.duration))")",
                      systemImage: "macwindow")
                    .font(.caption).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.secondary.opacity(0.6)))
            }
            if !item.lines.isEmpty {
                output(collapseAfter: t.collapseAfter)
            }
            if item.isLive && !item.panel && (item.quiet || item.awaitingSecret) {
                if item.awaitingSecret {
                    Label("Password: type it and press Return (it stays hidden)", systemImage: "key.fill")
                        .labelStyle(KeyLabelStyle())
                        .font(.callout)
                        .foregroundStyle(Theme.outputText)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.output, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .accessibilityLabel("Waiting for a password. Typing is hidden.")
                } else {
                    TypingDots(still: item.longQuiet, since: item.quietSince)
                }
            }
            if item.lines.isEmpty && item.command != nil && !item.panel {
                HStack { Spacer(); footer }.padding(.trailing, 12)
            } else {
                footer.padding(.leading, 12)
            }
            if let hint = item.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func output(collapseAfter: Int) -> some View {
        let n = item.lines.count
        // A find match anywhere in this bubble opens it (searchText is cached once the command ends).
        let hiddenMatch = !query.isEmpty && item.searchText.contains(query.lowercased())
        // Never collapse when head + tail would already show every line (no repeated lines).
        let collapsed = collapseAfter > 0 && n > max(collapseAfter, Self.headLines + Self.tailLines)
            && !item.expanded && !hiddenMatch
        return VStack(alignment: .leading, spacing: 6) {
            if item.omittedLines > 0 {
                Text("\(item.omittedLines.formatted()) earlier lines not kept · the classic view (⌘\\) has recent history")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            if collapsed {
                Text(item.rendered(.head(Self.headLines), query: query)).textSelection(.enabled)
                Button("Show all \(n.formatted()) lines") { item.expanded = true }
                    .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Theme.mine)
                    .accessibilityHint("Expands the output")
                Text(item.rendered(.tail(Self.tailLines), query: query)).textSelection(.enabled)
            } else if n > Self.expandedLimit {
                // Laying out 10,000 lines as one text costs seconds per theme change; the bubble shows the
                // newest 2,000 and points at the classic view (⌘\\) for the rest.
                Text("Showing the last \(Self.expandedLimit.formatted()) of \(n.formatted()) lines · ⌘\\ shows everything in the classic view")
                    .font(.caption).foregroundStyle(Theme.secondary)
                Text(item.rendered(.tail(Self.expandedLimit), query: query)).textSelection(.enabled)
                showLess
            } else {
                Text(item.rendered(.all, query: query)).textSelection(.enabled)
                if n > collapseAfter && collapseAfter > 0 { showLess }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.output, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            if failed { RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.error.opacity(0.85), lineWidth: 2) }
        }
        .contextMenu { outputMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Output\(failed ? ", failed" : "")")
        .padding(.trailing, 24)
    }

    /// "Copy" copies what is selected in the bubble (the selectable text is first responder after a selection).
    private func copySelection() { NSApp.sendAction(NSSelectorFromString("copy:"), to: nil, from: nil) }

    @ViewBuilder private func commandMenu(_ cmd: String) -> some View {
        Button("Copy") { copySelection() }
        Button("Copy Command") { PaneModel.copyToClipboard(cmd) }
        Divider()
        Button("Paste Command into Prompt") { item.pane?.pasteIntoPrompt(cmd) }
        Button("Run Again") { item.pane?.runAgain(cmd) }.disabled(item.pane?.running != nil)
        Divider()
        Button("Paste Clipboard into Prompt") { item.pane?.pasteIntoPrompt(NSPasteboard.general.string(forType: .string) ?? "") }
    }

    @ViewBuilder private var outputMenu: some View {
        Button("Copy") { copySelection() }
        Button("Copy Output") { PaneModel.copyToClipboard(item.outputText) }
        if let cmd = item.command {
            Button("Copy Command and Output") { PaneModel.copyToClipboard("$ " + cmd + "\n" + item.outputText) }
        }
        Divider()
        Button("Paste Clipboard into Prompt") { item.pane?.pasteIntoPrompt(NSPasteboard.general.string(forType: .string) ?? "") }
    }

    private var showLess: some View {
        Button("Show less") { item.expanded = false }
            .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Theme.mine)
    }

    @ViewBuilder private var footer: some View {
        if item.isLive {
            if !item.panel {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("live").font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
        } else if item.command != nil && !item.panel {
            let label: String = {
                switch item.exitCode {
                case 0: return "✓  \(Self.format(item.duration))"
                case 130: return "interrupted · \(Self.format(item.duration))"
                case 128 + SIGTSTP: return "suspended · fg resumes it"
                case let code?: return "✗  exit \(code) · \(Self.format(item.duration))"
                case nil: return Self.format(item.duration)
                }
            }()
            if failed {
                // A failure is a red pill, not just red text: easy to spot over a remote link.
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.error, in: Capsule())
                    .accessibilityLabel("Failed, exit code \(item.exitCode ?? 0), \(Self.format(item.duration))")
            } else {
                Text(label).font(.caption2.weight(.medium)).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// Non-zero exit, except Ctrl-C (130, "interrupted") and Ctrl-Z (146 on macOS, "suspended").
    private var failed: Bool { !item.isLive && ![0, 130, 128 + SIGTSTP].contains(item.exitCode ?? 0) }

    static func format(_ t: TimeInterval) -> String {
        if t < 1 { return "\(max(1, Int(t * 1000))) ms" }
        if t < 60 { return String(format: "%.1f s", t) }
        let m = Int(t) / 60, s = Int(t) % 60
        return m < 60 ? "\(m) min \(s) s" : "\(m / 60) h \(m % 60) min"
    }
}

extension View {
    /// Right-aligned row whose content may use at most `fraction` of the available width.
    func containerRelativeFrameCompat(fraction: Double) -> some View {
        modifier(MaxWidthFraction(fraction: fraction))
    }
}

private struct MaxWidthFraction: ViewModifier {
    let fraction: Double
    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content.containerRelativeFrame(.horizontal, alignment: .trailing) { w, _ in w * fraction }
        }
    }
}

/// "🔑 Password …": the emoji, not the SF Symbol, so it reads like a message.
struct KeyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { Text("🔑"); configuration.title }
    }
}

/// The iMessage "typing" bubble: three dots pulsing in turn while a command is quiet.
/// Static dots with Reduce Motion; the animation only runs while the bubble is on screen.
struct TypingDots: View {
    /// Quiet for over a minute: stop animating (a waiting server shouldn't cost power for hours).
    var still = false
    var since: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let frozen = reduceMotion || still
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: frozen)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = frozen ? 0.6 : 0.35 + 0.65 * max(0, sin((t * 2 * .pi / 1.2) - Double(i) * 0.9))
                    Circle().frame(width: 8, height: 8).opacity(phase)
                }
                if still, let since {
                    Text("quiet since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).padding(.leading, 4)
                }
            }
            .foregroundStyle(Theme.outputText.opacity(0.55))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.output, in: Capsule())
        }
        .accessibilityLabel("Still working")
    }
}

struct ComposeBar: View {
    @ObservedObject var model: PaneModel
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let cell = Theme.cellHeight
        ZStack(alignment: .topTrailing) {
            TerminalHost(view: model.composeView)
                .frame(height: CGFloat(PaneModel.composeMaxRows) * cell)
                .frame(height: CGFloat(model.composeRows) * cell, alignment: .top)
                .clipped()
            if let r = model.running, !r.panel {
                Text(r.awaitingSecret ? "🔑 password input is hidden · Return sends it" : "↳ typing to \(r.label) · ⌃C stops it")
                    .lineLimit(1).truncationMode(.middle)
                    .font(.caption).foregroundStyle(Theme.secondary)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .overlay(alignment: .bottomTrailing) {
            if model.running == nil {
                Text("⌘\\ classic").font(.caption2).foregroundStyle(Theme.secondary.opacity(0.8))
                    .padding(.trailing, 10).padding(.bottom, 2).allowsHitTesting(false)
            }
        }
        .background(Theme.composeBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.secondary.opacity(0.5)))
        .padding(.horizontal, 8).padding(.bottom, 10).padding(.top, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.host?.focused = model; model.focusActive() }
    }
}
