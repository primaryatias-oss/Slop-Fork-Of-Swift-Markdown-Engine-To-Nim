## test_html.nim
## The two clipboard conversions: Markdown → HTML for rich copy, and the
## lenient HTML → Markdown for smart paste.
##
## Ported from `MarkdownHTMLRendererTests.swift`,
## `HTMLToMarkdownConverterTests.swift`, `DirectiveHTMLTests.swift` and the
## portable half of `MarkdownPasteboardWriterTests.swift` (the web-archive and
## RTF flavours are AppKit pasteboard formats with no Linux counterpart; the
## HTML transforms they are built from are tested here).

import std/[unittest, strutils]
import markdownengine
import ./directive_fixtures

proc html(md: string): string = renderHTML(md)

proc md(source: string): string =
  let (converted, ok) = markdownFromHTML(source)
  if ok: converted else: "\0<not html>"

suite "markdown to HTML":

  test "core element mapping":
    check html("# Title") == "<h1>Title</h1>"
    check html("*i*") == "<p><em>i</em></p>"
    check html("**b**") == "<p><strong>b</strong></p>"
    check html("`code`") == "<p><code>code</code></p>"
    check html("[text](http://x.com)") ==
      "<p><a href=\"http://x.com\">text</a></p>"
    check html("> hello") == "<blockquote>hello</blockquote>"
    check html("a < b & c > d") == "<p>a &lt; b &amp; c &gt; d</p>"

  test "fenced code block":
    check html("```swift\nlet x = 1\n```") ==
      "<pre><code class=\"language-swift\">let x = 1</code></pre>"
    check html("```\nplain\n```") == "<pre><code>plain</code></pre>"
    check html("```\n<a> & <b>\n```") ==
      "<pre><code>&lt;a&gt; &amp; &lt;b&gt;</code></pre>"

  test "unordered and ordered lists":
    check html("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>"
    check html("1. a\n2. b") == "<ol>\n<li>a</li>\n<li>b</li>\n</ol>"

  test "an indented item nests inside its parent li instead of flattening":
    check html("- a\n\t- b") ==
      "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>"
    check html("- a\n\t1. b\n- c") ==
      "<ul>\n<li>a\n<ol>\n<li>b</li>\n</ol>\n</li>\n<li>c</li>\n</ul>"

  test "a list that opens deeper than it continues keeps every item":
    check html("  - b\n- c") ==
      "<ul>\n<li>b</li>\n</ul>\n<ul>\n<li>c</li>\n</ul>"
    check html("  - b\n    - b2\n- c\n  - d") ==
      "<ul>\n<li>b\n<ul>\n<li>b2</li>\n</ul>\n</li>\n</ul>\n" &
      "<ul>\n<li>c\n<ul>\n<li>d</li>\n</ul>\n</li>\n</ul>"

  test "a task list keeps GFM checkbox markup":
    check html("- [ ] todo\n- [x] done") ==
      "<ul>\n<li><input type=\"checkbox\" disabled> todo</li>\n" &
      "<li><input type=\"checkbox\" checked disabled> done</li>\n</ul>"

  test "a thematic break becomes hr":
    check "<hr" in html("---")

  test "a GFM table":
    let rendered = html("| A | B |\n| --- | --- |\n| 1 | 2 |")
    check "<table" in rendered
    check "<th>A</th>" in rendered
    check "<th>B</th>" in rendered
    check "<td>1</td>" in rendered
    check "<td>2</td>" in rendered

  # The editor's styler makes bare URLs clickable, but rich-paste consumers
  # take the HTML flavour verbatim and run no link detection of their own — so
  # the renderer must emit a real anchor for everything the editor shows as a
  # link.

  test "bare URLs and emails autolink":
    check html("https://example.com") ==
      "<p><a href=\"https://example.com\">https://example.com</a></p>"
    check html("see https://example.com/a?b=1&c=2 now") ==
      "<p>see <a href=\"https://example.com/a?b=1&amp;c=2\">" &
      "https://example.com/a?b=1&amp;c=2</a> now</p>"
    # `https`, where the Swift's `NSDataDetector` supplied `http` for a
    # scheme-less host — see `urlFromDetected`. The rendered text is
    # untouched either way; only the href differs.
    check html("www.example.com") ==
      "<p><a href=\"https://www.example.com\">www.example.com</a></p>"
    check html("mail me@example.com") ==
      "<p>mail <a href=\"mailto:me@example.com\">me@example.com</a></p>"

  test "autolink reaches nested inline and re-parsed blockquote content":
    check html("**https://example.com**") ==
      "<p><strong><a href=\"https://example.com\">https://example.com</a>" &
      "</strong></p>"
    check html("> https://example.com") ==
      "<blockquote><a href=\"https://example.com\">https://example.com</a>" &
      "</blockquote>"

  test "no autolink inside code spans or an explicit link's title":
    check html("`https://example.com`") ==
      "<p><code>https://example.com</code></p>"
    # A URL-shaped title must not nest a second anchor inside the link's own.
    check html("[https://example.com](https://example.com)") ==
      "<p><a href=\"https://example.com\">https://example.com</a></p>"

suite "HTML to markdown":

  test "core element mapping":
    check md("<h1>Title</h1>") == "# Title"
    check md("<p><strong>bold</strong> and <em>italic</em></p>") ==
      "**bold** and *italic*"
    check md("<a href=\"https://example.com\">link</a>") ==
      "[link](https://example.com)"
    check md("<p>Use <code>let x</code> here</p>") == "Use `let x` here"
    check md("<pre><code class=\"language-swift\">let x = 1</code></pre>") ==
      "```swift\nlet x = 1\n```"
    check md("<blockquote>quoted</blockquote>") == "> quoted"
    check md("<hr>") == "----"

  test "unordered and ordered lists":
    check md("<ul><li>One</li><li>Two</li><li>Three</li></ul>") ==
      "- One\n- Two\n- Three"
    check md("<ol><li>Alpha</li><li>Beta</li><li>Gamma</li></ol>") ==
      "1. Alpha\n2. Beta\n3. Gamma"

  test "a nested ul inside an li indents":
    check md("<ul><li>Parent<ul><li>Child</li></ul></li></ul>") ==
      "- Parent\n\t- Child"

  test "a sublist placed NEXT TO its li indents instead of vanishing":
    # Apple Mail and Notes indent a bullet by appending the sublist as a
    # SIBLING of the <li>. Invalid per spec, rendered right by every browser.
    check md("<ul><li>A</li><ul><li>B</li><li>C</li></ul></ul>") ==
      "- A\n\t- B\n\t- C"
    check md("<ul><li>A</li><ul><li>B</li><ul><li>C</li></ul></ul></ul>") ==
      "- A\n\t- B\n\t\t- C"
    check md("<ul><li>A</li><ol><li>B</li></ol></ul>") == "- A\n\t1. B"
    # The sibling sublist must not consume the parent's numbering.
    check md("<ol><li>A</li><ul><li>B</li></ul><li>C</li></ol>") ==
      "1. A\n\t- B\n2. C"

  test "a nested list survives the copy to paste round trip":
    let markdown = "- A\n\t- B\n\t\t- C\n- D"
    check md(renderHTML(markdown)) == markdown

  test "a checkbox li becomes a GFM task item":
    check md("<ul><li><input type=\"checkbox\">Todo</li>" &
             "<li><input type=\"checkbox\" checked>Done</li></ul>") ==
      "- [ ] Todo\n- [x] Done"
    # Chat UIs emit task lists as literal "[ ] text" in plain <li>s; the
    # escaped brackets must be reclaimed as a task marker.
    check md("<ul><li>[ ] Task one</li><li>[x] Done task</li></ul>") ==
      "- [ ] Task one\n- [x] Done task"
    # …but brackets elsewhere stay escaped — no accidental checkboxes.
    check md("<ol><li>[ ] not a task</li></ol>") == "1. \\[ \\] not a task"

  test "messy inline styles and meta are unwrapped; non-HTML is rejected":
    check md("<meta charset=\"utf-8\"><ul>" &
             "<li><span style=\"color:red\">Live-Neuberechnung</span></li>" &
             "<li>Inline-Rendering</li></ul>") ==
      "- Live-Neuberechnung\n- Inline-Rendering"
    check markdownFromHTML("just text")[1] == false

  test "entities, ordered-list start, breaks, hrefs and escaping":
    check md("<p>&#123;a&#125; &#x1F600;</p>") == "{a} \u{1F600}"
    check md("<ol start=\"5\"><li>a</li><li>b</li></ol>") == "5. a\n6. b"
    check md("<p>a<br>b</p>") == "a  \nb"
    check md("<ul><li>a<br>b</li></ul>") == "- a  \n  b"
    check md("<a href=\"/my file.md\">doc</a>") == "[doc](</my file.md>)"
    check md("<p>1. First</p>") == "1\\. First"
    check md("<p># not a heading</p>") == "\\# not a heading"
    check md("<p>*stars*</p>") == "\\*stars\\*"
    check md("<p><em>x</em></p>") == "*x*"

  test "block children inside an li stay in the item":
    check md("<li><p>First</p><p>Second</p></li>") == "- First\n\n  Second"
    check md("<ul><li>Parent<div><ul><li>Child</li></ul></div></li></ul>") ==
      "- Parent\n\t- Child"

  test "a full document wrapper still converts its blocks":
    # Some exporters put a whole document on the clipboard; the wrapper tags
    # must be transparent, and head/style must not leak as text.
    check md("<meta charset='utf-8'><html><head><style>td{}</style></head><body>" &
             "<table>\n<thead>\n<tr>\n<th>Feld</th>\n<th>Wert</th>\n</tr>\n</thead>\n" &
             "<tbody>\n<tr>\n<td>Arbeitgeber</td>\n<td>CF GmbH</td>\n</tr>\n" &
             "</tbody>\n</table></body></html>") ==
      "| Feld | Wert |\n|---|---|\n| Arbeitgeber | CF GmbH |"

  test "a table inside unknown web components stays a table":
    # Some assistants wrap every table in custom elements. Unknown tags used
    # to fold into the inline run, which unwrapped the <table> too and glued
    # every cell into one line of bold text.
    check md("<meta charset='utf-8'><div class=\"horizontal-scroll-wrapper\">" &
             "<div class=\"table-block-component\"><response-element class=\"no-md\">" &
             "<table-block><div class=\"table-block\">" &
             "<div class=\"table-content md-content\"><table>" &
             "<thead><tr><td><strong>Land</strong></td><td><strong>QoQ</strong></td></tr></thead>" &
             "<tbody><tr><td><span><b>China</b></span></td><td><span><b>+0,9 %</b></span></td></tr></tbody>" &
             "</table></div><div class=\"table-footer\"></div></div></table-block>" &
             "</response-element></div></div>") ==
      "| **Land** | **QoQ** |\n|---|---|\n| **China** | **+0,9 %** |"

  test "block content inside an unknown or inline wrapper keeps its structure":
    check md("<section><ul><li>A</li><li>B</li></ul></section>") == "- A\n- B"
    check md("<span><table><tr><td>a</td><td>b</td></tr>" &
             "<tr><td>1</td><td>2</td></tr></table></span>") ==
      "| a | b |\n|---|---|\n| 1 | 2 |"
    check md("<ul><li>Parent<x-wrap><ul><li>Child</li></ul></x-wrap></li></ul>") ==
      "- Parent\n\t- Child"

  test "an unknown wrapper around inline content stays inline":
    check md("<p>a <x-chip>b</x-chip> c</p>") == "a b c"
    check md("<h2>Title <x-badge><b>new</b></x-badge></h2>") == "## Title **new**"

  test "bare li fragments become one tight bullet list":
    check md("<meta charset='utf-8'><li class=\"x\"><strong>A:</strong> one</li>\n" &
             "  <li>two</li>") == "- **A:** one\n- two"

suite "directives in HTML":

  let directives = @[newFontDirective(), newColorDirective(), markerDirective()]

  proc withDirectives(markdown: string): string =
    renderHTML(markdown, directives = directives)

  test "a container directive wraps its body":
    check "font-size:18" in withDirectives("@font(size: 18){hello}")
    check ">hello<" in withDirectives("@font(size: 18){hello}")

  test "body markup renders inside the wrapper":
    check "<strong>bold</strong>" in withDirectives("@font(size: 18){**bold**}")

  test "a self-contained directive renders its own markup":
    check "<hr class=\"marker\" />" in withDirectives("@marker")

  test "a directive with no styling arguments still emits its body":
    check "hello" in withDirectives("@font(){hello}")

  test "nested directives nest in the output":
    let rendered = withDirectives("@font(size: 18){@font(weight: bold){x}}")
    check "font-size:18" in rendered
    check "font-weight:bold" in rendered

  test "without registration the source copies literally":
    check "@font(size: 18){hello}" in renderHTML("@font(size: 18){hello}")

  test "registering directives does not disturb ordinary markdown":
    let markdown = "# Title\n\nSome **bold** and a [link](https://example.com).\n"
    check withDirectives(markdown) == renderHTML(markdown)

  test "an extension and a directive coexist in one render":
    let rendered = renderHTML("==hi== and @font(size: 18){there}",
                              extensions = @[newHighlightExtension()],
                              directives = directives)
    check "<mark>hi</mark>" in rendered
    check "font-size:18" in rendered

suite "clipboard flavours":

  test "rich flavours strip checkbox inputs to plain bullets":
    let body = "<ul>\n<li><input type=\"checkbox\" disabled> open</li>\n" &
               "<li><input type=\"checkbox\" checked disabled> done</li>\n</ul>"
    check stripTaskCheckboxes(body) == "<ul>\n<li>open</li>\n<li>done</li>\n</ul>"

  test "a rule stand-in replaces hr for flavours that cannot carry one":
    check ruleStandInBody("<p>a</p>\n<hr>\n<p>b</p>") ==
      "<p>a</p>\n<p>" & rtfRuleStandIn & "</p>\n<p>b</p>"

  test "a bare URL reaches the rich flavours as a real anchor":
    # Mail and Outlook run no link detection of their own.
    let payload = makeClipboardPayload("https://example.com")
    check "<a href=\"https://example.com\">https://example.com</a>" in payload.html

  test "the private flavour carries the selection verbatim":
    let markdown = "A [[Note|abc-123]] and `code`.\n"
    let payload = makeClipboardPayload(markdown)
    check payload.rawMarkdown == markdown
    check payload.plain == markdown

  test "a paste prefers the private flavour over derived HTML":
    let (text, ok) = resolvePaste("**raw**", true, "<p>html</p>", true, "plain")
    check ok
    check text == "**raw**"

  test "a paste falls back to HTML, then to plain text":
    check resolvePaste("", false, "<p><em>x</em></p>", true, "plain") == ("*x*", true)
    check resolvePaste("", false, "not html at all", true, "plain") == ("plain", true)
    check resolvePaste("", false, "", false, "plain") == ("plain", true)
    check resolvePaste("", false, "", false, "")[1] == false
