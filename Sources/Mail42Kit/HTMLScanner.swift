// HTMLScanner.swift — the small byte-level HTML tokenizer helpers shared by `HTMLSanitizer` (renders a message
// for the widget) and `HTMLText` (plain text for full-text search).
//
// Works on UTF-8 bytes: every delimiter HTML cares about (`<`, `>`, quotes, `=`) is ASCII, and ASCII bytes never
// occur inside a multi-byte UTF-8 sequence, so slicing and re-joining byte ranges can't split a character.

import Foundation

/// A parsed start tag: `<name attr="v" flag>`.
struct HTMLStartTag {
    /// Lowercased tag name.
    var name: String
    /// Attributes in source order; names lowercased; `nil` value for a bare flag like `disabled`.
    var attributes: [(name: String, value: String?)]
    /// Index just past the closing `>`.
    var end: Int
}

enum HTMLScanner {

    static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    static func lower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 32 : b
    }

    /// True when `bytes[i...]` starts with `prefix`, ignoring ASCII case.
    static func hasPrefix(_ bytes: [UInt8], at i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        guard i + p.count <= bytes.count else { return false }
        for k in 0..<p.count where lower(bytes[i + k]) != lower(p[k]) { return false }
        return true
    }

    /// Index of the first occurrence of `needle` (ASCII, case-insensitive) at or after `from`.
    static func find(_ needle: String, in bytes: [UInt8], from: Int) -> Int? {
        let p = Array(needle.utf8)
        guard !p.isEmpty, bytes.count >= p.count, from <= bytes.count - p.count else { return nil }
        var i = from
        let last = bytes.count - p.count
        let first = lower(p[0])
        while i <= last {
            if lower(bytes[i]) == first {
                var matched = true
                var k = 1
                while k < p.count {
                    if lower(bytes[i + k]) != lower(p[k]) { matched = false; break }
                    k += 1
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    /// Index just past the next `>` at or after `from`, or nil.
    static func endOfTag(_ bytes: [UInt8], from: Int) -> Int? {
        var i = from
        while i < bytes.count {
            if bytes[i] == 0x3E { return i + 1 }
            i += 1
        }
        return nil
    }

    /// Parses the start tag at `i` (`bytes[i] == '<'` and a letter follows). Returns nil when the tag has no
    /// closing `>` (the caller then treats the `<` as text).
    static func parseStartTag(_ bytes: [UInt8], at i: Int) -> HTMLStartTag? {
        let n = bytes.count
        var j = i + 1
        let nameStart = j
        while j < n, !isSpace(bytes[j]), bytes[j] != 0x2F, bytes[j] != 0x3E { j += 1 }
        let name = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
        var attributes: [(name: String, value: String?)] = []

        while j < n {
            while j < n, isSpace(bytes[j]) || bytes[j] == 0x2F { j += 1 }
            guard j < n else { return nil }
            if bytes[j] == 0x3E {
                return HTMLStartTag(name: name, attributes: attributes, end: j + 1)
            }
            let attrStart = j
            while j < n, !isSpace(bytes[j]), bytes[j] != 0x3D, bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
            if j == attrStart { j += 1; continue }
            let attrName = String(decoding: bytes[attrStart..<j], as: UTF8.self).lowercased()
            while j < n, isSpace(bytes[j]) { j += 1 }
            if j < n, bytes[j] == 0x3D {
                j += 1
                while j < n, isSpace(bytes[j]) { j += 1 }
                guard j < n else { return nil }
                var value: String
                if bytes[j] == 0x22 || bytes[j] == 0x27 {
                    let quote = bytes[j]
                    j += 1
                    let valueStart = j
                    while j < n, bytes[j] != quote { j += 1 }
                    guard j < n else { return nil }
                    value = String(decoding: bytes[valueStart..<j], as: UTF8.self)
                    j += 1
                } else {
                    let valueStart = j
                    while j < n, !isSpace(bytes[j]), bytes[j] != 0x3E { j += 1 }
                    value = String(decoding: bytes[valueStart..<j], as: UTF8.self)
                }
                attributes.append((attrName, value))
            } else {
                attributes.append((attrName, nil))
            }
        }
        return nil
    }
}

/// Minimal HTML entity decoding: numeric references and the named entities that show up in real email.
enum HTMLEntities {

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "laquo": "«", "raquo": "»", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "deg": "°", "times": "×", "divide": "÷", "plusmn": "±", "sect": "§", "para": "¶",
        "colon": ":", "tab": "\t", "newline": "\n", "excl": "!", "num": "#", "dollar": "$",
        "percnt": "%", "lpar": "(", "rpar": ")", "sol": "/", "semi": ";", "equals": "=",
        "quest": "?", "commat": "@", "lbrack": "[", "rbrack": "]", "lowbar": "_", "period": ".",
        "comma": ",", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}",
        "zwj": "\u{200D}", "shy": "\u{00AD}",
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = s[s.index(after: i)..<semi]
                if let decoded = decodeBody(body) {
                    out.append(decoded)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeBody(_ body: Substring) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[body.lowercased()]
    }
}
