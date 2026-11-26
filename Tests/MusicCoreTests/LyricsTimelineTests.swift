import XCTest

@testable import MusicCore

final class LyricsTimelineTests: XCTestCase {
    func testWordTimingProgressAndTranslationRemainIndependent() throws {
        let json =
            #"{"track_id":"sample","text":"[00:01]你好","content_type":"application/x-lrc","translation":"[00:01]Hello","lines":[{"text":"你好","start_ms":1000,"duration_ms":1000,"words":[{"text":"你","start_ms":1000,"duration_ms":300},{"text":"好","start_ms":1300,"duration_ms":700}]}]}"#
        let result = try MusicJSON.decoder().decode(SourceLyrics.self, from: Data(json.utf8))
        let timeline = LyricsTimeline(lrc: result.text, translation: result.translation, lines: result.lines)
        let cue = try XCTUnwrap(timeline.cues.first)
        XCTAssertEqual(cue.translation, "Hello")
        XCTAssertEqual(cue.words.map(\.text), ["你", "好"])
        XCTAssertEqual(cue.words[1].time, 1.3)
        XCTAssertEqual(cue.words[0].progress(at: 0.9), 0)
        XCTAssertEqual(cue.words[0].progress(at: 1.15), 0.5, accuracy: 0.0001)
        XCTAssertEqual(cue.words[0].progress(at: 1.4), 1)
        XCTAssertEqual(cue.words[1].progress(at: 1.65), 0.5, accuracy: 0.0001)
        XCTAssertEqual(cue.words[1].progress(at: .nan), 0)
    }

    func testMalformedOptionalWordDataDoesNotHideLineLyrics() throws {
        let result = try MusicJSON.decoder().decode(
            SourceLyrics.self,
            from: Data(
                #"{"track_id":"x","text":"[00:01]Hello","content_type":"application/x-lrc","lines":[{"words":"invalid"}]}"#
                    .utf8))
        XCTAssertNil(result.lines)
        XCTAssertEqual(LyricsTimeline(lrc: result.text, lines: result.lines).cues[0].text, "Hello")
    }

    func testInvalidTimingFallsBackPerLineAndDoesNotInventWordAlignment() {
        let valid = SourceLyricLine(
            text: "A B", startMS: 1000, durationMS: 1000,
            words: [
                .init(text: "A", startMS: 1000, durationMS: 400), .init(text: " B", startMS: 1400, durationMS: 600),
            ])
        let invalid = SourceLyricLine(
            text: "Other", startMS: 3000, durationMS: 1000,
            words: [
                .init(text: "Different", startMS: 3000, durationMS: 1000)
            ])
        let timeline = LyricsTimeline(lrc: "[00:01.01]A B\n[00:03]Other\n[00:05]Fallback", lines: [valid, invalid])
        XCTAssertEqual(timeline.cues[0].words.count, 2)
        XCTAssertTrue(timeline.cues[1].words.isEmpty)
        XCTAssertTrue(timeline.cues[2].words.isEmpty)
        XCTAssertEqual(timeline.cues.map(\.time), [1.01, 3, 5])
    }

    func testZeroDurationAndOverlappingWordTimings() {
        let line = SourceLyricLine(
            text: "AB", startMS: 1000, durationMS: 500,
            words: [
                .init(text: "A", startMS: 1000, durationMS: 0), .init(text: "B", startMS: 1000, durationMS: 500),
            ])
        let timeline = LyricsTimeline(lrc: "[00:01]AB", lines: [line])
        XCTAssertEqual(timeline.cues[0].words[0].progress(at: 1), 1)
        var invalid = line
        invalid.words[1].durationMS = .max
        XCTAssertTrue(LyricsTimeline(lrc: "[00:01]AB", lines: [invalid]).cues[0].words.isEmpty)
        invalid = line
        invalid.words[1].startMS = -1
        XCTAssertTrue(LyricsTimeline(lrc: "[00:01]AB", lines: [invalid]).cues[0].words.isEmpty)
    }

    func testPreciseFractionsOrderingAndSeekBoundaries() {
        let lyrics = LyricsTimeline(lrc: "[00:12.123]Third\r\n[00:01.1]First\n[00:02.12]Second")
        XCTAssertEqual(lyrics.cues.map(\.time), [1.1, 2.12, 12.123])
        XCTAssertNil(lyrics.activeCue(at: 1.099))
        XCTAssertEqual(lyrics.activeCue(at: 1.1)?.text, "First")
        XCTAssertEqual(lyrics.activeCue(at: 12.123)?.text, "Third")
        XCTAssertEqual(lyrics.activeCue(at: 2.12)?.text, "Second")
        XCTAssertNil(lyrics.activeCue(at: -.infinity))
        XCTAssertNil(lyrics.activeCue(at: .nan))
        XCTAssertNil(lyrics.activeCue(at: -1))
    }

    func testMultipleTimestampsTranslationsAndDuplicatesShareOneCue() {
        let lyrics = LyricsTimeline(lrc: "[00:02][00:10.000]Repeat\n[00:02.00]Translation\n[00:02.000]Repeat")
        XCTAssertEqual(lyrics.cues.count, 2)
        XCTAssertEqual(lyrics.cues[0].text, "Repeat\nTranslation")
        XCTAssertEqual(lyrics.activeCue(at: 10)?.text, "Repeat")
        XCTAssertEqual(Set(lyrics.cues.map(\.id)).count, 2)
    }

