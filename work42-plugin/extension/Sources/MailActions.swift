// MailActions.swift — what the widget asks Apple Mail to do with a message, as typed Apple Events (WOR-900).
//
// This is the acting half of the `mail42` command line, moved into the extension: instead of AppleScript run by `osascript`,
// each action is an `AppleEventRequest` that Work42 builds and sends to `com.apple.mail` (`services.automation`, permission
// `automation` with target `com.apple.mail`). Mail still does the work: it syncs the change to the server and updates its own
// index. Reply, forward and new open Mail's own compose window, pre-filled; the person presses Send. Nothing here sends mail.
//
// A message is addressed as `message id <row id> of mailbox … of account …` (the Envelope Index row id is Mail's own message
// id). Every action first asks Mail for that message's id, as the CLI's script did, so a message that moved or was deleted is
// "not found" rather than an obscure Mail error.
//
// What the typed surface cannot say (Work42's `AppleEventBuilder`, which only knows the values of `AppleEventValue`):
//   · a `whose` test (the CLI's fallback "first message whose message id is …"): there is no comparison descriptor;
//   · an insertion location (`at end of to recipients`): a `.record` is sent as a plain record, never an `insl`.
// So a message whose row id no longer points at it is not found by Message-ID here, and a new draft cannot be given recipients;
// that one case answers `unsupported_by_automation` instead of guessing at a shape the host would not build.

import Foundation
import Work42PluginKit

