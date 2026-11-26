import Foundation
import XCTest
@testable import MusicCore

final class QQCommentContentTests: XCTestCase {
    func testQQEmojiStayInlineWithUnicodeAndNewlines() {
        let parts = QQCommentContent.parse("好听🎵[em]e400824[/em]\n继续[em]e400833[/em]")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], .text("好听🎵"))
        guard case .emoji(let code, let url) = parts[1] else { return XCTFail("Missing QQ emoji") }
        XCTAssertEqual(code, "e400824")
        XCTAssertEqual(url.absoluteString, "https://y.gtimg.cn/mediastyle/global/emoji/img/e400824.png")
        XCTAssertEqual(parts[2], .text("\n继续"))
    }

    func testPicturesAndUnrecognizedMarkup() {
        let parts = QQCommentContent.parse("图[img]http://y.gtimg.cn/a.jpg[/img][em]unknown[/em]")
        XCTAssertEqual(parts, [.text("图"), .image(URL(string: "https://y.gtimg.cn/a.jpg")!), .text("[em]unknown[/em]")])
        let unsafe = "[img]file:///tmp/a.jpg[/img]"
        XCTAssertEqual(QQCommentContent.parse(unsafe), [.text(unsafe)])
        XCTAssertNil(QQCommentContent.mediaURL("https://qpic.cn.evil.example/a.jpg"))
        XCTAssertNil(QQCommentContent.mediaURL("https://user:password@y.gtimg.cn/a.jpg"))
        XCTAssertEqual(QQCommentContent.mediaURL("//p.qpic.cn/a.jpg")?.scheme, "https")
    }

    func testImageOnlyCommentsAndOldCommentCompatibility() throws {
        let row: JSONValue = .object(["pics": .array([
            .object(["url": .string("https://p.qpic.cn/a.jpg")]), .string("https://p.qpic.cn/a.jpg"),
            .string("https://example.com/not-comment-media"),
        ])])
        XCTAssertEqual(QQCommentContent.images(in: row).count, 1)
        let old = Data(#"{"id":"1","author":"user","text":"comment","likeCount":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(QQSongComment.self, from: old).images)
    }
}
