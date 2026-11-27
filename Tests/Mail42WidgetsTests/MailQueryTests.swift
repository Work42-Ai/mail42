// MailQueryTests.swift — the search language (parser and SQL compiler) ported out of the `mail42` command line (WOR-900).
// Ported from Mail42KitTests/QueryParserTests, plus what the compiler promises (SQL shape, parameters, text terms, dates).

import Foundation
import Testing
@testable import Mail42MailWidget

@Suite("Mail query parser")
struct MailQueryParserTests {

    /// A compact, position-free rendering of the parse tree, e.g. `and(from:alice,is:unread)`.
    private func shape(_ node: MailQueryNode) -> String {
        switch node {
        case .term(let field, let value, _): return (field.map { "\($0.rawValue):" } ?? "") + value
        case .not(let inner): return "not(\(shape(inner)))"
        case .and(let a, let b): return "and(\(shape(a)),\(shape(b)))"
        case .or(let a, let b): return "or(\(shape(a)),\(shape(b)))"
        }
    }

    private func parse(_ query: String) throws -> String { shape(try MailQueryParser.parse(query)) }

    private func failure(_ query: String) -> (message: String, position: Int)? {
        do { _ = try MailQueryParser.parse(query); return nil } catch let error as MailQueryError {
            return (error.message, error.position)
        } catch { return nil }
    }

    // MARK: Valid queries

    @Test("every field and the implicit AND")
    func fieldsAndImplicitAnd() throws {
        #expect(try parse("from:alice is:unread") == "and(from:alice,is:unread)")
        #expect(try parse("to:bo cc") == "and(to:bo,cc)")
        #expect(try parse("subject:\"q4 roadmap\" or body:invoice") == "or(subject:q4 roadmap,body:invoice)")
        #expect(try parse("not in:Sent date:2w..") == "and(not(in:Sent),date:2w..)")
        #expect(try parse("has:attachment date:2026-10-01..2026-10-15") == "and(has:attachment,date:2026-10-01..2026-10-15)")
        #expect(try parse("invoice") == "invoice")
        #expect(try parse("\"exact phrase\"") == "exact phrase")
    }

    @Test("or binds looser than and, and not binds tightest")
    func precedence() throws {
        #expect(try parse("a or b c") == "or(a,and(b,c))")
        #expect(try parse("a b or c") == "or(and(a,b),c)")
        #expect(try parse("a and b or c and d") == "or(and(a,b),and(c,d))")
        #expect(try parse("not a b") == "and(not(a),b)")
        #expect(try parse("not not a") == "not(not(a))")
        #expect(try parse("a or b or c") == "or(or(a,b),c)")
        #expect(try parse("(a or b) c") == "and(or(a,b),c)")
        #expect(try parse("not (a or b)") == "not(or(a,b))")
        #expect(try parse("((a))") == "a")
        #expect(try parse("a(b)") == "and(a,b)")
    }

    @Test("keywords and field names are case-insensitive")
    func caseInsensitive() throws {
        #expect(try parse("A AND b OR NOT c") == "or(and(A,b),not(c))")
        #expect(try parse("FROM:Alice Is:Unread") == "and(from:Alice,is:Unread)")
    }

    @Test("quoted keywords and field-like words are just text")
    func quotedAreText() throws {
        #expect(try parse("\"or\"") == "or")
        #expect(try parse("\"not\" \"and\"") == "and(not,and)")
        #expect(try parse("\"from:alice\"") == "from:alice")
        #expect(try parse("https://example.com/x") == "https://example.com/x")     // unknown prefix: a word
        #expect(try parse("foo:bar") == "foo:bar")
        #expect(try parse("12:30") == "12:30")
        #expect(try parse("orange nothing android") == "and(and(orange,nothing),android)")   // keywords only as whole words
    }

    @Test("escapes and unicode")
    func escapesAndUnicode() throws {
        #expect(try parse(#"subject:"say \"hi\"""#) == #"subject:say "hi""#)
        #expect(try parse(#""back\\slash""#) == #"back\slash"#)
        #expect(try parse("from:josé café") == "and(from:josé,café)")
        #expect(try parse("  spaced   out  ") == "and(spaced,out)")
        #expect(try parse("日本語") == "日本語")
    }

