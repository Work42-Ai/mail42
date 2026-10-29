// QueryCompiler.swift — turns a parsed query into a SQL `WHERE` clause over Apple Mail's index, with bound
// parameters.
//
// The clause is written against Apple's `messages` table aliased as `m`, with `subjects` as `s` and the sender's
// `addresses` row as `a` joined in. User text never reaches the SQL string as SQL: sender, recipient and subject
// terms are `?` parameters (substring `LIKE`, escaped).
//
// Message TEXT is not in Apple's index (it is in the .emlx files, and on current macOS not in Spotlight either), so
// free words and `body:` are checked by reading messages. SQL can't do that, so a query with such terms compiles
// twice: once "relaxed", with every text test replaced by what can't exclude a message (a superset to scan), and
// once for real, where each text test is `m.ROWID IN (…)` over the ids the scan found. The ids are integers, so
// they are safe to write into the statement.

import Foundation

public struct CompiledQuery: Sendable {
    /// SQL boolean expression over `messages m` (+ `subjects s`, sender `addresses a`).
    public let whereSQL: String
    /// Parameters for the `?` placeholders in `whereSQL`, in order.
    public let params: [SQLiteValue]
    /// The distinct words the query wants found inside messages (free words and `body:` values).
    public let textTerms: [String]
    /// True when a word is used under `not`. Then "which messages match by their headers alone" is no longer a subset
    /// of the real answer (a message whose BODY has the word must be excluded), so it can't be shown early.
    public let hasNegatedText: Bool
}

public struct QueryCompiler {

    public let now: Date
    public let calendar: Calendar
    /// Ids of the mailboxes a name, id or role refers to (for `in:`).
    private let mailboxIDs: @Sendable (String) -> [Int64]
    /// For each text term, the ids of the messages whose text contains it. Nil = compile the relaxed superset.
    private let textMatches: [String: Set<Int64>]?
    /// Whether the statement joins Apple's one-line message preview as `sm`, so a plain word can match it too.
    private let summaries: Bool

    /// - Parameter textMatches: nil compiles the relaxed form used to pick messages to scan; a table compiles the
    ///   real query, with every text test answered from it.
    /// - Parameter summaries: the statement has `LEFT JOIN summaries sm`; a plain word then also matches the preview
    ///   line Apple Mail keeps of each message (the start of its text), which the index can answer instantly.
    public init(
        now: Date = Date(), calendar: Calendar = .current,
        mailboxIDs: @escaping @Sendable (String) -> [Int64] = { _ in [] },
        textMatches: [String: Set<Int64>]? = nil,
        summaries: Bool = false
    ) {
        self.now = now
        self.calendar = calendar
        self.mailboxIDs = mailboxIDs
        self.textMatches = textMatches
        self.summaries = summaries
    }

    public func compile(_ node: QueryNode) throws -> CompiledQuery {
        var state = State()
        let sql = try build(node, negated: false, state: &state)
        return CompiledQuery(whereSQL: sql, params: state.params, textTerms: state.terms, hasNegatedText: state.negatedText)
    }

    /// Parses and compiles in one step.
    public func compile(_ query: String) throws -> CompiledQuery {
        try compile(try QueryParser.parse(query))
    }

    private struct State {
        var params: [SQLiteValue] = []
        var terms: [String] = []
        var negatedText = false
    }

    // MARK: - AST

    private func build(_ node: QueryNode, negated: Bool, state: inout State) throws -> String {
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
        _ field: QueryField?, _ value: String, position: Int, negated: Bool, state: inout State
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
            // Stored in the mailbox, or (a Gmail label) labelled with it.
            return "(m.mailbox IN (\(list)) OR EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(list))))"

        case .is?:
            switch value.lowercased() {
            case "unread": return "m.read = 0"
            case "read": return "m.read = 1"
            case "flagged": return "m.flagged = 1"
            default:
                throw Mail42Error.badQuery("`is:` takes unread, read or flagged, not `\(value)`", position: position)
            }

        case .has?:
            guard value.lowercased() == "attachment" else {
                throw Mail42Error.badQuery("`has:` takes attachment, not `\(value)`", position: position)
            }
            return "EXISTS (SELECT 1 FROM attachments att WHERE att.message = m.ROWID AND att.name IS NOT NULL AND att.name != '')"

        case .date?:
            return try dateClause(value, position: position, state: &state)
        }
    }

    // MARK: - Fields

    private func subjectClause(_ value: String, state: inout State) -> String {
        state.params.append(.text("%\(escapeLike(value))%"))
        return "s.subject LIKE ? ESCAPE '\\'"
    }

    /// Apple Mail's preview line of the message (the first lines of its text), as shown in Mail's own list.
    private func summaryClause(_ value: String, state: inout State) -> String {
        state.params.append(.text("%\(escapeLike(value))%"))
        return "sm.summary LIKE ? ESCAPE '\\'"
    }

    private func senderClause(_ value: String, state: inout State) -> String {
        let pattern = "%\(escapeLike(value))%"
        state.params += [.text(pattern), .text(pattern)]
        return "(a.address LIKE ? ESCAPE '\\' OR a.comment LIKE ? ESCAPE '\\')"
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

    // MARK: - Dates

    private static let usage = "use 2w.. (or 3d.., 1m..), 2026-10-01..2026-10-15, 2026-10-01.. or ..2026-10-15"

    private func dateClause(_ value: String, position: Int, state: inout State) throws -> String {
        var lower: Date?
        var upper: Date?                     // exclusive

        if let range = value.range(of: "..") {
            let left = String(value[value.startIndex..<range.lowerBound])
            let right = String(value[range.upperBound...])
            guard !left.isEmpty || !right.isEmpty else {
                throw Mail42Error.badQuery("`date:..` needs a start or an end (\(Self.usage))", position: position)
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
            let amount = Int(spec.dropLast()) ?? 0
            let component: Calendar.Component
            let count: Int
            switch spec.last!.lowercased() {
            case "d": component = .day; count = amount
            case "w": component = .day; count = amount * 7
            default: component = .month; count = amount
            }
            guard let date = calendar.date(byAdding: component, value: -count, to: now) else {
                throw Mail42Error.badQuery("`\(spec)` is out of range", position: position)
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
            throw Mail42Error.badQuery("`\(spec)` in `date:\(value)` is not a date (\(Self.usage))", position: position)
        }
        return endOfRange ? (calendar.date(byAdding: .day, value: 1, to: start) ?? start) : start
    }
}
