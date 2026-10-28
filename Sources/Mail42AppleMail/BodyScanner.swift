// BodyScanner.swift — "which of these messages contain this word?", answered by reading the messages.
//
// Apple Mail's Envelope Index holds headers only. The text of a message is in its .emlx file, and on current macOS
// Spotlight does not index those files (Mail's text lives in a private index nobody else can query; this was
// checked on a real Mail store: Spotlight reports no Mail items at all). So a text search reads the candidate
// messages itself: each file is decoded once, in parallel, and tested for every word the query asks about.
//
// That is fast for hundreds of messages and slow for hundreds of thousands, so the caller picks a bounded set of
// candidates (the newest ones that match the rest of the query) and a time limit; what was and wasn't covered is
// reported so a search never pretends to have looked at more than it did.

import Foundation
import Mail42Kit

/// How much a text search may read.
public struct ScanLimits: Sendable {
    /// The most messages to read.
    public var maxMessages: Int
    /// Stop starting new messages after this long.
    public var timeLimit: TimeInterval

    public init(maxMessages: Int = 20_000, timeLimit: TimeInterval = 8) {
        self.maxMessages = maxMessages
        self.timeLimit = timeLimit
    }

    public static let standard = ScanLimits()
}

public struct ScanResult: Sendable {
    /// For each word, the ids of the scanned messages whose text contains it.
    public var matches: [String: Set<Int64>]
    /// The ids of the messages that were actually read (a message with no file is "read" and matches nothing).
    public var scanned: Set<Int64>
}

public enum BodyScanner {

    /// - Parameters:
    ///   - terms: the words to look for (substring, ignoring case; accents must match).
    ///   - candidates: the messages to read, newest first; `file` is nil when Mail has no file for the message.
    public static func scan(
        terms: [String], candidates: [(id: Int64, file: URL?)], limits: ScanLimits = .standard
    ) -> ScanResult {
        let wanted = terms.map { (term: $0, folded: fold($0)) }
        let deadline = Date().addingTimeInterval(limits.timeLimit)
        let batch = Array(candidates.prefix(limits.maxMessages))

        let lock = NSLock()
        var matches: [String: Set<Int64>] = [:]
        var scanned = Set<Int64>()

        DispatchQueue.concurrentPerform(iterations: batch.count) { index in
            guard Date() < deadline else { return }
            let (id, file) = batch[index]
            let found = file.map { termsFound(in: $0, wanted: wanted) } ?? []
            lock.lock()
            scanned.insert(id)
            for term in found { matches[term, default: []].insert(id) }
            lock.unlock()
        }
        return ScanResult(matches: matches, scanned: scanned)
    }

    /// Which of the words the message's text contains.
    ///
    /// Decoding a message properly (MIME, charsets, HTML) costs ~25 ms; looking at its raw bytes costs ~0.5 ms. Most
    /// messages don't contain the word at all, so the raw bytes are checked first and a message is only decoded when it
    /// might match, or when its raw bytes can't be trusted (base64-encoded text, or a word with characters that
    /// encodings and HTML rewrite).
    static func termsFound(in file: URL, wanted: [(term: String, folded: String)]) -> [String] {
        let mightMatch: [String]
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
           let raw = rawCandidates(in: data, wanted: wanted) {
            mightMatch = raw
        } else {
            mightMatch = wanted.map(\.term)                      // can't tell from the raw bytes: decode it
        }
        guard !mightMatch.isEmpty, let text = text(of: file) else { return [] }
        let folded = fold(text)
        return wanted.filter { mightMatch.contains($0.term) && folded.contains($0.folded) }.map(\.term)
    }

    /// The words that appear in the raw bytes, or nil when the raw bytes can't answer (see `termsFound`).
    static func rawCandidates(in data: Data, wanted: [(term: String, folded: String)]) -> [String]? {
        let words = wanted.map { Array($0.folded.utf8) }
        // Only plain ASCII words that no encoding or HTML escaping could rewrite are safe to look for in raw bytes.
        let safe: (UInt8) -> Bool = { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 32 || $0 == 45 || $0 == 46 || $0 == 64 }
        guard words.allSatisfy({ !$0.isEmpty && $0.allSatisfy(safe) }) else { return nil }

        // Lower-case ASCII, and drop quoted-printable soft line breaks ("=" at the end of a line), which can split a word.
        var lower: [UInt8] = []
        lower.reserveCapacity(data.count)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var i = 0
            while i < bytes.count {
                let byte = bytes[i]
                if byte == 61 {                                                   // "="
                    if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                    if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                }
                lower.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
                i += 1
            }
        }
        // Base64 hides the text from raw bytes.
        if contains(lower, Array("content-transfer-encoding: base64".utf8)) { return nil }
        return zip(wanted, words).filter { contains(lower, $0.1) }.map { $0.0.term }
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
    }

    /// The message's readable text: its plain part, else its HTML turned into text. Nil when the file is unreadable.
    static func text(of file: URL) -> String? {
        guard let parsed = try? MessageParser.parse(emlx: file) else { return nil }
        if let plain = parsed.textBody, !plain.isEmpty { return plain }
        return parsed.htmlBody.map(HTMLText.convert)
    }

    /// The form used for comparing: case-insensitive, accents significant. (Accent-insensitive matching would force
    /// every message with an accent, nine in ten of them, through the slow decoder, and would make a text search
    /// disagree with the header searches, whose `LIKE` ignores case but not accents either.)
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: nil)
    }
}
