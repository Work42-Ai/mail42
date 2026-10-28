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

    /// Stable machine-readable code (the `error.code` in `--json` output).
    public var code: String {
        switch self {
        case .fdaDenied: return "fda_denied"
        case .noMailData: return "no_mail_data"
        case .schemaUnsupported: return "schema_unsupported"
        case .databaseNotAccessible: return "database_not_accessible"
        case .queryFailed: return "query_failed"
        case .emlxParseFailed: return "emlx_parse_failed"
        case .emlxNotFound: return "emlx_not_found"
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
        }
    }
}
