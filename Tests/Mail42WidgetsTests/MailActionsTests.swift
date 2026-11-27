// MailActionsTests.swift — Mail's actions as typed Apple Events: the exact requests each verb sends to com.apple.mail, how
// failures are named, and that nothing is sent twice.

import Foundation
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

/// Records every request and answers from `handler` (an empty reply by default).
nonisolated final class FakeAutomation: WidgetAutomationService, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [AppleEventRequest] = []
    private var inFlight = 0
    private var peak = 0
    private let delay: Duration?
    private let handler: @Sendable (AppleEventRequest) throws -> AppleEventReply

    init(delay: Duration? = nil, handler: @escaping @Sendable (AppleEventRequest) throws -> AppleEventReply = { _ in AppleEventReply() }) {
        self.delay = delay
        self.handler = handler
    }

    var requests: [AppleEventRequest] { lock.withLock { log } }
    var peakConcurrency: Int { lock.withLock { peak } }

    func send(_ request: AppleEventRequest) async throws -> AppleEventReply {
        lock.withLock {
            log.append(request)
            inFlight += 1
            peak = max(peak, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if let delay { try await Task.sleep(for: delay) }
        return try handler(request)
    }
}

@Suite struct MailActionsTests {

    static let inbox = MailAct.Target(
        accountName: "Google", mailboxPath: ["INBOX"], rowid: 48213, messageID: "CAF7x9Q@mail.gmail.com",
        link: "mail42://message/48213?mid=CAF7x9Q%40mail.gmail.com",
        archivePath: ["[Gmail]", "All Mail"], junkPath: ["[Gmail]", "Spam"])

    // Written out by hand, not with MailAct's own helpers, so a mistake in them cannot hide here.
    static let account: AppleEventValue = .object(.init(desiredClass: "mact", form: "name", data: .string("Google")))
    static let inboxBox: AppleEventValue = .object(.init(desiredClass: "mbxp", container: account, form: "name", data: .string("INBOX")))
    static let message: AppleEventValue = .object(.init(desiredClass: "mssg", container: inboxBox, form: "ID  ", data: .int(48213)))

    static func property(_ code: AppleEventCode) -> AppleEventValue {
        .object(.init(desiredClass: "prop", container: message, form: "prop", data: .type(code)))
    }

    static func allMail() -> AppleEventValue {
        let gmail: AppleEventValue = .object(.init(desiredClass: "mbxp", container: account, form: "name", data: .string("[Gmail]")))
        return .object(.init(desiredClass: "mbxp", container: gmail, form: "name", data: .string("All Mail")))
    }

    static func spam() -> AppleEventValue {
        let gmail: AppleEventValue = .object(.init(desiredClass: "mbxp", container: account, form: "name", data: .string("[Gmail]")))
        return .object(.init(desiredClass: "mbxp", container: gmail, form: "name", data: .string("Spam")))
    }

    static func request(_ eventClass: AppleEventCode, _ eventID: AppleEventCode, _ parameters: [AppleEventField] = []) -> AppleEventRequest {
        AppleEventRequest(target: "com.apple.mail", eventClass: eventClass, eventID: eventID, parameters: parameters, timeoutSeconds: 20)
    }

    static let lookup = request("core", "getd", [.init(.directObject, property("ID  "))])
    static let activate = request("misc", "actv")

    static func set(_ code: AppleEventCode, _ value: AppleEventValue) -> AppleEventRequest {
        request("core", "setd", [.init(.directObject, property(code)), .init("data", value)])
    }

    /// A controller over a fake Mail; the resolver knows only row 48213.
    func controller(_ fake: FakeAutomation, target: MailAct.Target = inbox) -> MailAct.Controller {
        MailAct.Controller(automation: fake) { rowid in
            guard rowid == target.rowid else { throw MailFailure(code: "not_found", message: "no such message") }
            return target
        }
    }

    // MARK: Verbs

    @Test func markReadSetsReadStatusAfterLookingTheMessageUp() async throws {
        let fake = FakeAutomation()
        let result = try await controller(fake).mark(48213, read: true)
        #expect(fake.requests == [Self.lookup, Self.set("isrd", .bool(true))])
        #expect(result.ok)
        #expect(result.link == Self.inbox.link)
    }

    @Test func markUnreadSetsReadStatusFalse() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).mark(48213, read: false)
        #expect(fake.requests == [Self.lookup, Self.set("isrd", .bool(false))])
    }

    @Test func flagWithoutAColourOnlySetsTheFlag() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).flag(48213)
        #expect(fake.requests == [Self.lookup, Self.set("isfl", .bool(true))])
    }

    @Test func flagWithAColourSetsTheFlagIndexToo() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).flag(48213, color: .blue)
        #expect(fake.requests == [Self.lookup, Self.set("isfl", .bool(true)), Self.set("fidx", .int(4))])
    }

    @Test func flagColoursFollowMailsFlagIndex() {
        #expect(MailAct.FlagColor.allCases.map(\.index) == [0, 1, 2, 3, 4, 5, 6])
        #expect(MailAct.FlagColor.red.index == 0 && MailAct.FlagColor.gray.index == 6)
    }

    @Test func unflagClearsTheFlag() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).unflag(48213)
        #expect(fake.requests == [Self.lookup, Self.set("isfl", .bool(false))])
    }

    @Test func moveSendsTheMessageAndTheDestinationMailbox() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).move(48213, toMailbox: ["[Gmail]", "All Mail"])
        #expect(fake.requests == [
            Self.lookup,
            Self.request("core", "move", [.init(.directObject, Self.message), .init("insh", Self.allMail())]),
        ])
    }

    @Test func archiveMovesToTheAccountsArchiveMailbox() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).archive(48213)
        #expect(fake.requests == [
            Self.lookup,
            Self.request("core", "move", [.init(.directObject, Self.message), .init("insh", Self.allMail())]),
        ])
    }

    @Test func archiveWithoutAnArchiveMailboxSendsNothing() async {
        var target = Self.inbox
        target.archivePath = nil
        let fake = FakeAutomation()
        await #expect(throws: MailFailure.self) { _ = try await controller(fake, target: target).archive(48213) }
        #expect(fake.requests.isEmpty)
        do { _ = try await controller(fake, target: target).archive(48213) } catch let failure as MailFailure {
            #expect(failure.code == "no_archive_mailbox")
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func deleteSendsTheCoreDeleteEvent() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).delete(48213)
        #expect(fake.requests == [Self.lookup, Self.request("core", "delo", [.init(.directObject, Self.message)])])
    }

    @Test func junkMarksTheMessageThenMovesItToTheJunkMailbox() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).junk(48213)
        #expect(fake.requests == [
            Self.lookup,
            Self.set("isjk", .bool(true)),
            Self.request("core", "move", [.init(.directObject, Self.message), .init("insh", Self.spam())]),
        ])
    }

    @Test func junkWithoutAJunkMailboxOnlyMarksIt() async throws {
        var target = Self.inbox
        target.junkPath = nil
        let fake = FakeAutomation()
        _ = try await controller(fake, target: target).junk(48213)
        #expect(fake.requests == [Self.lookup, Self.set("isjk", .bool(true))])
    }

    @Test func replyOpensTheWindowAndActivatesMail() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).draft(.reply, of: 48213)
        #expect(fake.requests == [
            Self.lookup,
            Self.request("emal", "rpms", [.init(.directObject, Self.message), .init("ropw", .bool(true))]),
            Self.activate,
        ])
    }

    @Test func replyAllAddsReplyToAll() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).draft(.replyAll, of: 48213)
        #expect(fake.requests == [
            Self.lookup,
            Self.request("emal", "rpms", [.init(.directObject, Self.message), .init("ropw", .bool(true)), .init("rpal", .bool(true))]),
            Self.activate,
        ])
    }

    @Test func forwardOpensTheWindowAndActivatesMail() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).draft(.forward, of: 48213)
        #expect(fake.requests == [
            Self.lookup,
            Self.request("emal", "fwms", [.init(.directObject, Self.message), .init("ropw", .bool(true))]),
            Self.activate,
        ])
    }

    @Test func newDraftMakesAVisibleOutgoingMessage() async throws {
        let fake = FakeAutomation()
        let result = try await controller(fake).draft(.new(subject: "Hello", body: "Hi there"))
        #expect(fake.requests == [
            Self.request("core", "crel", [
                .init("kocl", .type("bcke")),
                .init("prdt", .record([.init("pvis", .bool(true)), .init("subj", .string("Hello")), .init("ctnt", .string("Hi there"))])),
            ]),
            Self.activate,
        ])
        #expect(result.ok && result.link == nil)
    }

    @Test func emptyNewDraftOnlyAsksForAVisibleWindow() async throws {
        let fake = FakeAutomation()
        _ = try await controller(fake).draft(.new())
        #expect(fake.requests == [
            Self.request("core", "crel", [.init("kocl", .type("bcke")), .init("prdt", .record([.init("pvis", .bool(true))]))]),
            Self.activate,
        ])
    }

    @Test func newDraftWithRecipientsIsNotExpressible() async {
        let fake = FakeAutomation()
        do {
            _ = try await controller(fake).draft(.new(to: ["a@example.com"]))
            Issue.record("expected a failure")
        } catch let failure as MailFailure {
            #expect(failure.code == "unsupported_by_automation")
        } catch { Issue.record("unexpected \(error)") }
        #expect(fake.requests.isEmpty)
    }

    @Test func openSendsMailsMessageLinkAsAGetURLEvent() async throws {
        let fake = FakeAutomation()
        let result = try await controller(fake).open(48213)
        #expect(fake.requests == [Self.request("GURL", "GURL", [.init(.directObject, .string("message://%3CCAF7x9Q%40mail.gmail.com%3E"))])])
        #expect(result.link == Self.inbox.link)
    }

    @Test func openNeedsAMessageID() async {
        var target = Self.inbox
        target.messageID = nil
        let fake = FakeAutomation()
        do {
            _ = try await controller(fake, target: target).open(48213)
            Issue.record("expected a failure")
        } catch let failure as MailFailure {
            #expect(failure.code == "no_message_id")
        } catch { Issue.record("unexpected \(error)") }
        #expect(fake.requests.isEmpty)
    }

    @Test func messageURLKeepsExistingBrackets() {
        #expect(MailAct.messageURL(messageID: "<a@b.c>") == "message://%3Ca%40b.c%3E")
        #expect(MailAct.messageURL(messageID: "  ") == nil)
    }

    @Test func everyRequestTargetsMailWithAnActionTimeout() async throws {
        let fake = FakeAutomation()
        let mail = controller(fake)
        _ = try await mail.mark(48213, read: true)
        _ = try await mail.draft(.new())
        _ = try await mail.junk(48213)
        #expect(!fake.requests.isEmpty)
        #expect(fake.requests.allSatisfy { $0.target == "com.apple.mail" && $0.timeoutSeconds == 20 })
    }

    // MARK: Which mailbox

    @Test func archiveMailboxPrefersGmailsAndNeedsTheArchiveRole() {
        let boxes = [
            MailMailboxRef(id: 1, name: "Archive", role: "archive"),
            MailMailboxRef(id: 2, name: "[Gmail]/All Mail", role: "archive"),
            MailMailboxRef(id: 3, name: "[Gmail]/Spam", role: "junk"),
            MailMailboxRef(id: 4, name: "INBOX", role: "inbox"),
        ]
        #expect(MailAct.archivePath(in: boxes) == ["[Gmail]", "All Mail"])
        #expect(MailAct.junkPath(in: boxes) == ["[Gmail]", "Spam"])
        #expect(MailAct.archivePath(in: [boxes[3]]) == nil)
        #expect(MailAct.junkPath(in: [boxes[3]]) == nil)
    }

    // MARK: Errors

    private func failure(_ fake: FakeAutomation, _ work: (MailAct.Controller) async throws -> MailActionResult) async -> MailFailure? {
        do { _ = try await work(controller(fake)); return nil } catch let failure as MailFailure { return failure } catch { return MailFailure(code: "other", message: "\(error)") }
    }

    @Test func aDeclinedPermissionIsAutomationDenied() async {
        let refusals: [any Error] = [
            WidgetServiceError.notPermitted("automation for com.apple.mail"),
            WidgetServiceError(message: PluginPermissionError.deniedPrefix + "automation: macOS has not allowed Work 42 to control com.apple.mail."),
            WidgetServiceError(message: PluginPermissionError.notDeclaredPrefix + "automation"),
            WidgetServiceError(message: "macOS has not allowed Work 42 to control com.apple.mail. Turn it on in System Settings"),
        ]
        for refusal in refusals {
            let fake = FakeAutomation { _ in throw refusal }
            let said = await failure(fake) { try await $0.mark(48213, read: true) }
            #expect(said?.code == "automation_denied")
            #expect(fake.requests.count == 1)
        }
    }

    @Test func macOSsOwnDenialInAReplyIsAutomationDenied() async {
        let fake = FakeAutomation { _ in AppleEventReply(errorNumber: -1743, errorMessage: "Not authorized") }
        let said = await failure(fake) { try await $0.delete(48213) }
        #expect(said?.code == "automation_denied")
    }

    @Test func mailNotRunningIsNamed() async {
        let fake = FakeAutomation { _ in
            throw WidgetServiceError(message: "com.apple.mail is not running (Apple Event error -600)", suggestion: "open the app first")
        }
        let said = await failure(fake) { try await $0.archive(48213) }
        #expect(said?.code == "mail_not_running")
        #expect(fake.requests.count == 1)
    }

    @Test func aTimeoutIsMailTimeoutAndIsNotRetried() async {
        let fake = FakeAutomation { _ in
            throw WidgetServiceError(message: "com.apple.mail did not answer within 20 s (Apple Event error -1712)")
        }
        let said = await failure(fake) { try await $0.move(48213, toMailbox: ["Archive"]) }
        #expect(said?.code == "mail_timeout")
        #expect(fake.requests.count == 1)
    }

    @Test func aMessageMailCannotGetIsNotFoundAndTheActionIsNeverSent() async {
        let fake = FakeAutomation { _ in AppleEventReply(errorNumber: -1728, errorMessage: "Can’t get message id 48213") }
        let said = await failure(fake) { try await $0.delete(48213) }
        #expect(said?.code == "not_found")
        #expect(fake.requests == [Self.lookup])
    }

    @Test func aRowTheIndexNoLongerHasIsNotFoundWithoutAskingMail() async {
        let fake = FakeAutomation()
        let said = await failure(fake) { try await $0.mark(999, read: true) }
        #expect(said?.code == "not_found")
        #expect(fake.requests.isEmpty)
    }

    @Test func mailsOwnRefusalOfTheActionIsActionFailed() async {
        let fake = FakeAutomation { request in
            request.eventID == "delo" ? AppleEventReply(errorNumber: -10000, errorMessage: "Handler failed") : AppleEventReply()
        }
        let said = await failure(fake) { try await $0.delete(48213) }
        #expect(said?.code == "action_failed")
        #expect(said?.message.contains("Handler failed (-10000)") == true)
        #expect(fake.requests.count == 2)
    }

    @Test func aFailedFirstStepStopsTheSequence() async {
        let fake = FakeAutomation { request in
            request.eventID == "setd" ? AppleEventReply(errorNumber: -10000, errorMessage: "no") : AppleEventReply()
        }
        let said = await failure(fake) { try await $0.junk(48213) }
        #expect(said?.code == "action_failed")
        #expect(fake.requests == [Self.lookup, Self.set("isjk", .bool(true))])
    }

    @Test func aHostWithoutAutomationFailsTheAction() async {
        let said = await failure(FakeAutomation { _ in throw WidgetServiceError.hostLacks("automation.send(_:)") }) {
            try await $0.unflag(48213)
        }
        #expect(said?.code == "action_failed")
    }

    // MARK: Order and repeats

    @Test func concurrentActionsReachMailOneAtATimeInOrderAndEachOnce() async throws {
        let fake = FakeAutomation(delay: .milliseconds(20))
        let mail = controller(fake)
        async let first = mail.mark(48213, read: true)
        try await Task.sleep(for: .milliseconds(5))
        async let second = mail.unflag(48213)
        try await Task.sleep(for: .milliseconds(5))
        async let third = mail.delete(48213)
        _ = try await (first, second, third)
        #expect(fake.peakConcurrency == 1)
        #expect(fake.requests == [
            Self.lookup, Self.set("isrd", .bool(true)),
            Self.lookup, Self.set("isfl", .bool(false)),
            Self.lookup, Self.request("core", "delo", [.init(.directObject, Self.message)]),
        ])
    }

    @Test func aFailureReleasesTheGateForTheNextAction() async throws {
        let calls = Counter()
        let fake = FakeAutomation { _ in
            if calls.next() == 1 { throw WidgetServiceError(message: "com.apple.mail is not running (Apple Event error -600)") }
            return AppleEventReply()
        }
        let mail = controller(fake)
        await #expect(throws: MailFailure.self) { _ = try await mail.mark(48213, read: true) }
        _ = try await mail.mark(48213, read: false)
        #expect(fake.requests == [Self.lookup, Self.lookup, Self.set("isrd", .bool(false))])
    }
}

nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
