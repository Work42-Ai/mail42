import Foundation
import Testing
import Mail42Kit
@testable import Mail42Actions

/// Records the scripts instead of running them.
private final class Recorder: ScriptRunner, @unchecked Sendable {
    var scripts: [String] = []
    var failure: Mail42Error?
    func run(_ source: String) throws -> String {
        if let failure { throw failure }
        scripts.append(source)
        return ""
    }
}

@Suite struct MailActionsTests {

    private let inbox = MessageRef(accountName: "Google", mailboxPath: ["INBOX"], rowid: 4821, messageID: "<abc@mail.gmail.com>")

    private func capture(_ body: (MailActions) throws -> Void) throws -> String {
        let recorder = Recorder()
        try body(MailActions(runner: recorder))
        return try #require(recorder.scripts.first)
    }

    // MARK: - Finding the message

    @Test func aMessageIsFoundByIdThenByMessageIDInsideItsMailbox() throws {
        let script = try capture { try $0.mark(inbox, as: .read) }
        #expect(script.contains("set theBox to mailbox \"INBOX\" of account \"Google\""))
        #expect(script.contains("«class mssg» id 4821 of theBox"))
        #expect(script.contains("whose message id is \"abc@mail.gmail.com\" or message id is \"<abc@mail.gmail.com>\""))
        #expect(script.contains("error \"mail42-message-not-found\" number -9999"))
        #expect(script.hasPrefix("with timeout of 20 seconds\n    tell application \"Mail\""))
    }

    @Test func aNestedMailboxIsSpelledOutLevelByLevel() throws {
        let gmail = MessageRef(accountName: "Google", mailboxPath: ["[Gmail]", "All Mail"], rowid: 1, messageID: nil)
        let script = try capture { try $0.mark(gmail, as: .read) }
        #expect(script.contains("mailbox \"All Mail\" of mailbox \"[Gmail]\" of account \"Google\""))
        #expect(!script.contains("whose message id"))                          // no Message-ID, no fallback
    }

    @Test func textIsQuotedSoItCannotBreakOutOfAString() {
        #expect(AppleScript.quote("plain") == "\"plain\"")
        #expect(AppleScript.quote("say \"hi\"\\") == "\"say \\\"hi\\\"\\\\\"")
        #expect(AppleScript.quote("a\nb\tc") == "\"a\\nb\\tc\"")
        let hostile = MessageRef(accountName: "x\" & (do shell script \"id\") & \"", mailboxPath: ["INBOX"], rowid: 1, messageID: nil)
        let script = Self.script { try $0.mark(hostile, as: .read) }
        #expect(script.contains("account \"x\\\" & (do shell script \\\"id\\\") & \\\"\""))     // all inside the string
    }

    private static func script(_ body: (MailActions) throws -> Void) -> String {
        let recorder = Recorder()
        try? body(MailActions(runner: recorder))
        return recorder.scripts.first ?? ""
    }

    // MARK: - State

    @Test func readUnreadAndFlagsSetMailsOwnProperties() throws {
        #expect(try capture { try $0.mark(inbox, as: .read) }.contains("set read status of theMessage to true"))
        #expect(try capture { try $0.mark(inbox, as: .unread) }.contains("set read status of theMessage to false"))
        #expect(try capture { try $0.mark(inbox, as: .unflagged) }.contains("set flagged status of theMessage to false"))
        let plain = try capture { try $0.mark(inbox, as: .flagged(nil)) }
        #expect(plain.contains("set flagged status of theMessage to true") && !plain.contains("flag index"))
        let purple = try capture { try $0.mark(inbox, as: .flagged(.purple)) }
        #expect(purple.contains("set flag index of theMessage to 5"))
        #expect(FlagColor.allCases.map(\.index) == [0, 1, 2, 3, 4, 5, 6] && FlagColor.red.index == 0 && FlagColor.gray.index == 6)
    }

    // MARK: - Location

