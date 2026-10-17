// Renders the app icon: a dark rounded square with an iMessage-style conversation:
// a blue "you" bubble holding a prompt, and a grey "output" bubble holding text lines.
// Build and run (Command Line Tools only):
//   swiftc -O -o makeicon MakeIcon.swift && ./makeicon AppIcon.iconset && iconutil -c icns AppIcon.iconset
import AppKit
import SwiftUI

struct Icon: View {
    let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        ZStack {
            // macOS icon grid: an 824 pt rounded square centred on a 1024 canvas
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.24), Color(red: 0.03, green: 0.03, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 4)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)

            VStack(spacing: 54) {
                // you: blue bubble on the right, with a prompt
                HStack {
                    Spacer(minLength: 0)
                    Bubble(fill: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.32, green: 0.70, blue: 1.0), blue],
                                                              startPoint: .top, endPoint: .bottom)),
                           tailRight: true, width: 430, height: 200) {
                        HStack(alignment: .center, spacing: 26) {
                            Image(systemName: "chevron.right").font(.system(size: 92, weight: .heavy))
                            RoundedRectangle(cornerRadius: 10).frame(width: 110, height: 24).offset(y: 30)
                        }
                        .foregroundStyle(.white)
                    }
                }
                // output: grey bubble on the left, with text lines
                HStack {
                    Bubble(fill: AnyShapeStyle(Color(white: 0.91)), tailRight: false, width: 520, height: 250) {
                        VStack(alignment: .leading, spacing: 30) {
                            Capsule().frame(width: 360, height: 30)
                            Capsule().frame(width: 250, height: 30)
                            Capsule().frame(width: 310, height: 30)
                        }
                        .foregroundStyle(Color(white: 0.52))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 660)
            .offset(y: -6)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// A rounded bubble plus a separate tail, filled with the same style (no overlap holes).
struct Bubble<Content: View>: View {
    let fill: AnyShapeStyle
    let tailRight: Bool
    let width: CGFloat, height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: tailRight ? .bottomTrailing : .bottomLeading) {
            Tail(right: tailRight).fill(fill).frame(width: 90, height: 80).offset(x: tailRight ? 22 : -22, y: 6)
            RoundedRectangle(cornerRadius: 96, style: .continuous).fill(fill).frame(width: width, height: height)
            content.frame(width: width, height: height)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

/// The little curl at a bubble's bottom corner.
struct Tail: Shape {
    let right: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let (inner, outer): (CGFloat, CGFloat) = right ? (r.minX, r.maxX) : (r.maxX, r.minX)
        p.move(to: CGPoint(x: inner, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: outer, y: r.maxY), control: CGPoint(x: (inner + outer) / 2 + (right ? 10 : -10), y: r.maxY - 6))
        p.addQuadCurve(to: CGPoint(x: inner, y: r.maxY - 30), control: CGPoint(x: r.midX, y: r.maxY + 4))
        p.closeSubpath()
        return p
    }
}

@MainActor func render(_ out: String) {
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let r = ImageRenderer(content: Icon())
    r.scale = 1
    guard let base = r.cgImage else { print("render failed"); exit(1) }
    // iconset: 16…512 pt at 1x and 2x
    for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let px = size * scale
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: px, height: px))
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: out + "/" + name))
    }
    print("wrote \(out)")
}

MainActor.assumeIsolated { render(CommandLine.arguments[1]) }
