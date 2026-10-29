import Testing
@testable import Mail42Kit

@Suite struct QueryParserTests {

    /// A compact, position-free rendering of the parse tree, e.g. `and(from:alice,is:unread)`.
    private func shape(_ node: QueryNode) -> String {
        switch node {
        case .term(let field, let value, _): return (field.map { "\($0.rawValue):" } ?? "") + value
        case .not(let inner): return "not(\(shape(inner)))"
        case .and(let a, let b): return "and(\(shape(a)),\(shape(b)))"
        case .or(let a, let b): return "or(\(shape(a)),\(shape(b)))"
        }
    }

    private func parse(_ query: String) throws -> String { shape(try QueryParser.parse(query)) }

    private func failure(_ query: String) -> (message: String, position: Int)? {
        do { _ = try QueryParser.parse(query); return nil } catch Mail42Error.badQuery(let message, let position) {
            return (message, position)
        } catch { return nil }
    }

    // MARK: - Valid queries

    @Test func parsesEveryFieldAndImplicitAnd() throws {
        #expect(try parse("from:alice is:unread") == "and(from:alice,is:unread)")
        #expect(try parse("to:bo cc") == "and(to:bo,cc)")
        #expect(try parse("subject:\"q4 roadmap\" or body:invoice") == "or(subject:q4 roadmap,body:invoice)")
        #expect(try parse("not in:Sent date:2w..") == "and(not(in:Sent),date:2w..)")
        #expect(try parse("has:attachment date:2026-10-01..2026-10-15") == "and(has:attachment,date:2026-10-01..2026-10-15)")
        #expect(try parse("invoice") == "invoice")
        #expect(try parse("\"exact phrase\"") == "exact phrase")
    }

    @Test func orBindsLooserThanAndAndNotBindsTightest() throws {
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

    @Test func keywordsAndFieldNamesAreCaseInsensitive() throws {
        #expect(try parse("A AND b OR NOT c") == "or(and(A,b),not(c))")
        #expect(try parse("FROM:Alice Is:Unread") == "and(from:Alice,is:Unread)")
    }

    @Test func quotedKeywordsAndFieldLikeWordsAreJustText() throws {
        #expect(try parse("\"or\"") == "or")
        #expect(try parse("\"not\" \"and\"") == "and(not,and)")
        #expect(try parse("\"from:alice\"") == "from:alice")
        #expect(try parse("https://example.com/x") == "https://example.com/x")     // unknown prefix: a word
        #expect(try parse("foo:bar") == "foo:bar")
        #expect(try parse("12:30") == "12:30")
        #expect(try parse("orange nothing android") == "and(and(orange,nothing),android)")   // keywords only as whole words
    }

    @Test func handlesEscapesAndUnicode() throws {
        #expect(try parse(#"subject:"say \"hi\"""#) == #"subject:say "hi""#)
        #expect(try parse(#""back\\slash""#) == #"back\slash"#)
        #expect(try parse("from:josé café") == "and(from:josé,café)")
        #expect(try parse("  spaced   out  ") == "and(spaced,out)")
        #expect(try parse("日本語") == "日本語")
    }

    @Test func fieldValuesStopAtParenthesesAndWhitespace() throws {
        #expect(try parse("(from:alice)") == "from:alice")
        #expect(try parse("(is:unread or is:flagged) from:bo") == "and(or(is:unread,is:flagged),from:bo)")
        #expect(try parse("date:2w..") == "date:2w..")
        #expect(try parse("date:..2026-10-15") == "date:..2026-10-15")
    }

    @Test func recordsWhereEachTermStarts() throws {
        guard case .and(.term(_, _, let first), .term(_, _, let second)) = try QueryParser.parse("from:a  is:unread") else {
            Issue.record("unexpected shape"); return
        }
        #expect(first == 0 && second == 8)
    }

    // MARK: - Errors, with positions

    @Test func rejectsAnEmptyQuery() {
        #expect(failure("")?.message.contains("empty") == true)
        #expect(failure("   ")?.message.contains("empty") == true)
    }

    @Test func rejectsAFieldWithNoValue() {
        let f = failure("from:")
        #expect(f?.position == 0 && f?.message.contains("from:") == true)
        #expect(failure("is:unread to:")?.position == 10)
        #expect(failure("subject:\"\"")?.message.contains("subject:") == true)
    }

    @Test func rejectsUnclosedQuotes() {
        #expect(failure("\"never closed")?.position == 0)
        #expect(failure("a subject:\"open")?.position == 10)
        #expect(failure("\"ends with backslash\\")?.message.contains("quote") == true)
    }

    @Test func rejectsUnbalancedParentheses() {
        #expect(failure("(a or b")?.position == 0)
        #expect(failure("a)")?.position == 1)
        #expect(failure("a ) b")?.position == 2)
        #expect(failure("()")?.position == 1 || failure("()")?.position == 0)
        #expect(failure("(a (b)")?.message.contains("`)`") == true)
    }

    @Test func rejectsOperatorsWithoutOperands() {
        #expect(failure("a or")?.position == 4 && failure("a or")?.message.contains("or") == true)
        #expect(failure("a and")?.message.contains("and") == true)
        #expect(failure("not")?.message.contains("not") == true)
        #expect(failure("or a")?.position == 0)
        #expect(failure("and a")?.position == 0)
        #expect(failure("a or or b") != nil)
        #expect(failure("a or )") != nil)
    }
}
