// MailBodyTheme.swift — puts a message in Work42's theme, the way Gmail restyles mail to fit its own look.
//
// `mail42 message read --html` gives the sender's HTML, already made safe (no scripts, no event handlers). Shown as it
// is, a plain mail looks like a 1995 web page (a serif font, browser-blue links, lines as wide as the window) and
// clashes with the rest of Work42. This wraps it in the same `--w42-*` tokens the artifacts use, so it takes the
// app's font, colours and accent, light or dark, a custom theme included.
//
// Three kinds of mail:
//   · Ordinary mail (plain text, or HTML that sets no colours) takes the theme: the app's background, text colours,
//     font and body size, accent links, a readable line length, the quoted history folded away.
//   · Mail that sets only TEXT colours (a Gmail reply with `color:rgb(34,34,34)` spans) takes the theme's text colours
//     too: its own dark text would vanish on a dark theme. Links keep the accent.
//   · Designed mail (newsletters, receipts: it paints its own backgrounds) keeps its design, because its colours were
//     chosen together. Light theme: as designed. Dark theme: adapted automatically, as Gmail's dark mode does (the
//     colours are inverted and the images put back), so a white newsletter becomes dark instead of a white slab.
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

        // The message goes in one wrapper that says which kind it is.
        let kind = designed ? "m42-card" : (setsTextColors(html) ? "m42-plain m42-force" : "m42-plain")
        if let body = page.range(of: "<body", options: .caseInsensitive),
           let open = page.range(of: ">", range: body.upperBound..<page.endIndex),
           let end = page.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            page.insert(contentsOf: "</div>", at: end.lowerBound)
            page.insert(contentsOf: "<div class=\"\(kind)\">", at: open.upperBound)
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

    /// True when the HTML paints backgrounds of its own: a designed mail, kept as designed.
    static func isDesigned(_ html: String) -> Bool {
        let patterns = [
            #"\bbgcolor\s*="#,
            #"(?<![-\w])background(-color|-image)?\s*[:=]\s*(?!\s*(transparent|none|inherit|initial|unset|rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\)))"#,
        ]
        return patterns.contains { html.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// True when the HTML sets text colours of its own (but, see `isDesigned`, no backgrounds).
    static func setsTextColors(_ html: String) -> Bool {
        let patterns = [
            #"<font[^>]*\bcolor\s*="#,
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

            body { padding: 14px 20px 28px; }
            .m42-card { background: #ffffff; color: #1d1d1f; color-scheme: light; border-radius: 12px; padding: 16px;
                        overflow-x: auto; box-shadow: 0 1px 3px rgba(0,0,0,.18); }
            @media (prefers-color-scheme: dark) {
              /* Gmail-style dark mode: invert the whole card, then invert the pictures back so photos keep their colours. */
              .m42-card { filter: invert(0.9) hue-rotate(180deg); box-shadow: none; }
              .m42-card img, .m42-card picture, .m42-card video, .m42-card canvas, .m42-card svg image,
              .m42-card [style*="background-image"] { filter: invert(1) hue-rotate(180deg); }
            }
            """
        }
        return common + """

        body { padding: 16px 24px 32px; }
        .m42-plain { max-width: 72ch; color: var(--w42-text-primary); font-family: var(--w42-font-family, -apple-system, system-ui);
               font-size: 15px; line-height: 1.6; overflow-wrap: anywhere; }
        /* Mail that only sets text colours: the theme's text colour wins (a dark grey on a dark theme can't be read). */
        .m42-force, .m42-force * { color: var(--w42-text-primary) !important; }
        .m42-plain a, .m42-plain a *, .m42-force a, .m42-force a * { color: var(--w42-accent, var(--w42-primary, #0a84ff)) !important; text-decoration: none; }
        .m42-plain a:hover { text-decoration: underline; }
        .m42-plain p { margin: 0 0 12px; }
        /* The CLI writes plain-text mail inside <pre style="font:-apple-system-body">: that inline style would win. */
        .m42-plain pre { white-space: pre-wrap !important; font: inherit !important; margin: 0; }
        .m42-plain blockquote { margin: 8px 0; padding: 2px 0 2px 14px; border-left: 3px solid var(--w42-accent, var(--w42-primary, #0a84ff));
                     color: var(--w42-text-secondary, var(--w42-text-primary)); }
        .m42-plain blockquote, .m42-plain blockquote * { color: var(--w42-text-secondary, var(--w42-text-primary)) !important; }
        details.m42-quote { margin: 10px 0; }
        details.m42-quote > summary { display: inline-block; cursor: pointer; list-style: none; font-size: 13px; padding: 2px 10px;
                     border-radius: 999px; background: var(--w42-chip, rgba(128,128,128,.18)); color: var(--w42-text-secondary, inherit); }
        details.m42-quote > summary::-webkit-details-marker { display: none; }
        details.m42-quote[open] > summary { margin-bottom: 6px; }
        .m42-plain table { max-width: 100%; }
        """
    }
}