    @Test("field values stop at parentheses and whitespace")
    func valuesStop() throws {
        #expect(try parse("(from:alice)") == "from:alice")
        #expect(try parse("(is:unread or is:flagged) from:bo") == "and(or(is:unread,is:flagged),from:bo)")
        #expect(try parse("date:2w..") == "date:2w..")
        #expect(try parse("date:..2026-10-15") == "date:..2026-10-15")
    }

    @Test("each term records where it starts")
    func positions() throws {
        guard case .and(.term(_, _, let first), .term(_, _, let second)) = try MailQueryParser.parse("from:a  is:unread") else {
            Issue.record("unexpected shape"); return
        }
        #expect(first == 0 && second == 8)
    }

    // MARK: Errors, with positions

    @Test("an empty query is rejected")
    func empty() {
        #expect(failure("")?.message.contains("empty") == true)
        #expect(failure("   ")?.message.contains("empty") == true)
    }

    @Test("a field with no value is rejected")
    func fieldWithoutValue() {
        let f = failure("from:")
        #expect(f?.position == 0 && f?.message.contains("from:") == true)
        #expect(failure("is:unread to:")?.position == 10)
        #expect(failure("subject:\"\"")?.message.contains("subject:") == true)
    }

    @Test("unclosed quotes are rejected")
    func unclosedQuotes() {
        #expect(failure("\"never closed")?.position == 0)
        #expect(failure("a subject:\"open")?.position == 10)
        #expect(failure("\"ends with backslash\\")?.message.contains("quote") == true)
    }

    @Test("unbalanced parentheses are rejected")
    func unbalanced() {
        #expect(failure("(a or b")?.position == 0)
        #expect(failure("a)")?.position == 1)
        #expect(failure("a ) b")?.position == 2)
        #expect(failure("()")?.position == 1 || failure("()")?.position == 0)
        #expect(failure("(a (b)")?.message.contains("`)`") == true)
    }

    @Test("operators without operands are rejected")
    func operatorsWithoutOperands() {
        #expect(failure("a or")?.position == 4 && failure("a or")?.message.contains("or") == true)
        #expect(failure("a and")?.message.contains("and") == true)
        #expect(failure("not")?.message.contains("not") == true)
        #expect(failure("or a")?.position == 0)
        #expect(failure("and a")?.position == 0)
        #expect(failure("a or or b") != nil)
        #expect(failure("a or )") != nil)
    }

    @Test("an error is a bad_query failure worded like the CLI's")
    func failureWording() {
        let error = MailQueryError.bad("unclosed quote", position: 3)
        #expect(error.failure == MailFailure(code: "bad_query", message: "Bad query at position 3: unclosed quote"))
        #expect(MailQueryError.code == "bad_query")
    }
}

@Suite("Mail query compiler")
struct MailQueryCompilerTests {

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// 2026-11-26 12:00 UTC.
    private static let now = date(2026, 11, 26, 12)

    private func compiler(
        mailboxes: @escaping @Sendable (String) -> [Int64] = { _ in [] }, matches: [String: Set<Int64>]? = nil,
        summaries: Bool = false
    ) -> MailQueryCompiler {
        MailQueryCompiler(now: Self.now, calendar: Self.utc, mailboxIDs: mailboxes, textMatches: matches, summaries: summaries)
    }

    private func compile(_ query: String, summaries: Bool = false) throws -> MailQueryCompiled {
        try compiler(summaries: summaries).compile(query)
    }

    private func render(_ params: [MailSQLValue]) -> [String] {
        params.map {
            switch $0 {
            case .null: return "null"
            case .int(let value): return "i:\(value)"
            case .text(let value): return "t:\(value)"
            }
        }
    }

    private func epoch(_ date: Date) -> String { "i:\(Int64(date.timeIntervalSince1970))" }

    private func badQuery(_ query: String) -> MailQueryError? {
        do { _ = try compile(query); return nil } catch let error as MailQueryError { return error } catch { return nil }
    }

    // MARK: Fields

    @Test("from matches the address or the name, to matches To and Cc only; both through parameters")
    func senderAndRecipient() throws {
        let from = try compile("from:alice")
        #expect(from.whereSQL == "(COALESCE(a.address, '') LIKE ? ESCAPE '\\' OR COALESCE(a.comment, '') LIKE ? ESCAPE '\\')")
        #expect(render(from.params) == ["t:%alice%", "t:%alice%"])
        let to = try compile("to:bo")
        #expect(to.whereSQL.contains("r.type IN (0, 1)") && !to.whereSQL.contains("2"))
        #expect(render(to.params) == ["t:%bo%", "t:%bo%"])
        #expect(try compile("subject:\"q4 roadmap\"").whereSQL == "COALESCE(s.subject, '') LIKE ? ESCAPE '\\'")
        #expect(render(try compile("subject:\"q4 roadmap\"").params) == ["t:%q4 roadmap%"])
    }

