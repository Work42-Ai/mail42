// MailActions.swift — what mail42 asks Apple Mail to do with a message, as Apple Events to Mail.app.
//
// mail42 reads Apple Mail's own files; it never edits them. Changing anything (read state, flag, location) is
// Mail's job, so every action here is a small AppleScript Mail runs itself: Mail then syncs the change to the
// server and updates its own index, and the next read sees it. Reply, forward and new open Mail's own compose
// window, pre-filled; the person presses Send. Nothing in this target sends mail: no script below contains the
// word, and a test keeps it that way.
//
// A message is found in Mail by its id (the Envelope Index row id, which is Mail's own message id), and, when that
// id no longer points at it, by its Message-ID header, inside the mailbox it was listed under.

import Foundation
import Mail42Kit

/// Runs AppleScript source and returns its result text.
public protocol ScriptRunner: Sendable {
    func run(_ source: String) throws -> String
}

/// Where a message is, in the words Mail's scripting uses.
public struct MessageRef: Equatable, Sendable {
    /// The account's name as Mail shows it.
    public var accountName: String
    /// The mailbox path inside the account (`["INBOX"]`, `["[Gmail]", "All Mail"]`).
    public var mailboxPath: [String]
    /// The Envelope Index row id, which is Mail's message id.
    public var rowid: Int64
    /// The RFC 5322 Message-ID, with or without angle brackets: a fallback when the id doesn't find it.
    public var messageID: String?

    public init(accountName: String, mailboxPath: [String], rowid: Int64, messageID: String?) {
        self.accountName = accountName
        self.mailboxPath = mailboxPath
        self.rowid = rowid
        self.messageID = messageID
    }

    public init(record: EnvelopeRecord) {
        self.init(
            accountName: record.accountName,
            mailboxPath: record.mailboxName.split(separator: "/").map(String.init),
            rowid: record.row.id, messageID: record.row.messageID)
    }
}

public enum MarkState: Equatable, Sendable {
    case read
    case unread
    /// Flagged, optionally with one of Mail's flag colours.
    case flagged(FlagColor?)
    case unflagged
}

/// Mail's seven flag colours, in the order of its `flag index`.
public enum FlagColor: String, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public struct MailActions: Sendable {

    /// How long Mail gets before the action is reported as unanswered (the outcome is then unknown).
    public static let timeoutSeconds = 20

    private let runner: ScriptRunner

    public init(runner: ScriptRunner = NSAppleScriptRunner()) {
        self.runner = runner
    }

    // MARK: - Permission

    /// Asks Mail something trivial (how many accounts it has) to find out whether mail42 may control it. The first
    /// call makes macOS show its Automation prompt. Throws `.automationDenied` or `.mailTimeout`.
    ///
    /// - Parameter waitSeconds: how long to wait for an answer. The first call blocks while macOS asks the person,
    ///   so this is longer than an action's timeout.
    public func probe(waitSeconds: Int = 120) throws -> Int {
        let text = try runner.run("""
            with timeout of \(waitSeconds) seconds
                tell application "Mail" to return (count of accounts)
            end timeout
            """)
        return Int(text) ?? 0
    }

    // MARK: - State

    public func mark(_ message: MessageRef, as state: MarkState) throws {
        let body: String
        switch state {
        case .read: body = "set read status of theMessage to true"
        case .unread: body = "set read status of theMessage to false"
        case .unflagged: body = "set flagged status of theMessage to false"
        case .flagged(let color):
            body = "set flagged status of theMessage to true"
                + (color.map { "\nset flag index of theMessage to \($0.index)" } ?? "")
        }
        _ = try runner.run(Self.script(for: message, body: body))
    }

    // MARK: - Location

    /// Moves the message to another mailbox of the same account.
    public func move(_ message: MessageRef, toMailbox path: [String]) throws {
        let destination = AppleScript.mailbox(account: message.accountName, path: path)
        _ = try runner.run(Self.script(for: message, body: "move theMessage to \(destination)"))
    }

    /// Archives: moves to the account's archive mailbox. Throws `.noArchiveMailbox` when there is none.
    public func archive(_ message: MessageRef, archivePath: [String]?) throws {
        guard let archivePath else { throw Mail42Error.noArchiveMailbox(message.accountName) }
        try move(message, toMailbox: archivePath)
    }

    /// Deletes: Mail moves the message to the account's Trash (or marks it deleted, as the account does).
    public func delete(_ message: MessageRef) throws {
        _ = try runner.run(Self.script(for: message, body: "delete theMessage"))
    }

    /// Marks the message as junk and, when the account's junk mailbox is known, moves it there.
    public func junk(_ message: MessageRef, junkPath: [String]?) throws {
        var body = "set junk mail status of theMessage to true"
        if let junkPath {
            body += "\nmove theMessage to \(AppleScript.mailbox(account: message.accountName, path: junkPath))"
        }
        _ = try runner.run(Self.script(for: message, body: body))
    }

