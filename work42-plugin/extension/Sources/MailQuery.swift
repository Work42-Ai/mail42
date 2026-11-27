// MailQuery.swift — the search language of the mail tile, ported from the `mail42` command line (WOR-900).
//
// A small subset of notmuch's search terms (design only; no notmuch code):
//
//   from:alice  to:bo  subject:"q4 roadmap"  body:invoice  in:inbox  is:unread  has:attachment  date:2w..
//   plain words and "quoted phrases" search subject, sender, recipients and body together
//   and · or · not · ( ) combine terms; two terms next to each other mean AND
//
// Grammar (lowest to highest precedence):
//   query  := and ( "or" and )*
//   and    := not ( ["and"] not )*          -- adjacent terms are an implicit AND
//   not    := "not" not | atom
//   atom   := "(" query ")" | field ":" value | word | "phrase"
//
// `MailQueryParser` turns the text into a tree; `MailQueryCompiler` turns the tree into a SQL `WHERE` clause over Apple's
// `messages` table (alias `m`, with `subjects s`, the sender's `addresses a` and, when present, `summaries sm` joined in).
// User text never reaches the SQL string as SQL: sender, recipient and subject terms are `?` parameters (substring `LIKE`,
// escaped). Message TEXT is not in Apple's index, so free words and `body:` compile twice: "relaxed" (a superset to scan) and
// for real, each text test answered from the ids a scan found (see `MailSearch.swift`).
//
// Errors carry the 0-based position of the problem, like the CLI's `bad_query`.

import Foundation

nonisolated enum MailQueryField: String, CaseIterable, Sendable {
    case from, to, subject, body, `in`, `is`, has, date
}

nonisolated indirect enum MailQueryNode: Equatable, Sendable {
    /// `field == nil` is free text (matches subject, sender, recipients and body).
    case term(field: MailQueryField?, value: String, position: Int)
    case not(MailQueryNode)
    case and(MailQueryNode, MailQueryNode)
    case or(MailQueryNode, MailQueryNode)
}

/// A search query that is not valid. `position` is the 0-based character offset of the problem.
nonisolated struct MailQueryError: Error, Equatable {
    let message: String
    let position: Int

    /// The code the CLI reported for this (`MailFailure.code`), which the tile reacts to.
    static let code = "bad_query"

    /// Same wording as the CLI's `bad_query`.
    var description: String { "Bad query at position \(position): \(message)" }

    var failure: MailFailure { MailFailure(code: Self.code, message: description) }

    static func bad(_ message: String, position: Int) -> MailQueryError { MailQueryError(message: message, position: position) }
}