    @Test("LIKE wildcards in the user's text are escaped, and text never enters the SQL")
    func escaping() throws {
        let compiled = try compile("subject:\"50%_off\\\\\"")
        #expect(render(compiled.params) == ["t:%50\\%\\_off\\\\%"])
        let hostile = try compile("from:\"x' OR 1=1 --\"")
        #expect(!hostile.whereSQL.contains("1=1") && render(hostile.params) == ["t:%x' OR 1=1 --%", "t:%x' OR 1=1 --%"])
        #expect(MailQueryCompiler.escapeLike("a%b_c\\d") == "a\\%b\\_c\\\\d")
    }

    @Test("is: and has: terms")
    func stateTerms() throws {
        #expect(try compile("is:unread").whereSQL == "m.read = 0")
        #expect(try compile("IS:Read").whereSQL == "m.read = 1")
        #expect(try compile("is:flagged").whereSQL == "m.flagged = 1")
        #expect(try compile("has:attachment").whereSQL.contains("FROM attachments att"))
        #expect(try compile("has:ATTACHMENT").params.isEmpty)
    }

    @Test("in: resolves mailboxes through the lookup; an unknown mailbox matches nothing")
    func inTerm() throws {
        let known = try compiler(mailboxes: { $0 == "inbox" ? [1, 7] : [] }).compile("in:inbox")
        #expect(known.whereSQL.contains("m.mailbox IN (1,7)") && known.whereSQL.contains("l.mailbox_id IN (1,7)"))
        #expect(try compiler().compile("in:nowhere").whereSQL == "0")
    }

    @Test("boolean structure becomes parenthesised AND, OR and NOT")
    func structure() throws {
        #expect(try compile("is:unread is:flagged").whereSQL == "(m.read = 0 AND m.flagged = 1)")
        #expect(try compile("is:unread or is:flagged").whereSQL == "(m.read = 0 OR m.flagged = 1)")
        #expect(try compile("not is:unread").whereSQL == "(NOT m.read = 0)")
    }

    // MARK: Words and text

    @Test("a plain word looks at subject, sender, recipients and the text; the preview line when the index has one")
    func plainWord() throws {
        let plain = try compile("invoice")
        #expect(plain.textTerms == ["invoice"] && !plain.hasNegatedText)
        #expect(plain.whereSQL.hasPrefix("(COALESCE(s.subject, '') LIKE") && plain.whereSQL.hasSuffix("OR 1)"))   // relaxed text test: true
        #expect(!plain.whereSQL.contains("sm.summary") && plain.params.count == 5)
        let withPreview = try compile("invoice", summaries: true)
        #expect(withPreview.whereSQL.contains("COALESCE(sm.summary, '') LIKE ?") && withPreview.params.count == 6)
    }

    @Test("body: is text only, and terms are listed once, in order")
    func bodyAndTerms() throws {
        let compiled = try compile("body:foo bar body:foo \"two words\"")
        #expect(compiled.textTerms == ["foo", "bar", "two words"])
        #expect(try compile("body:foo").whereSQL == "1")
        #expect(try compile("from:a is:unread").textTerms.isEmpty)
    }

    @Test("a word under not is flagged, and its relaxed test can't exclude anything")
    func negatedText() throws {
        let negated = try compile("not body:foo")
        #expect(negated.hasNegatedText && negated.whereSQL == "(NOT 0)")
        #expect(try compile("not foo").hasNegatedText)
        #expect(try compile("not (is:unread or foo)").hasNegatedText)
        #expect(try compile("not from:foo").hasNegatedText == false)
        #expect(try compile("not not body:foo").hasNegatedText == false)       // two negations: positive again
        #expect(try compile("not body:foo").textTerms == ["foo"])
    }

    @Test("with the scan's matches each text test becomes an id list; none found means false")
    func realForm() throws {
        let found = try compiler(matches: ["foo": [5]]).compile("body:foo")
        #expect(found.whereSQL == "m.ROWID IN (5)")
        #expect(try compiler(matches: [:]).compile("body:foo").whereSQL == "0")
        #expect(try compiler(matches: ["foo": []]).compile("not body:foo").whereSQL == "(NOT 0)")
    }