    func testGlobalOffsetsAndMetadata() {
        let advanced = LyricsTimeline(lrc: "[ti:Title]\n[ar:Singer]\n[00:02.00]Line\n[offset:+500]")
        XCTAssertEqual(advanced.cues.first?.time, 1.5)
        XCTAssertEqual(advanced.plainText, "Line")
        XCTAssertEqual(advanced.activeCue(at: 1.5)?.text, "Line")
        let delayed = LyricsTimeline(lrc: "[offset:-1250]\n[00:02]Line")
        XCTAssertEqual(delayed.cues.first?.time, 3.25)
        XCTAssertNil(delayed.activeCue(at: 3))
        let beforeZero = LyricsTimeline(lrc: "[offset:3000]\n[00:02]Line")
        XCTAssertEqual(beforeZero.activeCue(at: 0)?.text, "Line")
    }

    func testEmptyCuesClearHighlightAndWordTagsAreRemoved() {
        let lyrics = LyricsTimeline(lrc: "[00:01]<00:01.1>Hello <00:01.8>world\n[00:03]\n[00:06]Again")
        XCTAssertEqual(lyrics.activeCue(at: 2)?.text, "Hello world")
        XCTAssertEqual(lyrics.activeCue(at: 4)?.text, "")
        XCTAssertEqual(lyrics.activeCue(at: 6)?.text, "Again")
    }

    func testSungCueIndexHoldsAcrossBlankMarkersAndRepeatedText() {
        let lyrics = LyricsTimeline(lrc: "[00:01]Same\n[00:03]\n[00:04]\n[00:07]Same\n[00:09]\n[00:10]Last")
        XCTAssertEqual(lyrics.sungCues.map(\.id), [0, 3, 5])
        XCTAssertNil(lyrics.activeSungCueIndex(at: 0.99))
        XCTAssertEqual(lyrics.activeSungCueIndex(at: 1), 0)
        XCTAssertEqual(lyrics.activeSungCueIndex(at: 6.999), 0)
        XCTAssertEqual(lyrics.activeSungCueIndex(at: 7), 1)
        XCTAssertEqual(lyrics.activeSungCueIndex(at: 9.5), 1)
        XCTAssertEqual(lyrics.activeSungCueIndex(at: 100), 2)
        XCTAssertEqual(lyrics.activeSungCueIndex(at: 3.5), 0)
    }

    func testUntimedAndUnavailableLyricsDoNotInventTiming() {
        let plain = LyricsTimeline(lrc: "[ti:Title]\nFirst line\n\nSecond line")
        XCTAssertFalse(plain.isTimed)
        XCTAssertEqual(plain.plainText, "First line\nSecond line")
        XCTAssertNil(plain.activeCue(at: 30))
        XCTAssertTrue(LyricsTimeline(lrc: "").cues.isEmpty)
        XCTAssertEqual(LyricsTimeline(lrc: "[ar:Singer]").plainText, "")
    }

    func testIndependentTranslationTimelineAlignsRoundedTimestampsAndOffsets() {
        let lyrics = LyricsTimeline(
            lrc: "[offset:100]\n[00:01.20]Hello\n[00:03.00]Goodbye",
            translation: "[offset:200]\n[00:01.31]你好\n[00:03.10]再见")
        XCTAssertEqual(lyrics.cues.count, 2)
        XCTAssertEqual(lyrics.cues[0].text, "Hello")
        XCTAssertEqual(lyrics.cues[0].translation, "你好")
        XCTAssertEqual(lyrics.cues[1].translation, "再见")
        XCTAssertEqual(lyrics.activeCue(at: 1.1)?.translation, "你好")
    }

    func testTranslationDoesNotCreateSeekPointsFillGapsOrDuplicateOriginal() {
        let lyrics = LyricsTimeline(
            lrc: "[00:01]Hello\n[00:03]\n[00:05]Goodbye",
            translation: "[00:01]Hello\n[00:01]你好\n[00:01]你好\n[00:03]间奏\n[00:04]无对应原文\n[00:05]//")
        XCTAssertEqual(lyrics.cues.map(\.time), [1, 3, 5])
        XCTAssertEqual(lyrics.cues[0].translation, "你好")
        XCTAssertNil(lyrics.cues[1].translation)
        XCTAssertNil(lyrics.cues[2].translation)
        XCTAssertEqual(lyrics.activeCue(at: 3)?.text, "")
    }

    func testUntimedTranslationsAndMissingTranslationRemainOptional() {
        let lyrics = LyricsTimeline(lrc: "Hello", translation: "你好")
        XCTAssertEqual(lyrics.plainTranslation, "你好")
        XCTAssertFalse(lyrics.isTimed)
        XCTAssertNil(LyricsTimeline(lrc: "Hello").plainTranslation)
        XCTAssertNil(LyricsTimeline(lrc: "Hello", translation: "Hello").plainTranslation)
        XCTAssertNil(LyricsTimeline(lrc: "[00:01]Hello", translation: "你好").cues[0].translation)
    }

    func testSourceLyricsDecodesOlderResponsesAndOptionalTranslation() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let older = try decoder.decode(
            SourceLyrics.self, from: Data(#"{"track_id":"song","text":"Hello","content_type":"text/plain"}"#.utf8))
        XCTAssertNil(older.translation)
        let translated = try decoder.decode(
            SourceLyrics.self,
            from: Data(#"{"track_id":"song","text":"Hello","content_type":"text/plain","translation":"你好"}"#.utf8))
        XCTAssertEqual(translated.translation, "你好")
    }
}
