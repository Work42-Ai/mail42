// MailBodyTheme.swift — puts a message in Work42's theme.
//
// `mail42 message read --html` gives the sender's HTML, already made safe (no scripts, no event handlers). Shown as it
// is, a plain mail looks like a 1995 web page (a serif font, browser-blue links, lines as wide as the window) and
// clashes with the rest of Work42. This wraps it in the same `--w42-*` tokens the artifacts use, so it takes the
// app's font, colours and accent, light or dark, a custom theme included.
//
// Two kinds of mail:
//   · Ordinary mail (plain text, or HTML that sets no colours of its own) is themed: system font at the app's body
//     size, theme text colours, accent links, a readable line length, and the quoted history folded away.
//   · Designed mail (newsletters, receipts: it sets its own colours or backgrounds) is kept exactly as designed, on a
//     light rounded card, because its own colours were chosen for a white page and would be unreadable on a dark one.
//
// No JavaScript: the dark variant is a `prefers-color-scheme` media query and the quote fold is a `<details>`.
// Foundation only, so it can be tried outside the app.

import Foundation

nonisolated enum MailBodyTheme {

    /// The themed page for `html`. `tokens` is Work42's `CanvasTheme.tokensCSS()`.
    static func wrap(_ html: String, tokens: String) -> String {
        let designed = isDesigned(html)
        var page = designed ? html : collapseQuotes(html)
        let style = "<style>\n" + darkByMedia(tokens) + "\n" + css(designed: designed) + "\n</style>\n"

        // The style goes first in <head>, so the sender's own <style> (further down) can still win within its card.
        if let head = page.range(of: "<head", options: .caseInsensitive),
           let close = page.range(of: ">", range: head.upperBound..<page.endIndex) {
            page.insert(contentsOf: "\n" + style, at: close.upperBound)
        } else if let root = page.range(of: "<html", options: .caseInsensitive),
                  let close = page.range(of: ">", range: root.upperBound..<page.endIndex) {
            page.insert(contentsOf: "<head><meta charset=\"utf-8\">\n" + style + "</head>", at: close.upperBound)
        } else {
            page = "<!doctype html><html><head><meta charset=\"utf-8\">\n" + style + "</head><body>" + page + "</body></html>"
        }

        if designed,
           let body = page.range(of: "<body", options: .caseInsensitive),
           let open = page.range(of: ">", range: body.upperBound..<page.endIndex),
           let end = page.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            page.insert(contentsOf: "</div>", at: end.lowerBound)
            page.insert(contentsOf: "<div class=\"m42-card\">", at: open.upperBound)
        }
        return page
    }

    /// Work42's tokens switch on a `.dark` class that a script sets. Mail has no script, so the dark values ride on
    /// the system appearance instead.
    static func darkByMedia(_ tokens: String) -> String {
        let converted = tokens.replacingOccurrences(of: "\n.dark {", with: "\n@media (prefers-color-scheme: dark) {\n:root {")
        return converted == tokens ? tokens : converted + "\n}"
    }

    // MARK: - Which kind of mail

    /// True when the HTML sets colours or backgrounds of its own.
    static func isDesigned(_ html: String) -> Bool {
        let patterns = [
            #"\bbgcolor\s*="#,
            #"<font[^>]*\bcolor\s*="#,
            #"(?<![-\w])background(-color|-image)?\s*[:=]\s*(?!\s*(transparent|none|inherit|initial|unset|rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\)))"#,
            #"(?<![-\w])color\s*:\s*(?!\s*(inherit|initial|unset|currentcolor))"#,
        ]
        return patterns.contains { html.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    // MARK: - Quoted history

    /// Folds every top-level `<blockquote>` (the earlier messages a reply quotes) behind "Show quoted text".
    static func collapseQuotes(_ html: String) -> String {
        let open = "<blockquote", close = "</blockquote>"
        var out = ""
        var cursor = html.startIndex
        while let start = html.range(of: open, options: .caseInsensitive, range: cursor..<html.endIndex) {
            var depth = 1
            var scan = start.upperBound
            var end: String.Index?
            while depth > 0 {
                guard let nextClose = html.range(of: close, options: .caseInsensitive, range: scan..<html.endIndex) else { break }
                if let nextOpen = html.range(of: open, options: .caseInsensitive, range: scan..<html.endIndex),
                   nextOpen.lowerBound < nextClose.lowerBound {
                    depth += 1
                    scan = nextOpen.upperBound
                } else {
                    depth -= 1
                    scan = nextClose.upperBound
                    if depth == 0 { end = nextClose.upperBound }
                }
            }
            guard let end else { break }                         // unbalanced markup: leave the rest untouched
            out += html[cursor..<start.lowerBound]
            out += "<details class=\"m42-quote\"><summary>Show quoted text</summary>" + html[start.lowerBound..<end] + "</details>"
            cursor = end
        }
        out += html[cursor...]
        return out
    }

    // MARK: - Style

    private static func css(designed: Bool) -> String {
        let common = """
        html { color-scheme: light dark; -webkit-text-size-adjust: 100%; background: var(--w42-backdrop); }
        body { margin: 0; background: var(--w42-backdrop) !important; }
        img { max-width: 100%; height: auto; }
        """
        if designed {
            return common + """

            body { padding: 14px 20px; }
            .m42-card { background: #ffffff; color: #1d1d1f; color-scheme: light; border-radius: 12px; padding: 16px;
                        overflow-x: auto; box-shadow: 0 1px 3px rgba(0,0,0,.18); }
            """
        }
        return common + """

        body { padding: 16px 24px 32px; color: var(--w42-text-primary); font-family: var(--w42-font-family, -apple-system, system-ui);
               font-size: 15px; line-height: 1.6; max-width: 72ch; overflow-wrap: anywhere; }
        a { color: var(--w42-accent, var(--w42-primary, #0a84ff)); text-decoration: none; }
        a:hover { text-decoration: underline; }
        p { margin: 0 0 12px; }
        pre { white-space: pre-wrap; font-family: inherit; font-size: inherit; margin: 0; }
        blockquote { margin: 8px 0; padding: 2px 0 2px 14px; border-left: 3px solid var(--w42-accent, var(--w42-primary, #0a84ff));
                     color: var(--w42-text-secondary, var(--w42-text-primary)); }
        details.m42-quote { margin: 10px 0; }
        details.m42-quote > summary { display: inline-block; cursor: pointer; list-style: none; font-size: 13px; padding: 2px 10px;
                     border-radius: 999px; background: var(--w42-chip, rgba(128,128,128,.18)); color: var(--w42-text-secondary, inherit); }
        details.m42-quote > summary::-webkit-details-marker { display: none; }
        details.m42-quote[open] > summary { margin-bottom: 6px; }
        table { max-width: 100%; }
        """
    }
}
