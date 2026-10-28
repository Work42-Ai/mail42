// QueryCompiler.swift — turns a parsed query into a SQL `WHERE` clause with bound parameters.
//
// The clause is written against `envelopes` aliased as `e`. User text never reaches the SQL string: every
// value is a `?` parameter. Full-text terms (free words, `subject:`, `body:`) become FTS5 `MATCH` subqueries,
// each value quoted as a phrase (an unquoted hyphen or colon would change an FTS5 query's meaning). The
// positive full-text terms are also returned as one OR-ed FTS5 expression so results can be ranked by BM25.

import Foundation

public struct CompiledQuery: Sendable {
    /// SQL boolean expression over `envelopes e`.
    public let whereSQL: String
    /// Parameters for the `?` placeholders in `whereSQL`, in order.
    public let params: [SQLiteValue]
    /// OR of the query's positive full-text terms (nil when it has none): rank results by `bm25` against it.
    public let rankExpression: String?
}

public struct QueryCompiler {

    public let now: Date
    public let calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    public func compile(_ node: QueryNode) throws -> CompiledQuery {
        var state = State()
        let sql = try build(node, negated: false, state: &state)
        return CompiledQuery(
            whereSQL: sql, params: state.params,
            rankExpression: state.positiveFTS.isEmpty ? nil : state.positiveFTS.joined(separator: " OR "))
    }

    /// Parses and compiles in one step.
    public func compile(_ query: String) throws -> CompiledQuery {
        try compile(try QueryParser.parse(query))
    }

    private struct State {
        var params: [SQLiteValue] = []
        var positiveFTS: [String] = []
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
            return fullText(column: nil, value: value, negated: negated, state: &state)
        case .subject?:
            return fullText(column: "subject", value: value, negated: negated, state: &state)
        case .body?:
            return fullText(column: "body_text", value: value, negated: negated, state: &state)

        case .from?:
            let pattern = "%\(escapeLike(value))%"
            state.params += [.text(pattern), .text(pattern)]
            return "(e.from_addr LIKE ? ESCAPE '\\' OR e.from_name LIKE ? ESCAPE '\\')"

        case .to?:
            let pattern = "%\(escapeLike(value))%"
            state.params += [.text(pattern), .text(pattern)]
            return """
            EXISTS (SELECT 1 FROM recipients r WHERE r.envelope_id = e.id AND r.kind IN ('to', 'cc') \
            AND (r.addr LIKE ? ESCAPE '\\' OR r.name LIKE ? ESCAPE '\\'))
            """

        case .in?:
            let clause = Self.mailboxClause(matching: value)
            state.params += clause.params
            return clause.sql

        case .is?:
            switch value.lowercased() {
            case "unread": return "e.is_read = 0"
            case "read": return "e.is_read = 1"
            case "flagged": return "e.is_flagged = 1"
            default:
                throw Mail42Error.badQuery("`is:` takes unread, read or flagged, not `\(value)`", position: position)
            }

        case .has?:
            guard value.lowercased() == "attachment" else {
                throw Mail42Error.badQuery("`has:` takes attachment, not `\(value)`", position: position)
            }
            return "e.has_attachments = 1"

        case .date?:
            return try dateClause(value, position: position, state: &state)
        }
    }

    // MARK: - Full text

    /// An FTS5 `MATCH` subquery for one term; `column` limits it to one FTS column.
    private func fullText(column: String?, value: String, negated: Bool, state: inout State) -> String {
        // A value with no letters or digits has no tokens to match: it matches nothing.
        guard value.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return "0" }
        let phrase = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let expression = column.map { "\($0):\(phrase)" } ?? phrase
        state.params.append(.text(expression))
        if !negated { state.positiveFTS.append(expression) }
        return "e.id IN (SELECT rowid FROM bodies_fts WHERE bodies_fts MATCH ?)"
    }

    /// Escapes `%`, `_` and `\` for a LIKE pattern that uses `ESCAPE '\'`.
    static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func escapeLike(_ value: String) -> String { Self.escapeLike(value) }

    /// SQL (over `envelopes e`) for "the message is in the mailbox called `value`". `value` is a mailbox id, a
    /// name (case-insensitive, `Sent Messages`, or just the leaf of a nested name such as `Work42` for
    /// `Clients/Work42`), or a role (`inbox`, `sent`, `drafts`, `archive`, `trash`, `junk`). Shared by the
    /// `in:` search term and `envelope list -m`.
    static func mailboxClause(matching value: String) -> (sql: String, params: [SQLiteValue]) {
        (
            """
            e.mailbox_id IN (SELECT id FROM mailboxes WHERE id = ? OR lower(name) = lower(?) \
            OR lower(name) LIKE '%/' || lower(?) ESCAPE '\\' OR role = lower(?))
            """,
            [.int(Int64(value) ?? -1), .text(value), .text(escapeLike(value)), .text(value)]
        )
    }

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
            parts.append("e.date_received >= ?")
            state.params.append(.int(Int64(lower.timeIntervalSince1970)))
        }
        if let upper {
            parts.append("e.date_received < ?")
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
