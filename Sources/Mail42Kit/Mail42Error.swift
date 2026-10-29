// Mail42Error.swift — mail42's error type, with the stable machine codes the CLI prints under `--json`
// (`{"error":{"code","message"}}`) and the exit code each one maps to.

import Foundation

public enum Mail42Error: Error, LocalizedError, Equatable {

    /// macOS refused to let mail42 read `~/Library/Mail` (Full Disk Access isn't granted).
    case fdaDenied
    /// Apple Mail has no store on this Mac (`~/Library/Mail` or its Envelope Index doesn't exist).
    case noMailData
    /// A table or column mail42 depends on is missing from Apple's Envelope Index: Apple changed its private
    /// schema. mail42 refuses to guess rather than index wrong data.
    case schemaUnsupported(table: String, column: String)
    /// The Envelope Index (or its snapshot copy) couldn't be opened.
    case databaseNotAccessible(String)
    case queryFailed(String)
    /// An `.emlx` file's container or RFC 822 content couldn't be parsed.
    case emlxParseFailed(String)
    /// The `.emlx` for a message isn't on disk (Exchange accounts, or a body Mail never downloaded).
    case emlxNotFound(messageId: Int, path: String)
    /// No message, mailbox or attachment part with that id.
    case notFound(String)
    /// A search query that doesn't parse. `position` is the 0-based character offset of the problem.
    case badQuery(String, position: Int)
    /// The message has no Message-ID header, so it can't be opened in Mail.app.
    case noMessageID(Int64)
    /// The attachment exists but its bytes were never downloaded by Mail.
    case attachmentNotDownloaded(String)
    /// A file couldn't be written (an attachment copy, or a `--out` file).
    case writeFailed(String)
    /// macOS refused to let mail42 control Mail (Automation isn't allowed for mail42).
    case automationDenied
    /// Mail didn't answer in time. Whether the action happened is unknown, so it is never retried.
    case mailTimeout
    /// The account has no archive mailbox to move a message to.
    case noArchiveMailbox(String)
    /// Mail refused or failed an action (the message is Mail's own error text).
    case actionFailed(String)

    /// Stable machine-readable code (the `error.code` in `--json` output).
    public var code: String {
        switch self {
        case .automationDenied: return "automation_denied"
        case .mailTimeout: return "mail_timeout"
        case .noArchiveMailbox: return "no_archive_mailbox"
        case .actionFailed: return "action_failed"
        case .fdaDenied: return "fda_denied"
        case .noMailData: return "no_mail_data"
        case .schemaUnsupported: return "schema_unsupported"
        case .databaseNotAccessible: return "database_not_accessible"
        case .queryFailed: return "query_failed"
        case .emlxParseFailed: return "emlx_parse_failed"
        case .emlxNotFound: return "emlx_not_found"
        case .notFound: return "not_found"
        case .badQuery: return "bad_query"
        case .noMessageID: return "no_message_id"
        case .attachmentNotDownloaded: return "attachment_not_downloaded"
        case .writeFailed: return "write_failed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .fdaDenied:
            return "mail42 can't read Apple Mail's data: Full Disk Access isn't granted. "
                + "Run `mail42 permissions open`, turn on mail42, then try again."
        case .noMailData:
            return "No Apple Mail data found in ~/Library/Mail. Is Mail set up on this Mac?"
        case .schemaUnsupported(let table, let column):
            return "Apple Mail's index has changed: column `\(column)` is missing from table `\(table)`. "
                + "This macOS version isn't supported by this mail42 yet; update mail42."
        case .databaseNotAccessible(let message):
            return "Couldn't open the Apple Mail index: \(message)"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        case .emlxParseFailed(let message):
            return "Couldn't parse the message file: \(message)"
        case .emlxNotFound(let id, let path):
            return "The message file for message \(id) isn't on disk (\(path))."
        case .notFound(let what):
            return "Not found: \(what)."
        case .badQuery(let message, let position):
            return "Bad query at position \(position): \(message)"
        case .noMessageID(let id):
            return "Message \(id) has no Message-ID header, so it can't be opened in Mail."
        case .attachmentNotDownloaded(let name):
            return "The attachment `\(name)` hasn't been downloaded by Mail yet. "
                + "Open the message in Mail (`mail42 open <id>`) so it fetches it, then try again."
        case .writeFailed(let message):
            return "Couldn't write the file: \(message)"
        case .automationDenied:
            return "macOS didn't let mail42 control Mail. Open System Settings › Privacy & Security › Automation, "
                + "turn on Mail under mail42, then try again."
        case .mailTimeout:
            return "Mail didn't answer in 20 seconds. The action may or may not have happened; check Mail before "
                + "trying again."
        case .noArchiveMailbox(let account):
            return "The account \(account) has no Archive mailbox to move the message to."
        case .actionFailed(let message):
            return "Mail couldn't do that: \(message)"
        }
    }
}
