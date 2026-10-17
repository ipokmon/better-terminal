// Renders docs/img/mock-*.png from synthetic content. Run as a SwiftPM executable target (macOS 14+) with the output dir as argv[1].
import SwiftUI
import AppKit
let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
let grey = Color(red: 0.914, green: 0.914, blue: 0.922)
let mono = Font.system(size: 12, design: .monospaced)

struct Mine: View { let t: String
  var body: some View { HStack { Spacer(minLength: 120)
    Text(t).font(mono).foregroundColor(.white).padding(.horizontal, 12).padding(.vertical, 8)
      .background(blue).clipShape(RoundedRectangle(cornerRadius: 18)) } } }

struct Out: View { let t: String; var badge: String? = nil; var fail = false; var live = false
  var body: some View { VStack(alignment: .leading, spacing: 3) {
    HStack { VStack(alignment: .leading) { Text(t).font(mono).foregroundColor(.black) }
        .padding(.horizontal, 12).padding(.vertical, 8).background(grey).clipShape(RoundedRectangle(cornerRadius: 18))
      Spacer(minLength: 80) }
    if live { HStack(spacing: 5) { Circle().fill(Color.green).frame(width: 7, height: 7); Text("live").font(.caption2).foregroundColor(.secondary) }.padding(.leading, 12) }
    if let b = badge { Text(b).font(.caption2.weight(.medium)).foregroundColor(fail ? Color(red: 1, green: 0.27, blue: 0.23) : .secondary).padding(.leading, 12) }
  } } }

struct Chip: View { let t: String
  var body: some View { HStack { Text("▣  " + t).font(.caption).foregroundColor(.secondary)
    .padding(.horizontal, 10).padding(.vertical, 5).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.5))); Spacer() } } }

struct Thread: View {
  var body: some View {
    VStack(spacing: 0) {
      // title bar + tabs
      HStack(spacing: 8) {
        HStack(spacing: 7) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) } }
        Spacer()
        Text("mini-apps").font(.system(size: 12, weight: .semibold))
        Spacer()
        Text("💬  ▤   📷").font(.system(size: 13)).foregroundColor(.secondary)
      }.padding(.horizontal, 14).frame(height: 38).background(Color(white: 0.95))
      HStack(spacing: 0) {
        Text("mini-apps").font(.caption).frame(maxWidth: .infinity).padding(6).background(Color.white)
        Text("ssh pc").font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity).padding(6)
      }.background(Color(white: 0.9))
      Divider()
      VStack(spacing: 10) {
        Text("Today 20:41").font(.caption2).foregroundColor(.secondary)
        Mine(t: "git status -s")
        Out(t: " M products/better-terminal/brief.md\n?? products/better-terminal/docs/", badge: "✓  0.04 s")
        Mine(t: "curl -LO https://example.org/model.gguf")
        Out(t: "  % Total    % Received  Speed   Left\n 63 16.8G   63 10.6G   212M  0:00:30", live: true)
        Mine(t: "make test")
        Out(t: "Splitter: 11 passed, 1 failed\n  ✗ alt-screen exit restores bubbles", badge: "✗  exit 2 · 3.1 s", fail: true)
        Mine(t: "vim notes.txt")
        Chip(t: "vim notes.txt · 4 min")
      }.padding(16).frame(maxHeight: .infinity, alignment: .top)
      // compose bar
      HStack { Text("~/mini-apps % ").font(mono).foregroundColor(.secondary) + Text("brew upd").font(mono); Rectangle().frame(width: 7, height: 15).foregroundColor(blue.opacity(0.7)); Spacer()
        Text("⌘\\ classic").font(.caption2).foregroundColor(.secondary) }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 18).stroke(Color.gray.opacity(0.4)).background(RoundedRectangle(cornerRadius: 18).fill(Color.white)))
        .padding(12)
    }.frame(width: 620, height: 720).background(Color.white)
  }
}

struct Row: View { let k: String; let v: AnyView
  var body: some View { HStack { Text(k).font(.system(size: 12)); Spacer(); v }.padding(.vertical, 5) } }
func swatch(_ c: Color) -> AnyView { AnyView(RoundedRectangle(cornerRadius: 5).fill(c).frame(width: 34, height: 18).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.4)))) }
func val(_ s: String) -> AnyView { AnyView(Text(s).font(.system(size: 12)).foregroundColor(.secondary)) }

struct SettingsMock: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 22) { ForEach(["General", "Bubbles", "Background", "Text", "Thread"], id: \.self) { t in
        Text(t).font(.system(size: 11, weight: t == "Bubbles" ? .bold : .regular)).foregroundColor(t == "Bubbles" ? blue : .primary) } }
        .frame(maxWidth: .infinity).padding(12).background(Color(white: 0.95))
      VStack(alignment: .leading, spacing: 2) {
        Text("Preset").font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.top, 10)
        Row(k: "Theme", v: val("iMessage Light  ▾"))
        Text("Colours").font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.top, 10)
        Row(k: "My bubbles", v: swatch(blue)); Row(k: "My text", v: swatch(.white))
        Row(k: "Output bubbles", v: swatch(grey)); Row(k: "Output text", v: swatch(.black))
        Row(k: "Error badge", v: swatch(Color(red: 1, green: 0.27, blue: 0.23)))
        Text("Shape").font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.top, 10)
        Row(k: "Corner radius", v: val("●──────── 18"))
        Row(k: "Max bubble width", v: val("──────●── 85%"))
        Text("Preview").font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.top, 10)
        VStack(spacing: 6) { Mine(t: "ls"); Out(t: "Package.swift  Sources  Tests") }
          .padding(10).background(LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 1), Color(red: 0.98, green: 0.93, blue: 0.97)], startPoint: .top, endPoint: .bottom)).clipShape(RoundedRectangle(cornerRadius: 10))
        HStack { Spacer(); Text("Export theme…   Import…   Reset").font(.system(size: 11)).foregroundColor(blue) }.padding(.top, 10)
      }.padding(.horizontal, 20).padding(.bottom, 16)
    }.frame(width: 460).background(Color.white)
  }
}

@MainActor func render<V: View>(_ v: V, _ path: String) {
  let r = ImageRenderer(content: v.environment(\.colorScheme, .light)); r.scale = 2
  guard let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
        let png = rep.representation(using: .png, properties: [:]) else { print("fail", path); return }
  try! png.write(to: URL(fileURLWithPath: path)); print(path, png.count)
}
MainActor.assumeIsolated {
  let d = CommandLine.arguments[1]
  render(Thread(), d + "/mock-thread.png")
  render(SettingsMock(), d + "/mock-settings.png")
}