    @Test func moveArchiveDeleteAndJunk() throws {
        #expect(try capture { try $0.move(inbox, toMailbox: ["Receipts"]) }
            .contains("move theMessage to mailbox \"Receipts\" of account \"Google\""))
        #expect(try capture { try $0.archive(inbox, archivePath: ["[Gmail]", "All Mail"]) }
            .contains("move theMessage to mailbox \"All Mail\" of mailbox \"[Gmail]\" of account \"Google\""))
        #expect(try capture { try $0.delete(inbox) }.contains("delete theMessage"))
        let junk = try capture { try $0.junk(inbox, junkPath: ["Junk"]) }
        #expect(junk.contains("set junk mail status of theMessage to true"))
        #expect(junk.contains("move theMessage to mailbox \"Junk\" of account \"Google\""))
        let bare = try capture { try $0.junk(inbox, junkPath: nil) }
        #expect(bare.contains("set junk mail status of theMessage to true") && !bare.contains("move theMessage"))
    }

    @Test func archivingWithoutAnArchiveMailboxSaysSo() {
        #expect(throws: Mail42Error.noArchiveMailbox("Google")) {
            try MailActions(runner: Recorder()).archive(self.inbox, archivePath: nil)
        }
    }

    // MARK: - Drafts

    @Test func draftsOpenMailsComposeWindow() throws {
        let reply = try capture { try $0.draftReply(inbox, all: false) }
        #expect(reply.contains("reply theMessage opening window true") && !reply.contains("reply to all"))
        #expect(reply.contains("activate"))
        #expect(try capture { try $0.draftReply(inbox, all: true) }.contains("opening window true reply to all true"))
        #expect(try capture { try $0.draftForward(inbox) }.contains("forward theMessage opening window true"))

        let new = try capture {
            try $0.draftNew(to: ["a@example.com"], cc: ["b@example.com"], subject: "Hi \"you\"", body: "Line 1\nLine 2")
        }
        #expect(new.contains("make new outgoing message with properties {visible:true, subject:\"Hi \\\"you\\\"\", content:\"Line 1\\nLine 2\"}"))
        #expect(new.contains("make new to recipient at end of to recipients with properties {address:\"a@example.com\"}"))
        #expect(new.contains("make new cc recipient at end of cc recipients with properties {address:\"b@example.com\"}"))
        let empty = try capture { try $0.draftNew() }
        #expect(empty.contains("{visible:true}") && !empty.contains("tell theDraft"))   // no body: Mail keeps the signature
    }

    // MARK: - Never sends

    @Test func noScriptEverSends() throws {
        let recorder = Recorder()
        let actions = MailActions(runner: recorder)
        try actions.mark(inbox, as: .flagged(.red))
        try actions.move(inbox, toMailbox: ["A"])
        try actions.archive(inbox, archivePath: ["Archive"])
        try actions.delete(inbox)
        try actions.junk(inbox, junkPath: ["Junk"])
        try actions.draftReply(inbox, all: true)
        try actions.draftForward(inbox)
        try actions.draftNew(to: ["a@example.com"], cc: ["b@example.com"], subject: "send", body: "send it")
        for script in recorder.scripts {
            // The subject and body above deliberately contain the word; strip string literals before looking.
            let code = script.replacingOccurrences(of: "\"(\\\\.|[^\"\\\\])*\"", with: "\"\"", options: .regularExpression)
            #expect(code.range(of: "\\bsend\\b", options: [.regularExpression, .caseInsensitive]) == nil, "\(script)")
        }
        #expect(recorder.scripts.count == 8)
    }

    @Test func theTargetsSourceNeverCallsSend() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Mail42Actions")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                // The word itself (Mail's `send` command); `Sendable` and the like are Swift's.
                #expect(code.range(of: "\\bsend\\b", options: [.regularExpression, .caseInsensitive]) == nil,
                        "\(file.lastPathComponent):\(number + 1) mentions sending: \(line)")
            }
        }
    }

    // MARK: - Errors

    @Test func appleScriptErrorsMapToMail42Errors() {
        #expect(NSAppleScriptRunner.map(number: -1743, message: "Not authorized to send Apple events to Mail.") == .automationDenied)
        #expect(NSAppleScriptRunner.map(number: -1744, message: "") == .automationDenied)
        #expect(NSAppleScriptRunner.map(number: -1712, message: "AppleEvent timed out.") == .mailTimeout)
        #expect(NSAppleScriptRunner.map(number: -9999, message: "mail42-message-not-found") == .notFound("that message in Mail (it may have moved or been deleted)"))
        #expect(NSAppleScriptRunner.map(number: -10000, message: "Can't get mailbox") == .actionFailed("Can't get mailbox (-10000)"))
    }

    @Test func aFailingRunnerSurfacesItsError() {
        let recorder = Recorder()
        recorder.failure = .automationDenied
        #expect(throws: Mail42Error.automationDenied) { try MailActions(runner: recorder).mark(self.inbox, as: .read) }
    }

    @Test func recordsBecomeMessageRefs() {
        let row = EnvelopeRow(
            id: 77, messageID: "<m@x>", conversationID: 0, mailboxID: 3, subject: "s", fromName: nil, fromAddr: nil,
            dateReceived: 0, dateSent: 0, snippet: nil, isRead: false, isFlagged: false, hasAttachments: false, size: 1, emlxPath: nil)
        let record = EnvelopeRecord(
            row: row, accountID: "A", accountName: "Google", accountEmail: nil, mailboxName: "[Gmail]/All Mail",
            mailboxRole: "archive", to: [], cc: [])
        #expect(MessageRef(record: record) == MessageRef(
            accountName: "Google", mailboxPath: ["[Gmail]", "All Mail"], rowid: 77, messageID: "<m@x>"))
    }
}
