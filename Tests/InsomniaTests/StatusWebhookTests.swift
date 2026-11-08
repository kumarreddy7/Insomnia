import XCTest
@testable import Insomnia

@MainActor
final class StatusWebhookTests: XCTestCase {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(URL, Data)] = []
        func add(_ url: URL, _ body: Data) { lock.lock(); items.append((url, body)); lock.unlock() }
        var all: [(URL, Data)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private let snapshot = StatusWebhook.Snapshot(secondsLeft: 600, batteryPercent: 81, charging: true, thermal: "nominal", lidClosed: false)

    func testOnlyHTTPSURLsWithAHostAreEndpoints() {
        XCTAssertEqual(StatusWebhook.endpoint(" https://example.com/hook ")?.absoluteString, "https://example.com/hook")
        XCTAssertNil(StatusWebhook.endpoint(""))
        XCTAssertNil(StatusWebhook.endpoint("http://example.com/hook"))
        XCTAssertNil(StatusWebhook.endpoint("https://"))
        XCTAssertNil(StatusWebhook.endpoint("example.com"))
    }

    func testNothingIsConfiguredByDefaultAndTheKeyRoundTrips() throws {
        XCTAssertEqual(Config().statusWebhookURL, "")
        let decoded = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.statusWebhookURL, "")
        var c = Config()
        c.statusWebhookURL = "https://example.com/hook"
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(again.statusWebhookURL, "https://example.com/hook")
    }

    func testPostsTheSnapshotAndKeepsGoingUntilStopped() async throws {
        let sent = Sent()
        let hook = StatusWebhook(interval: .milliseconds(20)) { url, body in sent.add(url, body) }
        let url = try XCTUnwrap(URL(string: "https://example.com/hook"))
        hook.start { (url, self.snapshot) }
        try await Task.sleep(for: .milliseconds(200))
        hook.stop()
        try await Task.sleep(for: .milliseconds(50))  // a ping already under way may still land
        let count = sent.all.count
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertEqual(sent.all.first?.0, url)
        let body = try XCTUnwrap(sent.all.first?.1)
        XCTAssertEqual(try JSONDecoder().decode(StatusWebhook.Snapshot.self, from: body), snapshot)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent.all.count, count, "nothing is sent after stop")
    }

    func testSendsNothingWhileThereIsNothingToSend() async throws {
        let sent = Sent()
        let hook = StatusWebhook(interval: .milliseconds(20)) { url, body in sent.add(url, body) }
        hook.start { nil }
        try await Task.sleep(for: .milliseconds(100))
        hook.stop()
        XCTAssertEqual(sent.all.count, 0)
    }
}
