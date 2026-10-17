import AppKit
import BTCore
import SwiftUI
import UniformTypeIdentifiers

/// ⌘, : changes apply live and persist.
struct SettingsView: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            BubblesTab().tabItem { Label("Bubbles", systemImage: "bubble.left.and.bubble.right") }
            BackgroundTab().tabItem { Label("Background", systemImage: "photo") }
            TextTab().tabItem { Label("Text", systemImage: "textformat") }
            ThreadTab().tabItem { Label("Thread", systemImage: "list.bullet") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

/// Two-way binding between a hex string in the theme and a SwiftUI ColorPicker.
private func colorBinding(_ key: WritableKeyPath<ThemeData, String>) -> Binding<Color> {
    Binding(
        get: { Color(hex: Prefs.shared.theme[keyPath: key]) },
        set: { Prefs.shared.theme[keyPath: key] = NSColor($0).hex }
    )
}

private struct GeneralTab: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        Form {
            Picker("New panes open in", selection: $prefs.defaultClassic) {
                Text("Bubble view").tag(false)
                Text("Classic view").tag(true)
            }
            Picker("Right-click in the terminal", selection: $prefs.rightClickCopyPaste) {
                Text("Shows a menu (Mac)").tag(false)
                Text("Copies the selection, or pastes (Windows Terminal)").tag(true)
            }
            Toggle("Classic view everywhere (⌘⇧\\)", isOn: $prefs.classicEverywhereStored)
                .disabled(prefs.safeMode)
            if prefs.safeMode {
                Text("Safe mode: Option was held at launch, so every pane is in classic view until you relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Shell", value: "/bin/zsh (login shell, your usual dotfiles)")
            LabeledContent("Saved transcripts", value: "Off: threads live in memory only")
        }
        .formStyle(.grouped)
    }
}