nonisolated enum MailAct {

    static let mailBundleID = "com.apple.mail"

    /// How long Mail gets before an action is reported as unanswered (the outcome is then unknown, so it is never retried).
    static let timeoutSeconds = 20

    // MARK: Four-character codes of Mail's scripting dictionary (Mail.sdef)

    enum Code {
        // Classes
        static let message: AppleEventCode = "mssg"
        static let mailbox: AppleEventCode = "mbxp"
        static let account: AppleEventCode = "mact"
        static let outgoingMessage: AppleEventCode = "bcke"
        static let property: AppleEventCode = "prop"
        // Specifier forms
        static let byName: AppleEventCode = "name"
        static let byID: AppleEventCode = "ID  "
        // Properties
        static let id: AppleEventCode = "ID  "
        static let readStatus: AppleEventCode = "isrd"
        static let flaggedStatus: AppleEventCode = "isfl"
        static let flagIndex: AppleEventCode = "fidx"
        static let junkStatus: AppleEventCode = "isjk"
        static let subject: AppleEventCode = "subj"
        static let content: AppleEventCode = "ctnt"
        static let visible: AppleEventCode = "pvis"
        // Events: core suite
        static let core: AppleEventCode = "core"
        static let setData: AppleEventCode = "setd"
        static let getData: AppleEventCode = "getd"
        static let delete: AppleEventCode = "delo"
        static let move: AppleEventCode = "move"
        static let create: AppleEventCode = "crel"
        // Events: Mail suite
        static let mailSuite: AppleEventCode = "emal"
        static let reply: AppleEventCode = "rpms"
        static let forward: AppleEventCode = "fwms"
        // Events: required suite and Internet suite
        static let misc: AppleEventCode = "misc"
        static let activate: AppleEventCode = "actv"
        static let internet: AppleEventCode = "GURL"
        // Parameters
        static let data: AppleEventCode = "data"
        static let insertHere: AppleEventCode = "insh"
        static let newClass: AppleEventCode = "kocl"
        static let properties: AppleEventCode = "prdt"
        static let openingWindow: AppleEventCode = "ropw"
        static let replyToAll: AppleEventCode = "rpal"
    }

    // MARK: Where a message is

    /// What the caller knows about a message from `MailIndex`, in the words Mail's scripting uses.
    struct Target: Equatable, Sendable {
        /// The account's name as Mail shows it.
        var accountName: String
        /// The mailbox path inside the account (`["INBOX"]`, `["[Gmail]", "All Mail"]`). A Gmail message is stored in All Mail but
        /// lives in Mail under its labels too: pass where Mail shows it (its Inbox when it has one), which is also a far smaller
        /// mailbox for Mail to look in than the 160,000-message All Mail.
        var mailboxPath: [String]
        /// The Envelope Index row id, which is Mail's message id.
        var rowid: Int64
        /// The RFC 5322 Message-ID, for `open` (Mail's `message://` link).
        var messageID: String?
        /// The `mail42://message/<id>?mid=<Message-ID>` link that finds the message again after Mail moves it.
        var link: String?
        /// The account's archive mailbox (`MailAct.archivePath(in:)`), nil when it has none.
        var archivePath: [String]?
        /// The account's junk mailbox, nil when it has none.
        var junkPath: [String]?

        init(accountName: String, mailboxPath: [String], rowid: Int64, messageID: String? = nil, link: String? = nil,
             archivePath: [String]? = nil, junkPath: [String]? = nil) {
            self.accountName = accountName
            self.mailboxPath = mailboxPath
            self.rowid = rowid
            self.messageID = messageID
            self.link = link
            self.archivePath = archivePath
            self.junkPath = junkPath
        }
    }

    /// `["[Gmail]", "All Mail"]` from the full name `[Gmail]/All Mail`.
    static func path(ofMailboxNamed name: String) -> [String] {
        name.split(separator: "/").map(String.init)
    }

    /// The account's archive mailbox as the CLI chose it: the one with the `archive` role, a `[Gmail]` one first.
    static func archivePath(in boxes: [MailMailboxRef]) -> [String]? {
        boxes.filter { $0.role == "archive" }
            .sorted { ($0.name.hasPrefix("[Gmail]") ? 0 : 1) < ($1.name.hasPrefix("[Gmail]") ? 0 : 1) }
            .first.map { path(ofMailboxNamed: $0.name) }
    }

    /// The account's junk mailbox: the one with the `junk` role.
    static func junkPath(in boxes: [MailMailboxRef]) -> [String]? {
        boxes.first { $0.role == "junk" }.map { path(ofMailboxNamed: $0.name) }
    }

    enum Draft: Equatable, Sendable {
        case new(to: [String] = [], cc: [String] = [], subject: String? = nil, body: String? = nil)
        case reply
        case replyAll
        case forward
    }

    // MARK: Specifiers

    static func accountSpecifier(_ name: String) -> AppleEventValue {
        .object(AppleEventObjectSpecifier(desiredClass: Code.account, form: Code.byName, data: .string(name)))
    }

    /// `mailbox "All Mail" of mailbox "[Gmail]" of account "Google"`
    static func mailboxSpecifier(account: String, path: [String]) -> AppleEventValue {
        var specifier = accountSpecifier(account)
        for component in path {
            specifier = .object(AppleEventObjectSpecifier(
                desiredClass: Code.mailbox, container: specifier, form: Code.byName, data: .string(component)))
        }
        return specifier
    }

    /// `message id N of mailbox …`: the by-id reference, which Mail answers directly.
    static func messageSpecifier(_ target: Target) -> AppleEventValue {
        .object(AppleEventObjectSpecifier(
            desiredClass: Code.message, container: mailboxSpecifier(account: target.accountName, path: target.mailboxPath),
            form: Code.byID, data: .int(Int(target.rowid))))
    }

    static func propertySpecifier(_ code: AppleEventCode, of owner: AppleEventValue) -> AppleEventValue {
        .object(AppleEventObjectSpecifier(desiredClass: Code.property, container: owner, form: Code.property, data: .type(code)))
    }

    // MARK: Requests

    static func request(_ eventClass: AppleEventCode, _ eventID: AppleEventCode, _ parameters: [AppleEventField] = []) -> AppleEventRequest {
        AppleEventRequest(target: mailBundleID, eventClass: eventClass, eventID: eventID, parameters: parameters,
                          timeoutSeconds: timeoutSeconds)
    }

    /// Asks for the message's id: finds out whether Mail still has it there.
    static func lookup(_ target: Target) -> AppleEventRequest {
        request(Code.core, Code.getData, [AppleEventField(.directObject, propertySpecifier(Code.id, of: messageSpecifier(target)))])
    }

    /// `set <property> of <message> to <value>`
    static func set(_ code: AppleEventCode, of target: Target, to value: AppleEventValue) -> AppleEventRequest {
        request(Code.core, Code.setData, [
            AppleEventField(.directObject, propertySpecifier(code, of: messageSpecifier(target))),
            AppleEventField(Code.data, value),
        ])
    }

    /// `move <message> to <mailbox of the same account>`
    static func move(_ target: Target, to path: [String]) -> AppleEventRequest {
        request(Code.core, Code.move, [
            AppleEventField(.directObject, messageSpecifier(target)),
            AppleEventField(Code.insertHere, mailboxSpecifier(account: target.accountName, path: path)),
        ])
    }

    static func delete(_ target: Target) -> AppleEventRequest {
        request(Code.core, Code.delete, [AppleEventField(.directObject, messageSpecifier(target))])
    }

    /// `reply <message> opening window true [reply to all true]` and `forward <message> opening window true`.
    static func draft(_ kind: Draft, of target: Target) -> AppleEventRequest? {
        var parameters = [AppleEventField(.directObject, messageSpecifier(target)), AppleEventField(Code.openingWindow, .bool(true))]
        switch kind {
        case .reply: return request(Code.mailSuite, Code.reply, parameters)
        case .replyAll:
            parameters.append(AppleEventField(Code.replyToAll, .bool(true)))
            return request(Code.mailSuite, Code.reply, parameters)
        case .forward: return request(Code.mailSuite, Code.forward, parameters)
        case .new: return nil
        }
    }

    /// `make new outgoing message with properties {visible:true, subject:…, content:…}`
    static func newDraft(subject: String?, body: String?) -> AppleEventRequest {
        var fields = [AppleEventField(Code.visible, .bool(true))]
        if let subject { fields.append(AppleEventField(Code.subject, .string(subject))) }
        if let body { fields.append(AppleEventField(Code.content, .string(body))) }
        return request(Code.core, Code.create, [
            AppleEventField(Code.newClass, .type(Code.outgoingMessage)),
            AppleEventField(Code.properties, .record(fields)),
        ])
    }

    static func activate() -> AppleEventRequest { request(Code.misc, Code.activate) }

    /// Mail's `message://%3C<Message-ID>%3E` link, sent to Mail as a `GetURL` event (what opening the URL does).
    static func open(url: String) -> AppleEventRequest {
        request(Code.internet, Code.internet, [AppleEventField(.directObject, .string(url))])
    }

    /// `message://%3Cabc%40example.com%3E` for a Message-ID (with or without its angle brackets).
    static func messageURL(messageID: String) -> String? {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bracketed = trimmed.hasPrefix("<") && trimmed.hasSuffix(">") ? trimmed : "<\(trimmed)>"
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = bracketed.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return "message://\(encoded)"
    }

    // MARK: Errors (the codes the CLI printed: Mail42Error.code)

    static let automationDenied = MailFailure(
        code: "automation_denied",
        message: "macOS didn\u{2019}t let Work 42 control Mail. Open System Settings \u{203A} Privacy & Security \u{203A} Automation, "
            + "turn on Mail under Work 42, then try again.")
    static let mailTimeout = MailFailure(
        code: "mail_timeout",
        message: "Mail didn\u{2019}t answer in \(timeoutSeconds) seconds. The action may or may not have happened; check Mail before trying again.")
    static let mailNotRunning = MailFailure(code: "mail_not_running", message: "Mail isn\u{2019}t running. Open Mail, then try again.")
    static let notFound = MailFailure(
        code: "not_found", message: "Not found: that message in Mail (it may have moved or been deleted).")

    static func noArchiveMailbox(_ account: String) -> MailFailure {
        MailFailure(code: "no_archive_mailbox", message: "The account \(account) has no Archive mailbox to move the message to.")
    }

    static func actionFailed(_ text: String) -> MailFailure {
        MailFailure(code: "action_failed", message: "Mail couldn\u{2019}t do that: \(text)")
    }

    static func unsupported(_ what: String) -> MailFailure {
        MailFailure(code: "unsupported_by_automation", message: "Work 42\u{2019}s automation can\u{2019}t express \(what).")
    }

    /// What the host's own failure from `automation.send` means. Work42 names the three it knows (denied, not running,
    /// unanswered) in the error's text; `WidgetServiceError` has no stored code.
    static func failure(from error: any Error) -> MailFailure {
        if let failure = error as? MailFailure { return failure }
        if let permission = error as? PluginPermissionError {
            switch permission {
            case .notDeclared: return actionFailed("this plugin does not declare the automation permission")
            case .denied: return automationDenied
            @unknown default: return automationDenied
            }
        }
        let text = (error as? WidgetServiceError)?.message ?? error.localizedDescription
        if text.hasPrefix(PluginPermissionError.deniedPrefix) || text.hasPrefix(PluginPermissionError.notDeclaredPrefix)
            || text.hasPrefix(WidgetServiceError.notPermittedPrefix) || text.contains("has not allowed Work 42 to control") {
            return automationDenied
        }
        if text.contains("is not running") { return mailNotRunning }
        if text.contains("did not answer within") || text.contains("-1712") { return mailTimeout }
        return actionFailed(text)
    }

    /// What Mail's own refusal in a reply means (`NSAppleScriptErrorNumber` as the CLI mapped it, plus "can't get").
    static func failure(number: Int, message: String?, lookup: Bool) -> MailFailure {
        switch number {
        case -1743, -1744: return automationDenied
        case -1712: return mailTimeout
        case -600, -609, -10810: return mailNotRunning
        case -1728, -1719, -1700:
            return lookup ? notFound : actionFailed("\(message ?? "unknown error") (\(number))")
        default: return actionFailed("\(message ?? "unknown error") (\(number))")
        }
    }
}

