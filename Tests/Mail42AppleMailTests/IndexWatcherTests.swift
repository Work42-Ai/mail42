import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import Mail42AppleMail

/// The watcher reports a change when Apple Mail's mailbox counters move, once, soon, and never when they don't (WOR-828, AC9).
@Suite struct IndexWatcherTests {

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Lets the watcher's closure read through a snapshot the test owns (SQLite connections are serialised per call).
    private final class SnapshotBox: @unchecked Sendable {
        let snapshot: EnvelopeIndexSnapshot
        init(_ snapshot: EnvelopeIndexSnapshot) { self.snapshot = snapshot }
    }

    private func fixture() throws -> EnvelopeIndexBuilder {
        let mail = try EnvelopeIndexBuilder(wal: true)
        try mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 10, unread: 4)
        try mail.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["Sent"]), total: 3, unread: 0)
        return mail
    }

    /// A watcher on the fixture, reading the counters through the same in-place connection the daemon uses.
    private func watcher(
        _ mail: EnvelopeIndexBuilder, debounce: TimeInterval = 0.1, reports: Reports
    ) throws -> (IndexWatcher, EnvelopeIndexSnapshot) {
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: mail.mailRoot)
        let reader = SnapshotBox(snapshot)
        let watcher = IndexWatcher(
            mailRoot: mail.mailRoot, debounce: debounce,
            signature: {
                var parts: [String] = []
                try reader.snapshot.connection.query("SELECT ROWID, total_count, unread_count FROM mailboxes ORDER BY ROWID") { row in
                    parts.append("\(row.int(0)):\(row.int(1)):\(row.int(2))")
                }
                return parts.joined(separator: ",")
            },
            onChange: { reports.add($0) })
        return (watcher, snapshot)
    }

    /// Polls until `condition` holds or `seconds` pass.
    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aCounterChangeIsReportedOnceWithinASecond() async throws {
        let mail = try fixture()
        defer { mail.cleanup() }
        let reports = Reports()
        let (watcher, snapshot) = try watcher(mail, reports: reports)
        defer { watcher.stop(); snapshot.close() }
        try #require(snapshot.readsInPlace, "the fixture index should be readable in place")
        watcher.start()
        #expect(watcher.lastSignature == "1:10:4,2:3:0")

        try mail.setMailboxCounts(id: 1, total: 11, unread: 5)        // mail arrived
        await wait(1.0) { !reports.values.isEmpty }
        #expect(reports.values == ["1:11:5,2:3:0"])

        try await Task.sleep(for: .milliseconds(600))                  // nothing else happens: nothing else is reported
        #expect(reports.values.count == 1)
    }

    @Test func aBurstOfWritesIsOneReport() async throws {
        let mail = try fixture()
        defer { mail.cleanup() }
        let reports = Reports()
        // A long quiet period, and writes with nothing between them, so a slow machine can't stretch the burst past it.
        let (watcher, snapshot) = try watcher(mail, debounce: 0.6, reports: reports)
        defer { watcher.stop(); snapshot.close() }
        try #require(snapshot.readsInPlace, "the fixture index should be readable in place")
        watcher.start()

        for unread in 5...9 {                                          // five quick changes (a bulk "mark as read")
            try mail.setMailboxCounts(id: 1, total: 10, unread: Int64(10 - unread))
        }
        await wait(4.0) { !reports.values.isEmpty }
        try await Task.sleep(for: .milliseconds(1000))
        #expect(reports.values == ["1:10:1,2:3:0"])                    // one report, with where the counters ended up
    }

    @Test func aWriteThatLeavesEveryCounterAsItWasReportsNothing() async throws {
        let mail = try fixture()
        defer { mail.cleanup() }
        let reports = Reports()
        let (watcher, snapshot) = try watcher(mail, reports: reports)
        defer { watcher.stop(); snapshot.close() }
        try #require(snapshot.readsInPlace, "the fixture index should be readable in place")
        watcher.start()

        // Mail re-indexing, or saving a draft: the index file is written, no mailbox counter moves.
        try mail.addMessage(.init(
            rowid: 50, subject: "Draft", senderAddress: "me@example.com", mailboxID: 1, dateReceived: 1_761_000_000))
        try mail.setMailboxCounts(id: 1, total: 10, unread: 4)
        try await Task.sleep(for: .milliseconds(900))
        #expect(reports.values.isEmpty)
        #expect(watcher.lastSignature == "1:10:4,2:3:0")
    }

    @Test func nothingIsReportedAfterStop() async throws {
        let mail = try fixture()
        defer { mail.cleanup() }
        let reports = Reports()
        let (watcher, snapshot) = try watcher(mail, reports: reports)
        defer { snapshot.close() }
        try #require(snapshot.readsInPlace, "the fixture index should be readable in place")
        watcher.start()
        watcher.stop()
        try mail.setMailboxCounts(id: 1, total: 20, unread: 9)
        try await Task.sleep(for: .milliseconds(700))
        #expect(reports.values.isEmpty)
    }

    @Test func anIndexWithoutAWALIsWatchedThroughItsMainFile() async throws {
        // Mail not running, or not in WAL mode: there is no -wal file. The main file is still watched, and the
        // missing -wal is looked for again each second rather than being an error.
        let mail = try EnvelopeIndexBuilder()                          // rollback journal: no -wal file
        defer { mail.cleanup() }
        try mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 1, unread: 1)
        let reports = Reports()
        let (watcher, snapshot) = try watcher(mail, reports: reports)
        defer { watcher.stop(); snapshot.close() }
        watcher.start()
        try mail.setMailboxCounts(id: 1, total: 2, unread: 2)          // a write to the main file
        await wait(2.0) { !reports.values.isEmpty }
        #expect(reports.values == ["1:2:2"])
    }
}
