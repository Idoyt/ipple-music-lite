import XCTest

@testable import MusicCore

private actor CoverRequests {
    var count = 0
    func load(_ data: Data) async throws -> Data {
        count += 1
        try await Task.sleep(for: .milliseconds(10))
        return data
    }
}

private actor HeldCover {
    var started = false
    var continuation: CheckedContinuation<Data, Never>?
    func load() async -> Data {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

@MainActor
final class CoverDiskCacheTests: XCTestCase {
    private var image: Data {
        var png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")!
        // Padding makes eviction exercise real allocated file sizes without creating huge fixtures.
        png.append(Data(repeating: 0, count: 40_000))
        return png
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipple-cover-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCoalescesLoadsPersistsBytesAndSeparatesNamespaces() async throws {
        let directory = try directory()
        let cache = CoverDiskCache(directory: directory)
        let requests = CoverRequests()
        let image = image
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await cache.data(namespace: ["server", "alice", "cover"]) {
                        try await requests.load(image)
                    }
                }
            }
            for try await result in group { XCTAssertEqual(result, image) }
        }
        var count = await requests.count
        XCTAssertEqual(count, 1)
        let reopened = CoverDiskCache(directory: directory)
        _ = try await reopened.data(namespace: ["server", "alice", "cover"]) { try await requests.load(image) }
        count = await requests.count
        XCTAssertEqual(count, 1, "reopening downloaded a persisted cover")
        _ = try await reopened.data(namespace: ["server", "bob", "cover"]) { try await requests.load(image) }
        _ = try await reopened.data(namespace: ["other-server", "alice", "cover"]) { try await requests.load(image) }
        count = await requests.count
        XCTAssertEqual(count, 3, "cache crossed account or server namespaces")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.contains("alice") || $0.contains("server") })
    }

    func testLRUEvictionCapacityPersistenceAndDisable() async throws {
        let directory = try directory()
        let cache = CoverDiskCache(directory: directory)
        try await cache.setLimit(bytes: 110_000)
        let requests = CoverRequests()
        let image = image
        for key in ["a", "b", "a", "c", "a"] {
            _ = try await cache.data(namespace: [key]) { try await requests.load(image) }
        }
        var count = await requests.count
        XCTAssertEqual(count, 3, "recently used entry was evicted")
        var statistics = try await cache.statistics()
        XCTAssertLessThanOrEqual(statistics.usedBytes, 110_000)
        XCTAssertEqual(statistics.count, 2)
        _ = try await cache.data(namespace: ["b"]) { try await requests.load(image) }
        count = await requests.count
        XCTAssertEqual(count, 4, "least recently used entry was not evicted")
        try await cache.setLimit(bytes: 0)
        statistics = try await cache.statistics()
        XCTAssertEqual(statistics.usedBytes, 0)
        for _ in 0..<2 {
            _ = try await cache.data(namespace: ["disabled"]) { try await requests.load(image) }
        }
        count = await requests.count
        XCTAssertEqual(count, 6)
        let reopened = CoverDiskCache(directory: directory)
        statistics = try await reopened.statistics()
        XCTAssertEqual(statistics.limitBytes, 0)
        XCTAssertEqual(statistics.count, 0)
        do {
            try await cache.setLimit(bytes: CoverDiskCache.maximumBytes + 1)
            XCTFail("accepted capacity above the supported limit")
        } catch {}
    }

    func testClearAndResizePreventInflightRefill() async throws {
        for resize in [false, true] {
            let cache = CoverDiskCache(directory: try directory())
            let held = HeldCover()
            let task = Task { try await cache.data(namespace: ["late"]) { await held.load() } }
            for _ in 0..<100 {
                if await held.started { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            let started = await held.started
            XCTAssertTrue(started)
            if resize { try await cache.setLimit(bytes: 0) } else { try await cache.clear() }
            await held.release(image)
            _ = try await task.value
            let statistics = try await cache.statistics()
            XCTAssertEqual(statistics.usedBytes, 0)
            XCTAssertEqual(statistics.count, 0, "late request refilled cleared cache")
        }
    }

    func testInvalidAndCorruptCoversFallBackToNetwork() async throws {
        let directory = try directory()
        let cache = CoverDiskCache(directory: directory)
        let requests = CoverRequests()
        for _ in 0..<2 {
            _ = try await cache.data(namespace: ["invalid"]) { try await requests.load(Data("not-an-image".utf8)) }
        }
        var statistics = try await cache.statistics()
        XCTAssertEqual(statistics.count, 0)
        let image = image
        _ = try await cache.data(namespace: ["valid"]) { try await requests.load(image) }
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "cover" })
        try Data("corrupt".utf8).write(to: file)
        let result = try await cache.data(namespace: ["valid"]) { try await requests.load(image) }
        XCTAssertEqual(result, image)
        let count = await requests.count
        XCTAssertEqual(count, 4)
        try await cache.clear()
        statistics = try await cache.statistics()
        XCTAssertEqual(statistics.usedBytes, 0)
    }
}