// MARK: - The controller

extension MailAct {

    /// Sends Mail's actions through `services.automation`. Mail answers Apple Events one at a time, so the controller runs one
    /// action at a time, in the order they arrived (the CLI's `ActionQueue`, without the coalescing).
    final class Controller: Sendable {

        /// Finds what Mail needs to address the message with this row id (from `MailIndex`); throws `MailFailure` (`not_found`)
        /// when the index no longer has it.
        typealias Resolver = @Sendable (Int64) async throws -> Target

        private let automation: any WidgetAutomationService
        private let resolve: Resolver
        private let gate = Gate()

        init(automation: any WidgetAutomationService, resolver: @escaping Resolver) {
            self.automation = automation
            self.resolve = resolver
        }

        // MARK: State

        func mark(_ rowid: Int64, read: Bool) async throws -> MailActionResult {
            try await onMessage(rowid) { target in
                _ = try await self.send(MailAct.set(Code.readStatus, of: target, to: .bool(read)))
                return target.link
            }
        }

        /// Flags the message, with one of Mail's colours when given (its `flag index`).
        func flag(_ rowid: Int64, color: MailAct.FlagColor? = nil) async throws -> MailActionResult {
            try await onMessage(rowid) { target in
                _ = try await self.send(MailAct.set(Code.flaggedStatus, of: target, to: .bool(true)))
                if let color { _ = try await self.send(MailAct.set(Code.flagIndex, of: target, to: .int(color.index))) }
                return target.link
            }
        }

