import Foundation
import Testing
@testable import Mail42Kit

@Suite struct SyncStatusTests {

    private let now = Date(timeIntervalSince1970: 1_793_188_800)

    private func running(updatedAgo seconds: TimeInterval = 5, pid: Int32? = 4242) -> SyncStatus {
        SyncStatus(state: .running, phase: "indexing", pid: pid, started: now.addingTimeInterval(-60),
                   updated: now.addingTimeInterval(-seconds), processed: 500, total: 2_000)
    }

    @Test func aFreshRunningStatusIsRunning() {
        #expect(running().isRunning(now: now, processIsAlive: { _ in true }))
    }

    @Test func anIdleStatusIsNeverRunning() {
        #expect(!SyncStatus.idle(finished: now).isRunning(now: now, processIsAlive: { _ in true }))
    }

    @Test func aStatusWhoseProcessIsGoneIsStale() {
        #expect(!running().isRunning(now: now, processIsAlive: { _ in false }))
    }

    @Test func aStatusNobodyUpdatedForTooLongIsStale() {
        let old = running(updatedAgo: SyncStatus.staleAfter + 1)
        #expect(!old.isRunning(now: now, processIsAlive: { _ in true }))
        #expect(running(updatedAgo: SyncStatus.staleAfter - 1).isRunning(now: now, processIsAlive: { _ in true }))
    }

    @Test func theRealProcessCheckKnowsThisProcessIsAlive() {
        #expect(SyncStatus.processIsAlive(getpid()))
        #expect(running(pid: getpid()).isRunning(now: now))
    }

    @Test func fractionNeedsAPositiveTotal() {
        #expect(running().fraction == 0.25)
        var unknown = running(); unknown.total = nil
        #expect(unknown.fraction == nil)
        var empty = running(); empty.total = 0
        #expect(empty.fraction == nil)
        var over = running(); over.processed = 9_999
        #expect(over.fraction == 1)
    }

    @Test func roundTripsThroughTheFileAndTheWriteIsAtomic() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("nested/sync-status.json")
        #expect(SyncStatus.read(from: url) == nil)                         // no file yet

        let status = running()
        status.write(to: url)                                              // also creates the folder
        #expect(SyncStatus.read(from: url) == status)

        SyncStatus.idle(finished: now).write(to: url)                      // replaced in place
        #expect(SyncStatus.read(from: url)?.state == .idle)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["sync-status.json"])
    }

    @Test func aCorruptFileReadsAsNoStatus() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(SyncStatus.read(from: url) == nil)
    }

    @Test func theStatusFileLivesNextToTheDatabase() {
        #expect(Mail42Paths.syncStatus.lastPathComponent == "sync-status.json")
        #expect(Mail42Paths.syncStatus.deletingLastPathComponent() == Mail42Paths.root)
    }
}