nonisolated enum MailQueryParser {

    /// The longest query read, in characters, and the deepest nesting of `(` and `not` (each is a recursion of the parser, and of
    /// the compiler after it): a hostile or runaway argument fails as a `bad_query` instead of exhausting the stack.
    static let maxLength = 2_000
    static let maxDepth = 64

    static func parse(_ input: String) throws -> MailQueryNode {
        let length = input.count
        guard length <= maxLength else {
            throw MailQueryError.bad("the query is too long (\(length) characters; at most \(maxLength))", position: maxLength)
        }
        var parser = Parser(tokens: try tokenize(input), inputLength: input.count)
        guard !parser.tokens.isEmpty else { throw MailQueryError.bad("the query is empty", position: 0) }
        let node = try parser.parseOr()
        if let extra = parser.peek {
            switch extra.kind {
            case .rparen: throw MailQueryError.bad("unexpected `)` with no matching `(`", position: extra.position)
            default: throw MailQueryError.bad("unexpected \(extra.describe)", position: extra.position)
            }
        }
        return node
    }

    // MARK: Tokens

    struct Token {
        enum Kind: Equatable {
            case word(String)
            case phrase(String)
            case field(MailQueryField, String)
            case lparen, rparen, and, or, not
        }
        let kind: Kind
        let position: Int

        var describe: String {
            switch kind {
            case .word(let w): return "`\(w)`"
            case .phrase(let p): return "\"\(p)\""
            case .field(let f, let v): return "`\(f.rawValue):\(v)`"
            case .lparen: return "`(`"
            case .rparen: return "`)`"
            case .and: return "`and`"
            case .or: return "`or`"
            case .not: return "`not`"
            }
        }

        /// Can this token begin a term (so that it continues an implicit AND)?
        var startsTerm: Bool {
            switch kind {
            case .word, .phrase, .field, .lparen, .not: return true
            case .rparen, .and, .or: return false
            }
        }
    }

    static func tokenize(_ input: String) throws -> [Token] {
        let chars = Array(input)
        let n = chars.count
        var tokens: [Token] = []
        var i = 0

        /// Reads a double-quoted string starting at `chars[start] == "\""`; returns its text and the index after
        /// the closing quote. `\"` and `\\` are escapes.
        func quoted(from start: Int) throws -> (String, Int) {
            var j = start + 1
            var text = ""
            while j < n {
                let c = chars[j]
                if c == "\\", j + 1 < n, chars[j + 1] == "\"" || chars[j + 1] == "\\" {
                    text.append(chars[j + 1])
                    j += 2
                } else if c == "\"" {
                    return (text, j + 1)
                } else {
                    text.append(c)
                    j += 1
                }
            }
            throw MailQueryError.bad("unclosed quote", position: start)
        }

        while i < n {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c == "(" {
                tokens.append(Token(kind: .lparen, position: i)); i += 1
            } else if c == ")" {
                tokens.append(Token(kind: .rparen, position: i)); i += 1
            } else if c == "\"" {
                let (text, next) = try quoted(from: i)
                tokens.append(Token(kind: .phrase(text), position: i))
                i = next
            } else {
                let start = i
                // `field:` prefix?
                var j = i
                while j < n, chars[j].isLetter || chars[j] == "_" { j += 1 }
                if j < n, chars[j] == ":", j > i,
                   let field = MailQueryField(rawValue: String(chars[i..<j]).lowercased()) {
                    var k = j + 1
                    let value: String
                    if k < n, chars[k] == "\"" {
                        (value, k) = try quoted(from: k)
                    } else {
                        let valueStart = k
                        while k < n, !chars[k].isWhitespace, chars[k] != ")", chars[k] != "(" { k += 1 }
                        value = String(chars[valueStart..<k])
                    }
                    if value.isEmpty {
                        throw MailQueryError.bad("expected a value after `\(field.rawValue):`", position: start)
                    }
                    tokens.append(Token(kind: .field(field, value), position: start))
                    i = k
                } else {
                    var k = i
                    while k < n, !chars[k].isWhitespace, chars[k] != "(", chars[k] != ")", chars[k] != "\"" { k += 1 }
                    let word = String(chars[i..<k])
                    switch word.lowercased() {
                    case "and": tokens.append(Token(kind: .and, position: start))
                    case "or": tokens.append(Token(kind: .or, position: start))
                    case "not": tokens.append(Token(kind: .not, position: start))
                    default: tokens.append(Token(kind: .word(word), position: start))
                    }
                    i = k
                }
            }
        }
        return tokens
    }

    // MARK: Parser

    private struct Parser {
        let tokens: [Token]
        let inputLength: Int
        var index = 0
        /// How many `(` and `not` are open around the term being read.
        var depth = 0

        init(tokens: [Token], inputLength: Int) {
            self.tokens = tokens
            self.inputLength = inputLength
        }

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func advance() { index += 1 }

        /// Position to report when the input ended where a term was expected.
        var endPosition: Int { inputLength }

        mutating func parseOr() throws -> MailQueryNode {
            var left = try parseAnd()
            while let token = peek, token.kind == .or {
                advance()
                guard peek != nil else {
                    throw MailQueryError.bad("expected a term after `or`", position: endPosition)
                }
                left = .or(left, try parseAnd())
            }
            return left
        }

        mutating func parseAnd() throws -> MailQueryNode {
            var left = try parseNot()
            while let token = peek {
                if token.kind == .and {
                    advance()
                    guard peek != nil else {
                        throw MailQueryError.bad("expected a term after `and`", position: endPosition)
                    }
                    left = .and(left, try parseNot())
                } else if token.startsTerm {
                    left = .and(left, try parseNot())        // implicit AND
                } else {
                    break
                }
            }
            return left
        }

        /// Opens one more level of nesting (a `(` or a `not`) at `token`, or fails when there are too many.
        mutating func descend(at token: Token) throws {
            depth += 1
            guard depth <= MailQueryParser.maxDepth else {
                throw MailQueryError.bad(
                    "nested too deeply (more than \(MailQueryParser.maxDepth) levels of `(` or `not`)", position: token.position)
            }
        }

        mutating func parseNot() throws -> MailQueryNode {
            if let token = peek, token.kind == .not {
                try descend(at: token)
                defer { depth -= 1 }
                advance()
                guard peek != nil else {
                    throw MailQueryError.bad("expected a term after `not`", position: endPosition)
                }
                return .not(try parseNot())
            }
            return try parseAtom()
        }

        mutating func parseAtom() throws -> MailQueryNode {
            guard let token = peek else {
                throw MailQueryError.bad("expected a term", position: endPosition)
            }
            switch token.kind {
            case .lparen:
                try descend(at: token)
                defer { depth -= 1 }
                advance()
                guard peek != nil else {
                    throw MailQueryError.bad("missing `)` to close the `(`", position: token.position)
                }
                let inner = try parseOr()
                guard let close = peek, close.kind == .rparen else {
                    throw MailQueryError.bad("missing `)` to close the `(`", position: token.position)
                }
                advance()
                return inner
            case .word(let word):
                advance()
                return .term(field: nil, value: word, position: token.position)
            case .phrase(let phrase):
                advance()
                return .term(field: nil, value: phrase, position: token.position)
            case .field(let field, let value):
                advance()
                return .term(field: field, value: value, position: token.position)
            case .rparen:
                throw MailQueryError.bad("unexpected `)` with no matching `(`", position: token.position)
            case .and, .or:
                throw MailQueryError.bad("\(token.describe) needs a term on its left", position: token.position)
            case .not:
                throw MailQueryError.bad("expected a term", position: token.position)   // handled by parseNot
            }
        }
    }
}