    // MARK: - Drafts (Mail's own compose window; never sent)

    public func draftReply(_ message: MessageRef, all: Bool) throws {
        let body = "set theDraft to reply theMessage opening window true" + (all ? " reply to all true" : "")
            + "\nactivate"
        _ = try runner.run(Self.script(for: message, body: body))
    }

    public func draftForward(_ message: MessageRef) throws {
        _ = try runner.run(Self.script(for: message, body: "set theDraft to forward theMessage opening window true\nactivate"))
    }

    public func draftNew(to: [String] = [], cc: [String] = [], subject: String? = nil, body: String? = nil) throws {
        var properties = ["visible:true"]
        if let subject { properties.append("subject:\(AppleScript.quote(subject))") }
        if let body { properties.append("content:\(AppleScript.quote(body))") }
        var lines = ["set theDraft to make new outgoing message with properties {\(properties.joined(separator: ", "))}"]
        if !to.isEmpty || !cc.isEmpty {
            lines.append("tell theDraft")
            for address in to {
                lines.append("make new to recipient at end of to recipients with properties {address:\(AppleScript.quote(address))}")
            }
            for address in cc {
                lines.append("make new cc recipient at end of cc recipients with properties {address:\(AppleScript.quote(address))}")
            }
            lines.append("end tell")
        }
        lines.append("activate")
        _ = try runner.run(Self.wrap(lines.joined(separator: "\n")))
    }

    // MARK: - Scripts

    /// The whole script for an action on one message: find it, then run `body` (which may use `theMessage`).
    static func script(for message: MessageRef, body: String) -> String {
        wrap(lookup(message) + "\n" + body)
    }

    private static func wrap(_ inner: String) -> String {
        let indented = inner.split(separator: "\n", omittingEmptySubsequences: false).map { "        " + $0 }.joined(separator: "\n")
        return """
            with timeout of \(timeoutSeconds) seconds
                tell application "Mail"
            \(indented)
                end tell
            end timeout
            """
    }

    /// Sets `theMessage`: by Mail's message id first, then by Message-ID, both inside the mailbox it was listed under.
    private static func lookup(_ message: MessageRef) -> String {
        var lines = [
            "set theBox to \(AppleScript.mailbox(account: message.accountName, path: message.mailboxPath))",
            "set theMessage to missing value",
            "try",
            // `message id N` typed out is read as Mail's text property of that name; the class code forces the
            // by-id reference, which Mail answers directly (a `whose id is` scan of a 160,000-message mailbox times out).
            "    set theMessage to «class mssg» id \(message.rowid) of theBox",
            "    set probe to id of theMessage",
            "on error",
            "    set theMessage to missing value",
            "end try",
        ]
        if let header = message.messageID.flatMap(MessageLink.stripBrackets) {
            lines += [
                "if theMessage is missing value then",
                "    try",
                "        set theMessage to (first message of theBox whose message id is \(AppleScript.quote(header)) or message id is \(AppleScript.quote("<\(header)>")))",
                "    on error",
                "        set theMessage to missing value",
                "    end try",
                "end if",
            ]
        }
        lines.append("if theMessage is missing value then error \"\(AppleScript.notFoundMarker)\" number -9999")
        return lines.joined(separator: "\n")
    }
}

// MARK: - AppleScript text

enum AppleScript {

    /// Marks "the message isn't in that mailbox" in a script's own error, so it can be told from Mail's errors.
    static let notFoundMarker = "mail42-message-not-found"

    /// An AppleScript string literal.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// `mailbox "All Mail" of mailbox "[Gmail]" of account "Google"`
    static func mailbox(account: String, path: [String]) -> String {
        var specifier = "account \(quote(account))"
        for component in path { specifier = "mailbox \(quote(component)) of \(specifier)" }
        return specifier
    }
}

// MARK: - Running scripts in-process

/// Runs the script with `NSAppleScript` in this process. mail42 re-launches itself as its own permission principal
/// before running an action, so macOS asks (once) whether **mail42** may control Mail.
public struct NSAppleScriptRunner: ScriptRunner {

    public init() {}

    public func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw Mail42Error.actionFailed("the script didn't compile")
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info { throw Self.error(from: info) }
        return result.stringValue ?? ""
    }

    /// Maps an AppleScript error to mail42's.
    static func error(from info: NSDictionary) -> Mail42Error {
        let number = (info["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
        let message = info["NSAppleScriptErrorMessage"] as? String ?? "unknown error"
        return map(number: number, message: message)
    }

    static func map(number: Int, message: String) -> Mail42Error {
        switch number {
        case -1743, -1744: return .automationDenied
        case -1712: return .mailTimeout
        default:
            if message.contains(AppleScript.notFoundMarker) { return .notFound("that message in Mail (it may have moved or been deleted)") }
            return .actionFailed("\(message) (\(number))")
        }
    }
}
