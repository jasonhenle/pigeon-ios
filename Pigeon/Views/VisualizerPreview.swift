import SwiftUI
import UIKit

/// The looping previews beside each visualizer's name.
///
/// Each style ships as a sprite sheet (`Resources/VizPreviews/viz_<style>.png`, built by
/// `pigeon/tools_build_viz_previews.py` from the device's own renderer) in which the theme
/// color is drawn as pure blue. `recolor` swaps that blue for the Pigeon's theme color, so
/// one sheet serves every color; greys, whites and the meters' red are left alone.
enum VisualizerPreviews {
    static let columns = 6
    static let rows = 5
    static let framesPerSecond = 15.0
    /// Width over height of one frame.
    static let aspect: CGFloat = 240.0 / 112.0

    @MainActor private static var cache: [String: [CGImage]] = [:]

    static func hasPreview(style: String) -> Bool { sheetURL(style) != nil }

    private static func sheetURL(_ style: String) -> URL? {
        Bundle.main.url(forResource: "viz_\(style)", withExtension: "png")
    }

    /// The frames of a style's loop in a theme color (`0xRRGGBB`); nil for a style with no sheet.
    @MainActor
    static func frames(style: String, color: UInt32) async -> [CGImage]? {
        let key = "\(style)|\(color)"
        if let hit = cache[key] { return hit }
        guard let url = sheetURL(style) else { return nil }
        let made = await Task.detached(priority: .userInitiated) { () -> [CGImage]? in
            guard let sheet = UIImage(contentsOfFile: url.path)?.cgImage,
                  let tinted = recolor(sheet, to: color) else { return nil }
            return split(tinted)
        }.value
        if let made {
            if cache.count > 12 { cache.removeAll() }  // a few colors' worth; frames are small
            cache[key] = made
        }
        return made
    }

    /// Replaces the sheet's marker blue with `color`. For each pixel `a = max(0, B - max(R, G))`
    /// is how much theme color it holds; the rest of the pixel is kept as drawn.
    static func recolor(_ image: CGImage, to color: UInt32) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let tr = Int((color >> 16) & 0xFF), tg = Int((color >> 8) & 0xFF), tb = Int(color & 0xFF)
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let a = b - max(r, g)
            guard a > 0 else { continue }
            px[i] = UInt8(min(255, r + a * tr / 255))
            px[i + 1] = UInt8(min(255, g + a * tg / 255))
            px[i + 2] = UInt8(min(255, (b - a) + a * tb / 255))
        }
        return ctx.makeImage()
    }

    static func split(_ sheet: CGImage) -> [CGImage] {
        let fw = sheet.width / columns, fh = sheet.height / rows
        var out: [CGImage] = []
        for r in 0..<rows {
            for c in 0..<columns {
                if let f = sheet.cropping(to: CGRect(x: c * fw, y: r * fh, width: fw, height: fh)) { out.append(f) }
            }
        }
        return out
    }
}

/// One visualizer, playing. Every preview on screen reads the same clock, so they move together.
struct VisualizerPreview: View {
    let style: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [CGImage] = []

    var body: some View {
        let accent = ThemeStore.shared.accentKey
        TimelineView(.animation(minimumInterval: 1.0 / VisualizerPreviews.framesPerSecond, paused: reduceMotion)) { ctx in
            ZStack {
                Color.black
                if !frames.isEmpty {
                    let tick = Int(ctx.date.timeIntervalSinceReferenceDate * VisualizerPreviews.framesPerSecond)
                    Image(decorative: frames[reduceMotion ? frames.count / 2 : tick % frames.count], scale: 1)
                        .resizable().interpolation(.medium).scaledToFit()
                }
            }
        }
        .aspectRatio(VisualizerPreviews.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: accent) {
            let color = ThemeStore.colors[accent] ?? ThemeStore.colors[ThemeStore.defaultKey]!
            frames = await VisualizerPreviews.frames(style: style, color: color) ?? []
        }
        .accessibilityHidden(true)
    }
}