        func unflag(_ rowid: Int64) async throws -> MailActionResult {
            try await onMessage(rowid) { target in
                _ = try await self.send(MailAct.set(Code.flaggedStatus, of: target, to: .bool(false)))
                return target.link
            }
        }

        // MARK: Location

        /// Moves the message to another mailbox of its account (`path`, as `MailAct.path(ofMailboxNamed:)` gives it).
        func move(_ rowid: Int64, toMailbox path: [String]) async throws -> MailActionResult {
            try await onMessage(rowid) { target in
                _ = try await self.send(MailAct.move(target, to: path))
                return target.link
            }
        }

        /// Moves to the account's archive mailbox; `no_archive_mailbox` (and nothing sent to Mail) when there is none.
        func archive(_ rowid: Int64) async throws -> MailActionResult {
            let target = try await resolve(rowid)
            guard let path = target.archivePath else { throw MailAct.noArchiveMailbox(target.accountName) }
            return try await onMessage(rowid, target: target) { target in
                _ = try await self.send(MailAct.move(target, to: path))
                return target.link
            }
        }

        /// Deletes: Mail moves the message to the account's Trash (or marks it deleted, as the account does).
        func delete(_ rowid: Int64) async throws -> MailActionResult {
            try await onMessage(rowid) { target in
                _ = try await self.send(MailAct.delete(target))
                return target.link
            }
        }

