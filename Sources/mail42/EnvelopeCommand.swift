// EnvelopeCommand.swift — `mail42 envelope list` and `mail42 envelope search "<query>"`.
//
// An envelope is the cheap summary of a message (sender, subject, date, flags, a snippet), without its body:
// scan envelopes first, then `message read` only the few that matter. Both verbs read Apple Mail's index live.

import Foundation
import Mail42AppleMail
import Mail42Kit

enum EnvelopeCommand {

    private static let valueFlags: Set<String> = ["-m", "--mailbox", "--limit", "--before"]

    static func run(args: [String]) {
        let json = CLI.wantsJSON(args)
        let words = CLI.positionals(args, valueFlags: valueFlags)
        switch words.first {
        case "list": list(args: args, json: json)
        case "search": search(args: args, words: words, json: json)
        default:
            CLI.usageError("usage: envelope list [-m <mailbox>] … | envelope search \"<query>\" [--limit N]", json: json)
        }
    }

    // MARK: - list

    private static func list(args: [String], json: Bool) {
        var options = EnvelopeListOptions()
        options.limit = CLI.intFlag(args, "--limit", min: 1, json: json) ?? 50
        options.unreadOnly = args.contains("--unread")
        options.flaggedOnly = args.contains("--flagged")
        if let before = CLI.argValue(args, "--before") {
            guard let id = Int64(before) else {
                CLI.usageError("--before takes an envelope id, not `\(before)`", json: json)
            }
            options.beforeID = id
        }
        if let mailbox = CLI.argValue(args, "-m") ?? CLI.argValue(args, "--mailbox") {
            switch mailbox.lowercased() {
            case "all": options.mailbox = .allInboxes
            case "flagged": options.mailbox = .flagged
            default: options.mailbox = Int64(mailbox).map(MailboxSelector.id) ?? .named(mailbox)
            }
        }
        do {
            show(try LiveMail.open().listEnvelopes(options), json: json)
        } catch {
            CLI.fail(error: error, json: json)
        }
    }

    // MARK: - search

    private static func search(args: [String], words: [String], json: Bool) {
        // `envelope search from:alice is:unread` works unquoted too: the words are joined into one query.
        let query = words.dropFirst().joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            CLI.usageError("usage: envelope search \"<query>\" [--limit N]", json: json)
        }
        let limit = CLI.intFlag(args, "--limit", min: 1, json: json) ?? 50
        do {
            let outcome = try LiveMail.open().search(query, limit: limit)
            show(outcome.records, json: json)
            // On stderr, so a JSON result stays a plain array: how far back the message text was searched.
            if let note = outcome.note { CLI.warn("mail42: \(note)") }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }

    // MARK: - output

    static func show(_ records: [EnvelopeRecord], json: Bool) {
        if json {
            CLI.emitJSONObject(records.map(Presentation.envelope))
        } else {
            Presentation.printEnvelopeTable(records)
        }
    }
}
