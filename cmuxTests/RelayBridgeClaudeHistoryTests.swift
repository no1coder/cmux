import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RelayBridgeClaudeHistoryTests: XCTestCase {
    func testPaginateClaudeHistoryReturnsLatestPageAndOlderCursor() {
        let bridge = RelayBridge(socketPath: "/tmp/unused.sock")
        let snapshot = RelayBridge.ClaudeHistorySnapshot(
            fileSize: 1,
            modifiedAt: Date(),
            messages: [
                ["seq": 1, "type": "user"],
                ["seq": 2, "type": "assistant"],
                ["seq": 3, "type": "user"],
                ["seq": 4, "type": "assistant"],
            ],
            totalSeq: 4,
            status: "idle",
            usage: [:]
        )

        let recent = bridge.paginateClaudeHistory(snapshot: snapshot, afterSeq: 0, beforeSeq: nil, limit: 2)
        XCTAssertEqual(recent.messages.count, 2)
        XCTAssertEqual(recent.messages.first?["seq"] as? Int, 3)
        XCTAssertEqual(recent.messages.last?["seq"] as? Int, 4)
        XCTAssertTrue(recent.hasMore)
        XCTAssertEqual(recent.nextBeforeSeq, 3)

        let older = bridge.paginateClaudeHistory(snapshot: snapshot, afterSeq: 0, beforeSeq: 3, limit: 2)
        XCTAssertEqual(older.messages.count, 2)
        XCTAssertEqual(older.messages.first?["seq"] as? Int, 1)
        XCTAssertEqual(older.messages.last?["seq"] as? Int, 2)
        XCTAssertFalse(older.hasMore)
        XCTAssertEqual(older.nextBeforeSeq, 1)
    }

    func testPaginateClaudeHistorySupportsAfterSeqIncrementalReads() {
        let bridge = RelayBridge(socketPath: "/tmp/unused.sock")
        let snapshot = RelayBridge.ClaudeHistorySnapshot(
            fileSize: 1,
            modifiedAt: Date(),
            messages: [
                ["seq": 1, "type": "user"],
                ["seq": 2, "type": "assistant"],
                ["seq": 3, "type": "user"],
                ["seq": 4, "type": "assistant"],
            ],
            totalSeq: 4,
            status: "idle",
            usage: [:]
        )

        let incremental = bridge.paginateClaudeHistory(snapshot: snapshot, afterSeq: 2, beforeSeq: nil, limit: 50)
        XCTAssertEqual(incremental.messages.count, 2)
        XCTAssertEqual(incremental.messages.first?["seq"] as? Int, 3)
        XCTAssertEqual(incremental.messages.last?["seq"] as? Int, 4)
        XCTAssertFalse(incremental.hasMore)
        XCTAssertEqual(incremental.nextBeforeSeq, 3)
    }

    func testLoadClaudeHistorySnapshotReusesCachedParseUntilInvalidated() throws {
        let bridge = RelayBridge(socketPath: "/tmp/unused.sock")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-claude-history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try """
        {"type":"user","uuid":"u1","message":{"content":"hello"}}
        {"type":"assistant","uuid":"a1","message":{"content":"world","usage":{"input_tokens":1,"output_tokens":2}}}
        """.write(to: tempURL, atomically: true, encoding: .utf8)

        let attrs1 = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: tempURL.path) as [FileAttributeKey: Any])
        let fileSize1 = try XCTUnwrap(attrs1[.size] as? UInt64)
        let mod1 = attrs1[.modificationDate] as? Date
        let snapshot1 = try XCTUnwrap(bridge.loadClaudeHistorySnapshot(path: tempURL.path, fileSize: fileSize1, modifiedAt: mod1))
        XCTAssertEqual(snapshot1.totalSeq, 2)

        try """
        {"type":"user","uuid":"u1","message":{"content":"hello"}}
        {"type":"assistant","uuid":"a1","message":{"content":"world","usage":{"input_tokens":1,"output_tokens":2}}}
        {"type":"assistant","uuid":"a2","message":{"content":"new"}}
        """.write(to: tempURL, atomically: true, encoding: .utf8)

        let cachedSnapshot = try XCTUnwrap(bridge.loadClaudeHistorySnapshot(path: tempURL.path, fileSize: fileSize1, modifiedAt: mod1))
        XCTAssertEqual(cachedSnapshot.totalSeq, 2, "same metadata should hit cache")

        bridge.invalidateClaudeHistorySnapshot(path: tempURL.path)
        let attrs2 = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: tempURL.path) as [FileAttributeKey: Any])
        let fileSize2 = try XCTUnwrap(attrs2[.size] as? UInt64)
        let mod2 = attrs2[.modificationDate] as? Date
        let refreshedSnapshot = try XCTUnwrap(bridge.loadClaudeHistorySnapshot(path: tempURL.path, fileSize: fileSize2, modifiedAt: mod2))
        XCTAssertEqual(refreshedSnapshot.totalSeq, 3)
    }
}