        /// Marks the message as junk and, when the account's junk mailbox is known, moves it there.
        func junk(_ rowid: Int64) async throws -> MailActionResult {
            try await onMessage(rowid) { target in
                _ = try await self.send(MailAct.set(Code.junkStatus, of: target, to: .bool(true)))
                if let path = target.junkPath { _ = try await self.send(MailAct.move(target, to: path)) }
                return target.link
            }
        }

        // MARK: Drafts (Mail's own compose window; never sent)

        /// `.new` needs no message (`rowid` is ignored); the others open a draft of that message.
        func draft(_ kind: Draft, of rowid: Int64? = nil) async throws -> MailActionResult {
            if case .new(let to, let cc, let subject, let body) = kind {
                guard to.isEmpty, cc.isEmpty else { throw MailAct.unsupported("recipients on a new message (an insertion location)") }
                return try await gate.run {
                    _ = try await self.send(MailAct.newDraft(subject: subject, body: body))
                    _ = try await self.send(MailAct.activate())
                    return MailActionResult(ok: true, link: nil)
                }
            }
            guard let rowid else { throw MailAct.notFound }
            return try await onMessage(rowid) { target in
                guard let request = MailAct.draft(kind, of: target) else { return nil }
                _ = try await self.send(request)
                _ = try await self.send(MailAct.activate())
                return target.link
            }
        }

        // MARK: Open

        /// Shows the message in Mail: its `message://` link, which needs the Message-ID (`no_message_id` without one).
        func open(_ rowid: Int64) async throws -> MailActionResult {
            let target = try await resolve(rowid)
            guard let messageID = target.messageID, let url = MailAct.messageURL(messageID: messageID) else {
                throw MailFailure(code: "no_message_id", message: "Message \(rowid) has no Message-ID, so it can\u{2019}t be opened in Mail.")
            }
            return try await gate.run {
                _ = try await self.send(MailAct.open(url: url))
                return MailActionResult(ok: true, link: target.link)
            }
        }

        // MARK: Plumbing

        /// Finds the message, asks Mail whether it still has it there, then runs `body` (all inside the one-at-a-time gate).
        private func onMessage(
            _ rowid: Int64, target known: Target? = nil, _ body: @escaping @Sendable (Target) async throws -> String?
        ) async throws -> MailActionResult {
            let target: Target
            if let known { target = known } else { target = try await resolve(rowid) }
            return try await gate.run {
                _ = try await self.send(MailAct.lookup(target), lookup: true)
                let link = try await body(target)
                return MailActionResult(ok: true, link: link)
            }
        }

        /// One event to Mail; its own refusal (an error number in the reply) and the host's failure both become a `MailFailure`.
        private func send(_ request: AppleEventRequest, lookup: Bool = false) async throws -> AppleEventReply {
            let reply: AppleEventReply
            do { reply = try await automation.send(request) } catch { throw MailAct.failure(from: error) }
            if let number = reply.errorNumber, number != 0 {
                throw MailAct.failure(number: number, message: reply.errorMessage, lookup: lookup)
            }
            return reply
        }
    }

    /// Mail's seven flag colours, in the order of its `flag index`.
    enum FlagColor: String, CaseIterable, Sendable {
        case red, orange, yellow, green, blue, purple, gray

        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// Lets one action run at a time, in the order they asked.
    actor Gate {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
            if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
            defer { release() }
            return try await work()
        }

        private func release() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
    }
}
