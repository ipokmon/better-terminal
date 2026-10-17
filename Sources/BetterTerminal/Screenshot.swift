import AppKit
import BTCore
import SwiftUI

/// Copies what is on screen to the clipboard as PNG + TIFF. It draws the app's own views,
/// so it needs no Screen Recording permission, and nothing is written to disk.
/// A terminal view's content, drawn by us into screenshots.
struct TerminalStandIn {
    let view: NSView
    let lines: [StyledLine]
    let background: NSColor
    let text: NSColor
}

@MainActor
enum Screenshot {
    static func copy(pane: PaneModel) {
        guard let anchor = pane.anchorView, let image = capture(anchor, panes: [pane]) else {
            pane.showToast("Screenshot failed")
            return
        }
        pane.showToast(write(image) ? "Screenshot copied" : "Screenshot failed")
    }

    static func copyWindow(_ model: WindowModel) {
        guard let content = model.window?.contentView, let image = capture(content, panes: model.panes) else { return }
        model.focused.showToast(write(image) ? "Window screenshot copied" : "Screenshot failed")
    }

    /// Renders `view` through its Core Animation layer tree. `cacheDisplay` alone misses SwiftTerm's
    /// layer-drawn text (it came back white), so this is the primary path.
    static func captureLayers(_ view: NSView) -> NSImage? {
        guard let window = view.window, let rootView = window.contentView?.superview ?? window.contentView,
              let rootLayer = rootView.layer else { return nil }
        rootView.layoutSubtreeIfNeeded()
        rootView.displayIfNeeded()
        let rect = view.convert(view.bounds, to: rootView).integral
        guard rect.width > 1, rect.height > 1 else { return nil }
        let scale = window.backingScaleFactor
        let w = Int(rect.width * scale), h = Int(rect.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Layer coordinates follow the root view; flip if the root view is flipped, then move to `rect`.
        if rootView.isFlipped {
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
        } else {
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
        }
        rootLayer.render(in: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: rect.size)
    }

    /// The window area of `view` as on screen, with the panes' terminal text painted in from their shadows.
    static func capture(_ view: NSView, panes: [PaneModel]) -> NSImage? {
        guard let base = capture(view) else { return nil }
        let standIns = panes.flatMap(\.standIns).filter { $0.view.window === view.window && !$0.view.isHiddenOrHasHiddenAncestor }
        guard !standIns.isEmpty else { return base }
        let out = NSImage(size: base.size)
        out.lockFocusFlipped(true) // top-left origin, like the stand-in layout below
        base.draw(in: NSRect(origin: .zero, size: base.size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for s in standIns {
            let frame = topLeftRect(s.view.bounds, of: s.view, in: view)
            let visible = topLeftRect(s.view.visibleRect, of: s.view, in: view)
            guard visible.width > 1, visible.height > 1, let img = render(s, size: frame.size) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visible).addClip()
            img.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        out.unlockFocus()
        return out
    }

    /// `rect` (in `child` coordinates) in `root`'s coordinates with a top-left origin.
    private static func topLeftRect(_ rect: NSRect, of child: NSView, in root: NSView) -> NSRect {
        var r = root.convert(rect, from: child)
        if !root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
        return r
    }

    private static func render(_ s: TerminalStandIn, size: NSSize) -> NSImage? {
        // One fixed-height row per terminal line, so tall screens (vim) keep their last row in view.
        let cell = Theme.cellHeight
        let fg = Color(nsColor: s.text)
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(s.lines.enumerated()), id: \.offset) { _, line in
                Text(Theme.attributed([line][...], defaultText: fg))
                    .lineLimit(1)
                    .frame(height: cell, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: s.background))
        let r = ImageRenderer(content: content)
        r.scale = 2
        return r.nsImage
    }

    /// Renders `view`'s area of the window, as it is on screen, at the screen's scale.
    static func capture(_ view: NSView) -> NSImage? {
        if let img = captureLayers(view) { return img }
        guard let root = view.window?.contentView?.superview ?? view.window?.contentView else { return nil }
        let rect = view.convert(view.bounds, to: root).integral
        guard rect.width > 1, rect.height > 1, let rep = root.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        root.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    @discardableResult
    static func write(_ image: NSImage, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
