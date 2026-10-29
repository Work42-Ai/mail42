import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport

/// The action verbs end to end, with `MAIL42_ACTIONS_DRY_RUN=1` (the harness sets it): the real `mail42` binary
/// finds the message in a synthetic store and prints the AppleScript it would hand to Mail. Nothing touches Mail.
///
/// Fixture: messages 10 (INBOX, conversation 5), 11, 12 (flagged), 13…15 in INBOX; 16 in "Sent Messages".
@Suite struct ActionCLITests {

    private let cli = ReadVerbsCLITests()

    private func scripts(_ run: ReadVerbsCLITests.Run) -> [String] {
        run.object?["scripts"] as? [String] ?? []
    }

    @Test func markPrintsTheScriptAndTheLink() throws {
        guard let f = try cli.synced() else { return }
        defer { f.cleanup() }
        let run = try cli.run(["mark", "10", "read", "--json"], f)
        #expect(run.status == 0 && run.object?["ok"] as? Bool == true && run.object?["dry_run"] as? Bool == true)
        #expect(run.object?["link"] as? String == "mail42://message/10?mid=plain-1%40example.com")
        let script = try #require(scripts(run).first)
        #expect(script.contains("account \"yan@example.com\"") && script.contains("mailbox \"INBOX\""))
        #expect(script.contains("«class mssg» id 10 of theBox") && script.contains("tell theMessage to set read status to true"))

        let flagged = try cli.run(["mark", "10", "flagged", "--color", "purple", "--json"], f)
        #expect(scripts(flagged).first?.contains("tell theMessage to set flag index to 5") == true)
        #expect(try cli.run(["mark", "10", "unread"], f).out.contains("tell theMessage to set read status to false"))
    }

    @Test func aLinkNamesTheMessageToo() throws {
        guard let f = try cli.synced() else { return }
        defer { f.cleanup() }
        let run = try cli.run(["mark", "mail42://message/999?mid=plain-1%40example.com", "unread", "--json"], f)
        #expect(run.status == 0)                                                             // the row id is stale: found by Message-ID
        #expect(scripts(run).first?.contains("«class mssg» id 10 of theBox") == true)
    }

    @Test func moveFindsTheMailboxInTheMessagesOwnAccount() throws {
        guard let f = try cli.synced() else { return }
        defer { f.cleanup() }
        let byName = try cli.run(["move", "10", "Sent Messages", "--json"], f)
        #expect(scripts(byName).first?.contains("move theMessage to mailbox \"Sent Messages\" of account \"yan@example.com\"") == true)
        let byRole = try cli.run(["move", "10", "sent", "--json"], f)
        #expect(scripts(byRole).first?.contains("mailbox \"Sent Messages\"") == true)
        let byID = try cli.run(["move", "10", "2", "--json"], f)
        #expect(scripts(byID).first?.contains("mailbox \"Sent Messages\"") == true)
        let missing = try cli.run(["move", "10", "Nowhere", "--json"], f)
        #expect(missing.status == 2 && missing.errorCode == "not_found")
        #expect(try cli.run(["move", "10", "--json"], f).errorCode == "usage")
    }

    @Test func archiveNeedsAnArchiveMailbox() throws {
        guard let f = try cli.synced() else { return }
        defer { f.cleanup() }
        let none = try cli.run(["archive", "10", "--json"], f)                               // the fixture has no Archive
        #expect(none.status == 1 && none.errorCode == "no_archive_mailbox")

        try f.mail.addMailbox(id: 3, url: EnvelopeIndexBuilder.mailboxURL(["Archive"]))
        let run = try cli.run(["archive", "10", "--json"], f)
        #expect(run.status == 0)
        #expect(scripts(run).first?.contains("move theMessage to mailbox \"Archive\" of account \"yan@example.com\"") == true)
    }

    @Test func deleteAndJunk() throws {
        guard let f = try cli.synced() else { return }
        defer { f.cleanup() }
        #expect(scripts(try cli.run(["delete", "10", "--json"], f)).first?.contains("delete theMessage") == true)
        let bare = try cli.run(["junk", "10", "--json"], f)                                   // no Junk mailbox yet
        #expect(scripts(bare).first?.contains("tell theMessage to set junk mail status to true") == true)
        #expect(scripts(bare).first?.contains("move theMessage") == false)
        try f.mail.addMailbox(id: 4, url: EnvelopeIndexBuilder.mailboxURL(["Junk"]))
        let moved = try cli.run(["junk", "10", "--json"], f)
        #expect(scripts(moved).first?.contains("move theMessage to mailbox \"Junk\"") == true)
    }

    @Test func draftsOpenTheComposerAndNothingSends() throws {
        guard let f = try cli.synced() else { return }
        defer { f.cleanup() }
        let reply = try cli.run(["draft", "reply", "10", "--json"], f)
        #expect(scripts(reply).first?.contains("reply theMessage opening window true") == true)
        #expect(scripts(try cli.run(["draft", "reply-all", "10", "--json"], f)).first?.contains("reply to all true") == true)
        #expect(scripts(try cli.run(["draft", "forward", "10", "--json"], f)).first?.contains("forward theMessage opening window true") == true)

        let new = try cli.run(
            ["draft", "new", "--to", "a@example.com,b@example.com", "--cc", "c@example.com", "--subject", "Hello", "--body", "Hi there", "--json"], f)
        let script = try #require(scripts(new).first)
        #expect(script.contains("subject:\"Hello\"") && script.contains("content:\"Hi there\""))
        #expect(script.contains("{address:\"a@example.com\"}") && script.contains("{address:\"b@example.com\"}"))
        #expect(script.contains("make new cc recipient at end of cc recipients with properties {address:\"c@example.com\"}"))
        #expect(new.object?["id"] == nil && new.object?["link"] == nil)

        for run in [reply, new] {
            #expect(scripts(run).allSatisfy { $0.range(of: "\\bsend\\b", options: .regularExpression) == nil })
        }
        #expect(try cli.run(["draft", "--json"], f).errorCode == "usage")
        #expect(try cli.run(["draft", "burn", "--json"], f).errorCode == "usage")
    }

    @Test func badArgumentsAreUsageErrorsAndUnknownMessagesAreNotFound() throws {
        guard let f = try cli.synced() else { return }
        defer { f.cleanup() }
        #expect(try cli.run(["mark", "10", "maybe", "--json"], f).errorCode == "usage")
        #expect(try cli.run(["mark", "10", "flagged", "--color", "pink", "--json"], f).errorCode == "usage")
        #expect(try cli.run(["mark", "--json"], f).errorCode == "usage")
        #expect(try cli.run(["delete", "banana", "--json"], f).errorCode == "usage")
        let gone = try cli.run(["delete", "5000", "--json"], f)
        #expect(gone.status == 2 && gone.errorCode == "not_found")
    }

    @Test func helpDescribesEveryActionAndTheNeverSendsRule() throws {
        guard let f = try cli.synced() else { return }
        defer { f.cleanup() }
        let help = try cli.run(["help"], f).out
        for verb in ["mark <id>", "move <id>", "archive <id>", "delete <id>", "junk <id>", "draft reply|reply-all|forward", "draft new"] {
            #expect(help.contains(verb), "\(verb)")
        }
        #expect(help.contains("never sends"))
    }
}