    // MARK: Dates

    @Test("relative dates count back from now; `2w` means `2w..`")
    func relativeDates() throws {
        let twoWeeks = try compile("date:2w..")
        #expect(twoWeeks.whereSQL == "(m.date_received >= ?)")
        #expect(render(twoWeeks.params) == [epoch(Self.date(2026, 11, 12, 12))])
        #expect(render(try compile("date:2W").params) == [epoch(Self.date(2026, 11, 12, 12))])
        #expect(render(try compile("date:3d..").params) == [epoch(Self.date(2026, 11, 23, 12))])
        #expect(render(try compile("date:1m..").params) == [epoch(Self.date(2026, 10, 26, 12))])
    }

    @Test("absolute ranges include the whole last day; one day is a one-day range")
    func absoluteDates() throws {
        let range = try compile("date:2026-10-01..2026-10-15")
        #expect(range.whereSQL == "(m.date_received >= ? AND m.date_received < ?)")
        #expect(render(range.params) == [epoch(Self.date(2026, 10, 1)), epoch(Self.date(2026, 10, 16))])
        #expect(render(try compile("date:2026-10-01..").params) == [epoch(Self.date(2026, 10, 1))])
        let until = try compile("date:..2026-10-15")
        #expect(until.whereSQL == "(m.date_received < ?)" && render(until.params) == [epoch(Self.date(2026, 10, 16))])
        #expect(render(try compile("date:2026-10-15").params) == [epoch(Self.date(2026, 10, 15)), epoch(Self.date(2026, 10, 16))])
        #expect(render(try compile("date:..2026-12-31").params) == [epoch(Self.date(2027, 1, 1))])
        #expect(render(try compile("date:2w..1d").params).count == 2)
    }

    @Test("relative dates that overflow, do not fit an Int or reach past 10,000 years are a bad query, never a trap or a zero")
    func relativeDatesOutOfRange() throws {
        for query in [
            "date:9223372036854775807w",                        // `* 7` would overflow
            "date:1317624576693539402w",                        // just past Int.max / 7
            "date:9223372036854775807d", "date:9223372036854775807m",
            "date:9223372036854775808d",                        // one past Int.max: used to read as 0
            "date:99999999999999999999999999d", "date:99999999999999999999999999w..", "date:..99999999999999999999m",
            "date:521786w", "date:3652501d", "date:120001m",   // just past 10,000 years
        ] {
            let error = badQuery(query)
            #expect(error?.message.contains("out of range") == true, "\(query) was \(String(describing: error))")
        }
        // The edge itself still works.
        #expect(badQuery("date:3652500d") == nil)
        #expect(badQuery("date:120000m") == nil)
        #expect(badQuery("date:521785w") == nil)
        #expect(badQuery("date:0d") == nil)
    }

    @Test("`in:` also matches a Gmail label only when the index has a labels table")
    func inWithAndWithoutLabels() throws {
        let boxes: @Sendable (String) -> [Int64] = { _ in [1, 2] }
        let with = try MailQueryCompiler(now: Self.now, calendar: Self.utc, mailboxIDs: boxes).compile("in:inbox")
        #expect(with.whereSQL.contains("FROM labels"))
        let without = try MailQueryCompiler(now: Self.now, calendar: Self.utc, mailboxIDs: boxes, labels: false).compile("in:inbox")
        #expect(without.whereSQL == "m.mailbox IN (1,2)")
    }

    // MARK: Errors

    @Test("an invalid value is a bad query that points at the term")
    func invalidValues() {
        #expect(badQuery("is:maybe")?.position == 0 && badQuery("is:maybe")?.message.contains("unread, read or flagged") == true)
        #expect(badQuery("from:a has:photo")?.position == 7)
        #expect(badQuery("has:photo")?.message.contains("attachment") == true)
        #expect(badQuery("date:yesterday")?.message.contains("is not a date") == true)
        #expect(badQuery("date:..")?.message.contains("needs a start or an end") == true)
        #expect(badQuery("date:2026-02-30")?.message.contains("is not a date") == true)      // no such day
        #expect(badQuery("date:2026-1-1")?.message.contains("is not a date") == true)
        #expect(badQuery("date:2026-10-01..soon")?.message.contains("`soon` in `date:2026-10-01..soon`") == true)
        #expect(badQuery("from:") != nil && badQuery("(is:unread") != nil)
    }
}
