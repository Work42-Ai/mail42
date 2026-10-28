import Testing
@testable import Mail42Kit

@Suite struct HTMLTextTests {

    @Test func dropsTagsScriptsStylesAndTheHead() {
        let text = HTMLText.convert("""
        <html><head><title>Title</title><style>.a{color:red}</style></head>
        <body><script>evil()</script><p>Hello <b>world</b></p></body></html>
        """)
        #expect(text == "Hello world")
    }

    @Test func turnsBlockTagsAndBreaksIntoLines() {
        let text = HTMLText.convert("<p>One</p><p>Two<br>Three</p><ul><li>a</li><li>b</li></ul><div>End</div>")
        #expect(text == "One\nTwo\nThree\na\nb\nEnd" || text == "One\n\nTwo\nThree\n\na\nb\n\nEnd" || text.split(separator: "\n").map(String.init).filter { !$0.isEmpty } == ["One", "Two", "Three", "a", "b", "End"])
    }

    @Test func decodesEntities() {
        #expect(HTMLText.convert("Tom &amp; Jerry &lt;3 &quot;hi&quot; &#169; &#x1F600; caf&eacute;") .hasPrefix("Tom & Jerry <3 \"hi\" © 😀"))
        #expect(HTMLText.convert("a&nbsp;&nbsp;b") == "a b")
    }

    @Test func collapsesWhitespaceAndKeepsAtMostOneBlankLine() {
        let text = HTMLText.convert("<p>a   \n   b</p>\n\n\n<p>c</p><p></p><p></p><p>d</p>")
        #expect(text.contains("a b"))
        #expect(!text.contains("\n\n\n"))
        #expect(text.hasSuffix("d"))
    }

    @Test func keepsLineBreaksInsidePre() {
        let text = HTMLText.convert("<pre>line1\nline2\n  indented</pre>")
        #expect(text.contains("line1\nline2\nindented") || text.contains("line1\nline2\n indented"))
    }

    @Test func tableCellsAreSeparatedByASpace() {
        let text = HTMLText.convert("<table><tr><td>Name</td><td>Qty</td></tr><tr><td>Pen</td><td>3</td></tr></table>")
        #expect(text.contains("Name Qty"))
        #expect(text.contains("Pen 3"))
    }

    @Test func survivesMalformedAndHostileInput() {
        #expect(HTMLText.convert("") == "")
        #expect(HTMLText.convert("<<<>>>").contains("<"))
        #expect(HTMLText.convert("<div").contains("<div"))
        #expect(HTMLText.convert("<script>never closed").isEmpty)
        #expect(HTMLText.convert("text <!-- unterminated").hasPrefix("text"))
    }

    @Test func findsWordsOnlyPresentInTheBody() {
        let text = HTMLText.convert("<div><span>The secret word is</span> <i>quokkabody</i>.</div>")
        #expect(text.contains("quokkabody"))
    }
}
