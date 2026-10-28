import Foundation
import Testing
@testable import Mail42Kit

@Suite struct Mail42PathsTests {

    @Test func ownFilesLiveUnderWork42Mail42() {
        #expect(Mail42Paths.root.path.hasSuffix("/.work42/mail42"))
        #expect(Mail42Paths.db.lastPathComponent == "mail.db")
        #expect(Mail42Paths.trace.lastPathComponent == "trace.jsonl")
    }

    @Test func environmentOverridesRedirectBothLocations() {
        let env = ["MAIL42_ROOT": "/tmp/sandbox-root", "MAIL42_MAIL_LIBRARY": "/tmp/sandbox-mail"]
        #expect(Mail42Paths.root(environment: env).path == "/tmp/sandbox-root")
        #expect(Mail42Paths.appleMailLibrary(environment: env).path == "/tmp/sandbox-mail")
    }

    @Test func emptyOrMissingOverridesFallBackToTheHomeDirectory() {
        for env in [[:], ["MAIL42_ROOT": "", "MAIL42_MAIL_LIBRARY": ""]] as [[String: String]] {
            #expect(Mail42Paths.root(environment: env).path.hasSuffix("/.work42/mail42"))
            #expect(Mail42Paths.appleMailLibrary(environment: env).path.hasSuffix("/Library/Mail"))
        }
    }

    @Test func derivedFilesFollowTheRootOverride() {
        // db and trace are built from `root`, so one override moves everything mail42 writes.
        let env = ProcessInfo.processInfo.environment
        #expect(Mail42Paths.db.deletingLastPathComponent() == Mail42Paths.root(environment: env))
        #expect(Mail42Paths.trace.deletingLastPathComponent() == Mail42Paths.root(environment: env))
    }

    @Test func appleMailRootPicksTheHighestVersionDirectory() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail42-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        for name in ["V9", "V10", "V2", "MailData", "Vx", "v11"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(Mail42Paths.appleMailRoot(in: library)?.lastPathComponent == "V10")
    }

    @Test func appleMailRootIsNilWhenThereIsNoStore() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail42-missing-\(UUID().uuidString)")
        #expect(Mail42Paths.appleMailRoot(in: missing) == nil)
    }

    @Test func traceAppendsOneJSONObjectPerLine() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail42-trace-\(UUID().uuidString)/trace.jsonl")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        Trace.append(src: "sync", event: "sync-ok", fields: ["added": 3], to: file)
        Trace.append(src: "sync", event: "sync-failed", fields: ["code": "fda_denied"], to: file)
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let first = try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["event"] as? String == "sync-ok")
        #expect(first["added"] as? Int == 3)
        #expect(first["ts"] is String)
    }
}
