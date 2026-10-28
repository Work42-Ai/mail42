import Foundation
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

    // MARK: - The phase rule

    @Test func reexecsOnlyOnTheFirstPhase() {
        // First phase: nothing marks the process as already re-exec'd.
        #expect(Mail42Daemon.shouldReexec(processArguments: ["mail42", "permissions"], environment: [:]))
        // The re-exec'd process carries --reexec in its own argv…
        #expect(!Mail42Daemon.shouldReexec(processArguments: ["mail42", "permissions", "--reexec"], environment: [:]))
        // …and the environment marker, so even if the argument were stripped it would not loop.
        #expect(!Mail42Daemon.shouldReexec(
            processArguments: ["mail42", "permissions"], environment: ["MAIL42_REEXEC": "1"]))
    }

    @Test func honoursTheOptOutSwitch() {
        #expect(!Mail42Daemon.shouldReexec(
            processArguments: ["mail42", "permissions"], environment: ["MAIL42_NO_REEXEC": "1"]))
        #expect(Mail42Daemon.shouldReexec(
            processArguments: ["mail42", "permissions"], environment: ["MAIL42_NO_REEXEC": "0"]))
    }

    // MARK: - End to end

    /// Regression test for the infinite re-exec loop: the real CLI binary, with the re-launch enabled, must
    /// finish. (The bug was invisible to every unit test because `main.swift` strips `--reexec` before the
    /// verb sees its arguments.)
    @Test func theRealCLIFinishesWithTheReexecEnabled() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/mail42")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            // The test target depends on the executable, so a missing binary is a setup failure, not a skip.
            Issue.record("the mail42 binary isn't built at \(binary.path)")
            return
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["permissions", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "MAIL42_NO_REEXEC")
        environment.removeValue(forKey: "MAIL42_REEXEC")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        guard finished.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            Issue.record("`mail42 permissions` did not finish within 15 s: the re-exec is looping")
            return
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // 0 when this machine has granted Full Disk Access to the binary, 1 when it hasn't: never a hang.
        #expect([0, 1].contains(process.terminationStatus))
        #expect(text.contains("\"fullDiskAccess\""))
        #expect(!text.contains("--reexec"))
    }
}