// MARK: - Compiler

nonisolated struct MailQueryCompiled: Sendable {
    /// SQL boolean expression over `messages m` (+ `subjects s`, sender `addresses a`).
    let whereSQL: String
    /// Parameters for the `?` placeholders in `whereSQL`, in order.
    let params: [MailSQLValue]
    /// The distinct words the query wants found inside messages (free words and `body:` values).
    let textTerms: [String]
    /// True when a word is used under `not`. Then "which messages match by their headers alone" is no longer a subset
    /// of the real answer (a message whose BODY has the word must be excluded), so it can't be shown early.
    let hasNegatedText: Bool
}

nonisolated struct MailQueryCompiler {

    let now: Date
    let calendar: Calendar
    /// Ids of the mailboxes a name, id or role refers to (for `in:`).
    private let mailboxIDs: @Sendable (String) -> [Int64]
    /// For each text term, the ids of the messages whose text contains it. Nil = compile the relaxed superset.
    private let textMatches: [String: Set<Int64>]?
    /// Whether the statement joins Apple's one-line message preview as `sm`, so a plain word can match it too.
    private let summaries: Bool
    /// Whether the index has a usable `labels` table, so `in:` can also match a Gmail label.
    private let labels: Bool

    /// - Parameter textMatches: nil compiles the relaxed form used to pick messages to scan; a table compiles the
    ///   real query, with every text test answered from it.
    /// - Parameter summaries: the statement has `LEFT JOIN summaries sm`; a plain word then also matches the preview
    ///   line Apple Mail keeps of each message (the start of its text), which the index can answer instantly.
    init(
        now: Date = Date(), calendar: Calendar = .current,
        mailboxIDs: @escaping @Sendable (String) -> [Int64] = { _ in [] },
        textMatches: [String: Set<Int64>]? = nil,
        summaries: Bool = false,
        labels: Bool = true
    ) {
        self.labels = labels
        self.now = now
        self.calendar = calendar
        self.mailboxIDs = mailboxIDs
        self.textMatches = textMatches
        self.summaries = summaries
    }

    func compile(_ node: MailQueryNode) throws -> MailQueryCompiled {
        var state = State()
        let sql = try build(node, negated: false, state: &state)
        return MailQueryCompiled(whereSQL: sql, params: state.params, textTerms: state.terms, hasNegatedText: state.negatedText)
    }

    /// Parses and compiles in one step.
    func compile(_ query: String) throws -> MailQueryCompiled {
        try compile(try MailQueryParser.parse(query))
    }

    private struct State {
        var params: [MailSQLValue] = []
        var terms: [String] = []
        var negatedText = false
    }

    // MARK: AST

    private func build(_ node: MailQueryNode, negated: Bool, state: inout State) throws -> String {
        switch node {
        case .and(let a, let b):
            let left = try build(a, negated: negated, state: &state)
            let right = try build(b, negated: negated, state: &state)
            return "(\(left) AND \(right))"
        case .or(let a, let b):
            let left = try build(a, negated: negated, state: &state)
            let right = try build(b, negated: negated, state: &state)
            return "(\(left) OR \(right))"
        case .not(let inner):
            return "(NOT \(try build(inner, negated: !negated, state: &state)))"
        case .term(let field, let value, let position):
            return try term(field, value, position: position, negated: negated, state: &state)
        }
    }

    private func term(
        _ field: MailQueryField?, _ value: String, position: Int, negated: Bool, state: inout State
    ) throws -> String {
        switch field {
        case nil:
            // A plain word: in the subject, the sender, a recipient, the message's preview line, or the message text.
            var clauses = [subjectClause(value, state: &state), senderClause(value, state: &state),
                           recipientClause(value, state: &state)]
            if summaries { clauses.append(summaryClause(value, state: &state)) }
            clauses.append(textClause(value, negated: negated, state: &state))
            return "(" + clauses.joined(separator: " OR ") + ")"
        case .subject?:
            return subjectClause(value, state: &state)
        case .body?:
            return textClause(value, negated: negated, state: &state)

        case .from?:
            return senderClause(value, state: &state)
        case .to?:
            return recipientClause(value, state: &state)

        case .in?:
            let ids = mailboxIDs(value)
            guard !ids.isEmpty else { return "0" }
            let list = ids.map(String.init).joined(separator: ",")
            // Stored in the mailbox, or (a Gmail label) labelled with it, when this index has a usable labels table.
            guard labels else { return "m.mailbox IN (\(list))" }
            return "(m.mailbox IN (\(list)) OR EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(list))))"

        case .is?:
            switch value.lowercased() {
            case "unread": return "m.read = 0"
            case "read": return "m.read = 1"
            case "flagged": return "m.flagged = 1"
            default:
                throw MailQueryError.bad("`is:` takes unread, read or flagged, not `\(value)`", position: position)
            }

        case .has?:
            guard value.lowercased() == "attachment" else {
                throw MailQueryError.bad("`has:` takes attachment, not `\(value)`", position: position)
            }
            return "EXISTS (SELECT 1 FROM attachments att WHERE att.message = m.ROWID AND att.name IS NOT NULL AND att.name != '')"

        case .date?:
            return try dateClause(value, position: position, state: &state)
        }
    }

    // MARK: Fields

    private func subjectClause(_ value: String, state: inout State) -> String {
        state.params.append(.text("%\(escapeLike(value))%"))
        // COALESCE: a NULL column must test false, not NULL, or `not` would drop the message.
        return "COALESCE(s.subject, '') LIKE ? ESCAPE '\\'"
    }

    /// Apple Mail's preview line of the message (the first lines of its text), as shown in Mail's own list.
    private func summaryClause(_ value: String, state: inout State) -> String {
        state.params.append(.text("%\(escapeLike(value))%"))
        return "COALESCE(sm.summary, '') LIKE ? ESCAPE '\\'"
    }

    private func senderClause(_ value: String, state: inout State) -> String {
        let pattern = "%\(escapeLike(value))%"
        state.params += [.text(pattern), .text(pattern)]
        return "(COALESCE(a.address, '') LIKE ? ESCAPE '\\' OR COALESCE(a.comment, '') LIKE ? ESCAPE '\\')"
    }

    /// To and Cc (types 0 and 1 in Apple's `recipients`).
    private func recipientClause(_ value: String, state: inout State) -> String {
        let pattern = "%\(escapeLike(value))%"
        state.params += [.text(pattern), .text(pattern)]
        return """
        EXISTS (SELECT 1 FROM recipients r JOIN addresses ra ON ra.ROWID = r.address \
        WHERE r.message = m.ROWID AND r.type IN (0, 1) \
        AND (ra.address LIKE ? ESCAPE '\\' OR ra.comment LIKE ? ESCAPE '\\'))
        """
    }

    /// "The message text contains `value`". Relaxed: true where a match could only help the message qualify and
    /// false where it could only exclude it, so the result is a superset of the real answer.
    private func textClause(_ value: String, negated: Bool, state: inout State) -> String {
        if !state.terms.contains(value) { state.terms.append(value) }
        if negated { state.negatedText = true }
        guard let textMatches else { return negated ? "0" : "1" }
        let ids = textMatches[value] ?? []
        return ids.isEmpty ? "0" : "m.ROWID IN (\(ids.map(String.init).joined(separator: ",")))"
    }

    /// Escapes `%`, `_` and `\` for a LIKE pattern that uses `ESCAPE '\'`.
    static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func escapeLike(_ value: String) -> String { Self.escapeLike(value) }

    // MARK: Dates

    private static let usage = "use 2w.. (or 3d.., 1m..), 2026-10-01..2026-10-15, 2026-10-01.. or ..2026-10-15"

    private func dateClause(_ value: String, position: Int, state: inout State) throws -> String {
        var lower: Date?
        var upper: Date?                     // exclusive

        if let range = value.range(of: "..") {
            let left = String(value[value.startIndex..<range.lowerBound])
            let right = String(value[range.upperBound...])
            guard !left.isEmpty || !right.isEmpty else {
                throw MailQueryError.bad("`date:..` needs a start or an end (\(Self.usage))", position: position)
            }
            if !left.isEmpty { lower = try instant(left, endOfRange: false, value: value, position: position) }
            if !right.isEmpty { upper = try instant(right, endOfRange: true, value: value, position: position) }
        } else if isRelative(value) {
            lower = try instant(value, endOfRange: false, value: value, position: position)        // "2w" = "2w.."
        } else {
            lower = try instant(value, endOfRange: false, value: value, position: position)         // one whole day
            upper = try instant(value, endOfRange: true, value: value, position: position)
        }

        var parts: [String] = []
        if let lower {
            parts.append("m.date_received >= ?")
            state.params.append(.int(Int64(lower.timeIntervalSince1970)))
        }
        if let upper {
            parts.append("m.date_received < ?")
            state.params.append(.int(Int64(upper.timeIntervalSince1970)))
        }
        return "(" + parts.joined(separator: " AND ") + ")"
    }

    private func isRelative(_ spec: String) -> Bool {
        spec.range(of: #"^\d+[dwm]$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `3d` / `2w` / `1m` (that long ago) or `YYYY-MM-DD`. For a date used as the end of a range
    /// (`endOfRange`), returns the start of the NEXT day so the whole last day is included.
    private func instant(_ spec: String, endOfRange: Bool, value: String, position: Int) throws -> Date {
        if isRelative(spec) {
            // A digit string too long for Int, a week count that overflows `* 7`, or more than 10,000 years back is out of range.
            guard let amount = Int(spec.dropLast()) else {
                throw MailQueryError.bad("`\(spec)` is out of range", position: position)
            }
            let component: Calendar.Component
            let count: Int
            let limit: Int
            switch spec.last!.lowercased() {
            case "d": component = .day; limit = 3_652_500; count = amount
            case "w":
                let (product, overflow) = amount.multipliedReportingOverflow(by: 7)
                component = .day; limit = 3_652_500; count = overflow ? Int.max : product
            default: component = .month; limit = 120_000; count = amount
            }
            guard count <= limit else {
                throw MailQueryError.bad("`\(spec)` is out of range", position: position)
            }
            guard let date = calendar.date(byAdding: component, value: -count, to: now) else {
                throw MailQueryError.bad("`\(spec)` is out of range", position: position)
            }
            return date
        }

        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.dateComponents([.year, .month, .day], from: start)
                == DateComponents(year: year, month: month, day: day)
        else {
            throw MailQueryError.bad("`\(spec)` in `date:\(value)` is not a date (\(Self.usage))", position: position)
        }
        return endOfRange ? (calendar.date(byAdding: .day, value: 1, to: start) ?? start) : start
    }
}
