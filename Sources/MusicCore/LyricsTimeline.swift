import Foundation

public struct LyricWordTiming: Sendable, Equatable {
    public let text: String
    public let time: TimeInterval
    public let duration: TimeInterval

    public func progress(at position: TimeInterval) -> Double {
        guard position.isFinite, position >= time else { return 0 }
        guard duration > 0 else { return 1 }
        return min((position - time) / duration, 1)
    }
}

public struct LyricCue: Sendable, Equatable, Identifiable {
    public let id: Int
    public let time: TimeInterval
    public let text: String
    public let translation: String?
    public let words: [LyricWordTiming]

    public init(id: Int, time: TimeInterval, text: String, translation: String?, words: [LyricWordTiming] = []) {
        self.id = id
        self.time = time
        self.text = text
        self.translation = translation
        self.words = words
    }
}

/// Parses line-timed LRC once; playback lookups use an upper-bound search.
public struct LyricsTimeline: Sendable, Equatable {
    public let cues: [LyricCue]
    public let sungCues: [LyricCue]
    public let plainText: String
    public let plainTranslation: String?
    public var isTimed: Bool { !cues.isEmpty }

    public init(lrc: String, translation: String? = nil, lines wordLines: [SourceLyricLine]? = nil) {
        let timestamp = try! NSRegularExpression(pattern: #"^\[(\d{1,4}):([0-5]?\d)(?:[.:](\d{1,3}))?\]"#)
        let offsetTag = try! NSRegularExpression(pattern: #"^\[offset:\s*([+-]?\d+)\s*\]$"#, options: .caseInsensitive)
        let metadata = try! NSRegularExpression(pattern: #"^\[[A-Za-z][A-Za-z0-9_-]*:.*\]$"#)
        let wordTag = try! NSRegularExpression(pattern: #"<\d{1,4}:[0-5]?\d(?:[.:]\d{1,3})?>"#)
        var offset = 0.0
        var groups: [Int: [String]] = [:]
        var plain: [String] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
                of: "\u{FEFF}", with: "")
            let full = NSRange(line.startIndex..., in: line)
            if let match = offsetTag.firstMatch(in: line, range: full), let range = Range(match.range(at: 1), in: line),
                let value = Double(line[range]), value.isFinite
            {
                // LRC positive offsets advance the lyrics, so effective timestamps subtract the offset.
                offset = value / 1000
                continue
            }
            if metadata.firstMatch(in: line, range: full) != nil { continue }
            var times: [Int] = []
            while let match = timestamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                let minuteRange = Range(match.range(at: 1), in: line),
                let secondRange = Range(match.range(at: 2), in: line),
                let minutes = Int(line[minuteRange]), let seconds = Int(line[secondRange]),
                let matchedRange = Range(match.range, in: line)
            {
                var milliseconds = 0
                if let fractionRange = Range(match.range(at: 3), in: line) {
                    let digits = String(line[fractionRange])
                    milliseconds = (Int(digits) ?? 0) * (digits.count == 1 ? 100 : digits.count == 2 ? 10 : 1)
                }
                times.append(minutes * 60_000 + seconds * 1000 + milliseconds)
                line = String(line[matchedRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            line = wordTag.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { plain.append(line) }
            for time in times {
                if groups[time] == nil { groups[time] = [] }
                if !line.isEmpty, groups[time]?.contains(line) == false { groups[time]?.append(line) }
            }
        }
        var parsedCues = groups.keys.sorted().enumerated().map { index, milliseconds in
            LyricCue(
                id: index, time: Double(milliseconds) / 1000 - offset,
                text: (groups[milliseconds] ?? []).joined(separator: "\n"), translation: nil)
        }
        plainText = plain.joined(separator: "\n")
        let translated = translation.map { LyricsTimeline(lrc: $0) }
        if let translated, !parsedCues.isEmpty {
            var lines: [Int: [String]] = [:]
            for cue in translated.cues where !cue.text.isEmpty && cue.text != "//" {
                // A small tolerance accommodates independently rounded QQ timestamps.
                // Never create seek points from unmatched translation or instrumental gaps.
                var lower = 0
                var upper = parsedCues.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if parsedCues[middle].time < cue.time { lower = middle + 1 } else { upper = middle }
                }
                let candidates = [lower - 1, lower].filter { parsedCues.indices.contains($0) }
                guard
                    let index = candidates.min(by: {
                        abs(parsedCues[$0].time - cue.time) < abs(parsedCues[$1].time - cue.time)
                    }), abs(parsedCues[index].time - cue.time) <= 0.15, !parsedCues[index].text.isEmpty
                else { continue }
                for line in cue.text.components(separatedBy: "\n")
                where !parsedCues[index].text.components(separatedBy: "\n").contains(line)
                    && !(lines[index] ?? []).contains(line) && line != "//"
                {
                    lines[index, default: []].append(line)
                }
            }
            parsedCues = parsedCues.enumerated().map { index, cue in
                LyricCue(id: cue.id, time: cue.time, text: cue.text, translation: lines[index]?.joined(separator: "\n"))
            }
        }
        if let wordLines, wordLines.count <= 10_000 {
            var timings: [Int: [LyricWordTiming]] = [:]
            for line in wordLines {
                guard Self.valid(line) else { continue }
                let time = Double(line.startMS) / 1000
                var lower = 0
                var upper = parsedCues.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if parsedCues[middle].time < time { lower = middle + 1 } else { upper = middle }
                }
                let candidates = [lower - 1, lower].filter {
                    parsedCues.indices.contains($0) && abs(parsedCues[$0].time - time) <= 0.15
                        && Self.compactText(parsedCues[$0].text) == Self.compactText(line.text)
                }
                guard
                    let index = candidates.min(by: { abs(parsedCues[$0].time - time) < abs(parsedCues[$1].time - time) }
                    ), timings[index] == nil
                else { continue }
                timings[index] = line.words.map {
                    LyricWordTiming(
                        text: $0.text, time: Double($0.startMS) / 1000, duration: Double($0.durationMS) / 1000)
                }
            }
            parsedCues = parsedCues.enumerated().map { index, cue in
                LyricCue(
                    id: cue.id, time: cue.time, text: cue.text, translation: cue.translation,
                    words: timings[index] ?? [])
            }
        }
        cues = parsedCues
        sungCues = parsedCues.filter { !$0.text.isEmpty }
        if parsedCues.isEmpty, let text = translated?.plainText, !text.isEmpty, text != "//", text != plainText {
            plainTranslation = text
        } else {
            plainTranslation = nil
        }
    }

    private static func compactText(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }

    private static func valid(_ line: SourceLyricLine) -> Bool {
        let maximum: Int64 = 48 * 60 * 60 * 1000
        guard line.startMS >= 0, line.durationMS >= 0, line.startMS <= maximum,
            line.durationMS <= maximum - line.startMS, !line.words.isEmpty, line.words.count <= 10_000,
            !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            line.words.map(\.text).joined() == line.text
        else { return false }
        var previous = line.startMS
        for word in line.words {
            guard word.startMS >= previous, word.startMS >= line.startMS, word.startMS <= maximum,
                word.durationMS >= 0, word.durationMS <= maximum - word.startMS,
                word.startMS + word.durationMS <= line.startMS + line.durationMS
            else { return false }
            previous = word.startMS
        }
        return true
    }

    /// Includes explicit empty timing markers for consumers that need them.
    public func activeCue(at position: TimeInterval) -> LyricCue? {
        Self.cueIndex(at: position, in: cues).map { cues[$0] }
    }

    /// Holds the last displayed line through instrumental gaps until the next line begins.
    public func activeSungCueIndex(at position: TimeInterval) -> Int? {
        Self.cueIndex(at: position, in: sungCues)
    }

    private static func cueIndex(at position: TimeInterval, in cues: [LyricCue]) -> Int? {
        guard position.isFinite, position >= 0 else { return nil }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].time <= position { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 ? lower - 1 : nil
    }
}
