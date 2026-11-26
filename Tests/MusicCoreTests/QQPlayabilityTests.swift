import Foundation
import XCTest
@testable import MusicCore

final class QQPlayabilityTests: XCTestCase {
    private func track(_ fields: [String: JSONValue]) -> SourceTrack {
        LocalQQMapping.track(.object(fields.merging([
            "mid": .string("song"), "title": .string("Song"), "interval": .integer(120),
            "album": .object(["name": .string("Album")]),
        ]) { original, _ in original }))
    }

    func testRightsFlagsAndUnknownMetadata() {
        XCTAssertTrue(track([:]).isPlayable)
        XCTAssertTrue(track(["action": .object(["switch": .string("invalid")])]).isPlayable)
        for permission: Int64 in [2, 4, 8, 403] {
            XCTAssertTrue(track(["action": .object(["switch": .integer(permission)])]).isPlayable)
        }
        XCTAssertFalse(track(["action": .object(["switch": .integer(0)])]).isPlayable)
        XCTAssertFalse(track(["switch": .string("256")]).isPlayable)
        XCTAssertFalse(track(["disabled": .bool(true)]).isPlayable)
    }

    func testPaidTracksAndPreviewOnlyTracksHaveDifferentPermissions() {
        let blocked: JSONValue = .object(["switch": .integer(0)])
        XCTAssertTrue(track(["action": blocked, "pay": .object(["pay_play": .integer(1)])]).isPlayable)
        XCTAssertFalse(track(["action": blocked, "file": .object(["size_try": .integer(100)])]).isPlayable)
        XCTAssertFalse(track(["disabled": .integer(1), "pay": .object(["pay_play": .integer(1)])]).isPlayable)
    }

    func testMianHuiCaiRetainedPreviewDoesNotEnableFullPlayback() {
        // Public getSongInfo result for 000vMVMQ2W9Pm4: no full-stream bits,
        // despite an old trial file still being present in QQ metadata.
        let result = track([
            "mid": .string("000vMVMQ2W9Pm4"), "title": .string("面会菜"),
            "action": .object(["switch": .integer(65537), "msgid": .integer(1)]),
            "pay": .object(["pay_month": .integer(1), "pay_play": .integer(0)]),
            "file": .object(["size_try": .integer(960887), "try_begin": .integer(0), "try_end": .integer(0)]),
        ])
        XCTAssertFalse(result.isPlayable)
    }

    func testCacheRoundTripAndBackwardCompatibility() throws {
        let old = Data(#"{"id":"song","title":"Song","album":"Album","durationMs":120000}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(SourceTrack.self, from: old).isPlayable)
        let unavailable = track(["disabled": .integer(1)])
        XCTAssertEqual(try JSONDecoder().decode(SourceTrack.self, from: JSONEncoder().encode(unavailable)), unavailable)
    }
}