private struct BubblesTab: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        Form {
            Section("Preset") {
                Picker("Theme", selection: Binding(
                    get: { prefs.theme.name },
                    set: { name in
                        guard var p = ThemeData.presets.first(where: { $0.name == name }) else { return }
                        // Presets change looks only; keep the user's thread and panel settings.
                        p.timestamps = prefs.theme.timestamps
                        p.collapseAfter = prefs.theme.collapseAfter
                        p.panelPrograms = prefs.theme.panelPrograms
                        prefs.theme = p
                    })) {
                    ForEach(ThemeData.presets, id: \.name) { Text($0.name).tag($0.name) }
                    if !ThemeData.presets.contains(where: { $0.name == prefs.theme.name }) {
                        Text(prefs.theme.name).tag(prefs.theme.name)
                    }
                }
            }
            Section("Colours") {
                ColorPicker("My bubbles", selection: colorBinding(\.mine), supportsOpacity: false)
                ColorPicker("My text", selection: colorBinding(\.mineText), supportsOpacity: false)
                ColorPicker("Output bubbles", selection: colorBinding(\.output), supportsOpacity: false)
                ColorPicker("Output text", selection: colorBinding(\.outputText), supportsOpacity: false)
                ColorPicker("Error badge", selection: colorBinding(\.error), supportsOpacity: false)
            }
            Section("Shape") {
                LabeledContent("Corner radius") {
                    Slider(value: $prefs.theme.cornerRadius, in: 0...24, step: 1)
                    Text("\(Int(prefs.theme.cornerRadius))").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
                LabeledContent("Max width of my bubbles") {
                    Slider(value: $prefs.theme.maxMineWidth, in: 0.4...1, step: 0.05)
                    Text("\(Int(prefs.theme.maxMineWidth * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Section("Preview") { ThemePreview() }
            Section {
                HStack {
                    Spacer()
                    Button("Reset to Default") { prefs.theme = ThemeData() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.theme) { old, new in
            // Any hand edit turns a preset into "Custom".
            if old.name == new.name, ThemeData.presets.contains(where: { $0.name == new.name }),
               var p = ThemeData.presets.first(where: { $0.name == new.name }) {
                p.timestamps = new.timestamps; p.collapseAfter = new.collapseAfter; p.panelPrograms = new.panelPrograms
                if p != new { prefs.theme.name = "Custom" }
            }
        }
    }
}

private struct BackgroundTab: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        Form {
            Picker("Behind the bubbles", selection: $prefs.theme.background) {
                Text("Solid colour").tag(ThemeData.BackgroundKind.solid)
                Text("Image").tag(ThemeData.BackgroundKind.image)
            }
            .pickerStyle(.segmented)
            switch prefs.theme.background {
            case .solid:
                ColorPicker("Colour", selection: colorBinding(\.backgroundColor), supportsOpacity: false)
            case .image:
                LabeledContent("Image") {
                    Text(prefs.theme.backgroundImage ?? "None").foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose…") { ThemeFiles.chooseBackground() }
                }
                LabeledContent("Blur") {
                    Slider(value: $prefs.theme.blur, in: 0...30, step: 1)
                    Text("\(Int(prefs.theme.blur))").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }
            LabeledContent("Dim") {
                Slider(value: $prefs.theme.dim, in: 0...0.8, step: 0.05)
                Text("\(Int(prefs.theme.dim * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Section("Preview") { ThemePreview() }
        }
        .formStyle(.grouped)
    }
}

private struct TextTab: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        Form {
            Picker("Font", selection: $prefs.theme.fontName) {
                ForEach(Theme.fontChoices, id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Size") {
                Stepper(value: $prefs.theme.fontSize, in: 9...24, step: 1) {
                    Text("\(Int(prefs.theme.fontSize)) pt").monospacedDigit()
                }
            }
            Section("Preview") { ThemePreview() }
        }
        .formStyle(.grouped)
    }
}

private struct ThreadTab: View {
    @ObservedObject private var prefs = Prefs.shared
    // Not @State: on the macOS 27 SDK it is a macro whose plugin ships only with Xcode, not the CLT.
    @StateObject private var draft = Draft()
    final class Draft: ObservableObject { @Published var text = "" }
    var body: some View {
        Form {
            Picker("Timestamps", selection: $prefs.theme.timestamps) {
                Text("Off").tag(ThemeData.Timestamps.off)
                Text("On hover").tag(ThemeData.Timestamps.hover)
                Text("Always").tag(ThemeData.Timestamps.always)
            }
            Picker("Collapse output longer than", selection: $prefs.theme.collapseAfter) {
                ForEach([20, 40, 80, 200], id: \.self) { Text("\($0) lines").tag($0) }
                Text("Never").tag(0)
            }
            Section {
                TextField("Programs", text: $draft.text, axis: .vertical)
                    .lineLimit(3...6)
                    .onSubmit(savePrograms)
                HStack {
                    Button("Save List", action: savePrograms)
                    Button("Restore Defaults") {
                        prefs.theme.panelPrograms = PanelPolicy.defaultPrograms.sorted()
                        draft.text = prefs.theme.panelPrograms.joined(separator: ", ")
                    }
                }
            } header: {
                Text("Open in a full terminal")
            } footer: {
                Text("Comma-separated. These commands get the full terminal while they run, like vim does. Use it for programs that redraw the screen without switching to it (claude) or that host another shell (ssh, tmux).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { draft.text = prefs.theme.panelPrograms.joined(separator: ", ") }
    }

    private func savePrograms() {
        prefs.theme.panelPrograms = draft.text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// A small live preview of the current theme.
struct ThemePreview: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Text("ls").font(Theme.swiftUIFont()).foregroundStyle(Theme.mineText)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.mine, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
            Text("Package.swift  Sources  Tests").font(Theme.swiftUIFont()).foregroundStyle(Theme.outputText)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.output, in: RoundedRectangle(cornerRadius: Theme.radius))
            Text("✗  exit 1 · 12 ms").font(.caption2.weight(.medium)).foregroundStyle(Theme.error).padding(.leading, 12)
        }
        .padding(12)
        .background(ThreadBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
enum ThemeFiles {
    /// Copies the chosen picture into App Support, so the theme never points into other folders.
    static func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let dir = Prefs.backgroundsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString.prefix(8))-\(src.lastPathComponent)"
        do {
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name))
            Prefs.shared.theme.backgroundImage = name
            Prefs.shared.theme.background = .image
        } catch {
            NSSound.beep()
        }
    }
}
