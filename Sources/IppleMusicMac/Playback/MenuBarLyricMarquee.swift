import AppKit
import CoreText

struct MenuBarLyricWord: Equatable {
    var range: NSRange
    var time: Double
    var duration: Double
}

struct MenuBarLyricPresentation: Equatable {
    var cueID: Int
    var time: Double
    var endTime: Double?
    var text: String
    var words: [MenuBarLyricWord]
}

/// A finite media-time curve; Core Animation interpolates between word boundaries without frame callbacks.
struct MenuBarLyricScrollPlan: Equatable {
    struct Point: Equatable {
        var time: Double
        var offset: CGFloat
    }
    var cueTime: Double
    var duration: Double
    var points: [Point]
    var fillPoints: [Point]

    @MainActor init(lyric: MenuBarLyricPresentation, marquee: MenuBarLyricMarquee) {
        cueTime = lyric.time
        let wordEnd = lyric.words.map { $0.time + $0.duration }.max()
        let end =
            wordEnd.map { min($0, lyric.endTime ?? $0) }
            ?? lyric.endTime ?? (lyric.time + max(2, Double(lyric.text.count) * 0.25))
        duration = max(0.001, end - lyric.time)
        points = [Point(time: 0, offset: 0)]
        fillPoints = points
        let width = CGFloat(marquee.image.width) / marquee.scale
        func append(_ time: Double, scroll: CGFloat, fill: CGFloat) {
            let time = min(max(time, 0), duration)
            let scrollPoint = Point(time: time, offset: scroll)
            let fillPoint = Point(time: time, offset: fill)
            if time == points.last?.time {
                points[points.count - 1] = scrollPoint
                fillPoints[fillPoints.count - 1] = fillPoint
            } else if time > (points.last?.time ?? -1) {
                points.append(scrollPoint)
                fillPoints.append(fillPoint)
            }
        }
        if lyric.words.isEmpty {
            append(duration, scroll: marquee.maxOffset, fill: width)
        } else {
            for (index, word) in lyric.words.enumerated() {
                let nextStart = lyric.words.indices.contains(index + 1) ? lyric.words[index + 1].time : end
                let start = marquee.glyphOffset(atUTF16: word.range.location)
                let finish = marquee.glyphOffset(atUTF16: NSMaxRange(word.range))
                append(
                    word.time - lyric.time,
                    scroll: min(max(0, start - marquee.viewportWidth * 0.35), marquee.maxOffset), fill: start)
                append(
                    min(word.time + word.duration, nextStart) - lyric.time,
                    scroll: min(max(0, finish - marquee.viewportWidth * 0.35), marquee.maxOffset), fill: finish)
            }
            append(duration, scroll: points.last?.offset ?? 0, fill: width)
        }
    }

    func offset(at position: Double) -> CGFloat {
        let time = min(max(position - cueTime, 0), duration)
        guard let last = points.last, time < last.time else { return points.last?.offset ?? 0 }
        for index in 1..<points.count where time <= points[index].time {
            let a = points[index - 1]
            let b = points[index]
            let fraction = (time - a.time) / max(0.001, b.time - a.time)
            return a.offset + (b.offset - a.offset) * fraction
        }
        return 0
    }
}

/// One immutable glyph mask for both static and scrolling lyrics.
/// A shared font and baseline avoid switching to AppKit cell typography for short lines.
@MainActor
final class MenuBarLyricMarquee {
    static let font = NSFont.menuBarFont(ofSize: 12)
    let text: String
    let viewportWidth: CGFloat
    let scale: CGFloat
    let truncatesToViewport: Bool
    let image: CGImage
    let maxOffset: CGFloat
    private let line: CTLine
    private let height: CGFloat = 18

    init?(text: String, viewportWidth: CGFloat, scale: CGFloat, truncatesToViewport: Bool = false) {
        guard !text.isEmpty, viewportWidth.isFinite, viewportWidth > 2, scale.isFinite, scale > 0 else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.black]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        // Bound the texture even for malformed lyrics, using the same font for the ellipsis.
        let maximumWidth = truncatesToViewport ? min(viewportWidth, 65_536 / scale) : 65_536 / scale
        if CTLineGetTypographicBounds(line, nil, nil, nil) + 2 > maximumWidth {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            // Core Text can exceed its requested truncation advance by a fractional
            // glyph width. Leave a small margin and clamp the texture allocation.
            guard let truncated = CTLineCreateTruncatedLine(line, maximumWidth - 4, .end, ellipsis) else { return nil }
            line = truncated
        }
        let width = min(ceil(CTLineGetTypographicBounds(line, nil, nil, nil) + 2), floor(maximumWidth))
        let pixelsWide = Int(ceil(width * scale))
        let pixelsHigh = Int(height * scale)
        guard pixelsWide > 0, pixelsWide <= 65_536, pixelsHigh > 0,
            let context = CGContext(
                data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        let naturalBaseline = (height - Self.font.ascender + Self.font.descender) / 2 - Self.font.descender
        let baseline = (naturalBaseline * scale).rounded() / scale
        context.textPosition = CGPoint(x: 1, y: baseline)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        self.text = text
        self.viewportWidth = viewportWidth
        self.scale = scale
        self.truncatesToViewport = truncatesToViewport
        self.image = image
        self.line = line
        maxOffset = max(0, CGFloat(pixelsWide) / scale - viewportWidth)
    }

    func glyphOffset(atUTF16 index: Int) -> CGFloat {
        let value = CTLineGetOffsetForStringIndex(line, min(max(index, 0), (text as NSString).length), nil)
        return min(max(0, value + 1), CGFloat(image.width) / scale)
    }
}
