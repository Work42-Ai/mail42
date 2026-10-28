// QueryParser.swift — the `mail42 envelope search "<query>"` language.
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
// Errors carry the 0-based position of the problem so an agent (or a person) can fix the query.

import Foundation

public enum QueryField: String, CaseIterable, Sendable {
    case from, to, subject, body, `in`, `is`, has, date
}

public indirect enum QueryNode: Equatable, Sendable {
    /// `field == nil` is free text (matches subject, sender, recipients and body).
    case term(field: QueryField?, value: String, position: Int)
    case not(QueryNode)
    case and(QueryNode, QueryNode)
    case or(QueryNode, QueryNode)
}

public enum QueryParser {

    public static func parse(_ input: String) throws -> QueryNode {
        var parser = Parser(tokens: try tokenize(input), inputLength: input.count)
        guard !parser.tokens.isEmpty else { throw Mail42Error.badQuery("the query is empty", position: 0) }
        let node = try parser.parseOr()
        if let extra = parser.peek {
            switch extra.kind {
            case .rparen: throw Mail42Error.badQuery("unexpected `)` with no matching `(`", position: extra.position)
            default: throw Mail42Error.badQuery("unexpected \(extra.describe)", position: extra.position)
            }
        }
        return node
    }

    // MARK: - Tokens

    struct Token {
        enum Kind: Equatable {
            case word(String)
            case phrase(String)
            case field(QueryField, String)
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
            throw Mail42Error.badQuery("unclosed quote", position: start)
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
                   let field = QueryField(rawValue: String(chars[i..<j]).lowercased()) {
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
                        throw Mail42Error.badQuery("expected a value after `\(field.rawValue):`", position: start)
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

    // MARK: - Parser

    private struct Parser {
        let tokens: [Token]
        let inputLength: Int
        var index = 0

        init(tokens: [Token], inputLength: Int) {
            self.tokens = tokens
            self.inputLength = inputLength
        }

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func advance() { index += 1 }

        /// Position to report when the input ended where a term was expected.
        var endPosition: Int { inputLength }

        mutating func parseOr() throws -> QueryNode {
            var left = try parseAnd()
            while let token = peek, token.kind == .or {
                advance()
                guard peek != nil else {
                    throw Mail42Error.badQuery("expected a term after `or`", position: endPosition)
                }
                left = .or(left, try parseAnd())
            }
            return left
        }

        mutating func parseAnd() throws -> QueryNode {
            var left = try parseNot()
            while let token = peek {
                if token.kind == .and {
                    advance()
                    guard peek != nil else {
                        throw Mail42Error.badQuery("expected a term after `and`", position: endPosition)
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

        mutating func parseNot() throws -> QueryNode {
            if let token = peek, token.kind == .not {
                advance()
                guard peek != nil else {
                    throw Mail42Error.badQuery("expected a term after `not`", position: endPosition)
                }
                return .not(try parseNot())
            }
            return try parseAtom()
        }

        mutating func parseAtom() throws -> QueryNode {
            guard let token = peek else {
                throw Mail42Error.badQuery("expected a term", position: endPosition)
            }
            switch token.kind {
            case .lparen:
                advance()
                guard peek != nil else {
                    throw Mail42Error.badQuery("missing `)` to close the `(`", position: token.position)
                }
                let inner = try parseOr()
                guard let close = peek, close.kind == .rparen else {
                    throw Mail42Error.badQuery("missing `)` to close the `(`", position: token.position)
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
                throw Mail42Error.badQuery("unexpected `)` with no matching `(`", position: token.position)
            case .and, .or:
                throw Mail42Error.badQuery("\(token.describe) needs a term on its left", position: token.position)
            case .not:
                throw Mail42Error.badQuery("expected a term", position: token.position)   // handled by parseNot
            }
        }
    }
}
