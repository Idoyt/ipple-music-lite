import XCTest

@testable import MusicCore

final class QQSessionTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, domain: String = ".y.qq.com", expires: Date? = nil)
        -> HTTPCookie
    {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testCapturesOnlyMusicCookiesFromOfficialDomains() {
        let expiry = Date().addingTimeInterval(3600)
        let candidate = QQSessionCandidate.capture(from: [
            cookie("uin", "12345"), cookie("qqmusic_key", "music-token", expires: expiry),
            cookie("p_skey", "qq-wide-secret", domain: ".qq.com"), cookie("skey", "general-secret"),
            cookie("qm_keyst", "wrong-domain", domain: "attacker.example"), cookie("ipple_session", "app-secret"),
        ])
        XCTAssertEqual(candidate?.cookie, "qqmusic_key=music-token; uin=12345")
        XCTAssertEqual(candidate?.expiresAt?.timeIntervalSince1970 ?? 0, expiry.timeIntervalSince1970, accuracy: 1)
    }
    func testMissingMusicTokenExpiredCookiesAndFakeDomainsAreRejected() {
        XCTAssertNil(QQSessionCandidate.capture(from: [cookie("uin", "12345")]))
        XCTAssertNil(
            QQSessionCandidate.capture(from: [
                cookie("uin", "12345"), cookie("qqmusic_key", "expired", expires: Date().addingTimeInterval(-60)),
            ]))
        XCTAssertNil(
            QQSessionCandidate.capture(from: [
                cookie("uin", "12345", domain: "qq.com.attacker.example"), cookie("qm_keyst", "token"),
            ]))
        XCTAssertNil(QQSessionCandidate.capture(from: [cookie("uin", "0"), cookie("qm_keyst", "token")]))
    }
    func testEachCaptureIsIndependentAndPrefersMusicDomain() {
        let alice = QQSessionCandidate.capture(from: [cookie("uin", "12345"), cookie("qm_keyst", "alice")])
        let bob = QQSessionCandidate.capture(from: [
            cookie("uin", "67890"), cookie("qm_keyst", "stale", domain: ".qq.com"), cookie("qm_keyst", "bob"),
        ])
        XCTAssertTrue(alice?.cookie.contains("alice") == true)
        XCTAssertTrue(bob?.cookie.contains("bob") == true)
        XCTAssertFalse(bob?.cookie.contains("alice") == true)
        XCTAssertFalse(bob?.cookie.contains("stale") == true)
    }
    func testSessionStatusDecodesWithoutExposingCredentials() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(
            QQSessionStatus.self,
            from: Data(#"{"state":"expired","login_available":true,"account_id":"****2345"}"#.utf8))
        XCTAssertEqual(status.state, "expired")
        XCTAssertEqual(status.accountID, "****2345")
        XCTAssertTrue(status.loginAvailable)
    }
    func testAuthorizationCallbackRequiresExactOfficialEndpoint() throws {
        let valid = "https://y.qq.com/portal/wx_redirect.html?login_type=1&state=fixture-state&code=official-authorization-code"
        let candidate = try XCTUnwrap(QQSessionCandidate.authorizationCallback(from: URL(string: valid)!, expectedState: "fixture-state"))
        XCTAssertEqual(candidate.authorizationCode, "official-authorization-code")
        XCTAssertEqual(candidate.cookie, "")
        let fragment = valid.replacingOccurrences(of: "&code=", with: "#code=")
        XCTAssertEqual(QQSessionCandidate.authorizationCallback(from: URL(string: fragment)!, expectedState: "fixture-state")?.authorizationCode, candidate.authorizationCode)
        for invalid in [valid.replacingOccurrences(of: "&state=fixture-state", with: ""),
                        valid.replacingOccurrences(of: "fixture-state", with: "old-state"),
                        valid + "#state=fixture-state"] {
            XCTAssertNil(QQSessionCandidate.authorizationCallback(from: URL(string: invalid)!, expectedState: "fixture-state"))
        }
        for value in [valid.replacingOccurrences(of: "y.qq.com", with: "evil.example"), valid.replacingOccurrences(of: "https:", with: "http:"), valid.replacingOccurrences(of: "login_type=1", with: "login_type=2"), valid + "&code=second-code-should-fail", valid.replacingOccurrences(of: "wx_redirect.html", with: "profile.html")] {
            XCTAssertNil(QQSessionCandidate.authorizationCallback(from: URL(string: value)!, expectedState: "fixture-state"))
        }
    }

}
