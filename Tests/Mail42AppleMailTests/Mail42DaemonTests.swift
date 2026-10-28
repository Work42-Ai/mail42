import Testing
@testable import Mail42AppleMail

@Suite struct Mail42DaemonTests {

    @Test func detectsTheReexecPhase() {
        #expect(Mail42Daemon.isReexec(["sync", "--reexec"]))
        #expect(!Mail42Daemon.isReexec(["sync", "--json"]))
    }

    @Test func stripsTheReexecMarker() {
        #expect(Mail42Daemon.strippingReexec(["sync", "--json", "--reexec"]) == ["sync", "--json"])
    }

    @Test func reportsAnAbsoluteExecutablePath() {
        #expect(Mail42Daemon.currentExecutablePath().hasPrefix("/"))
    }
}
