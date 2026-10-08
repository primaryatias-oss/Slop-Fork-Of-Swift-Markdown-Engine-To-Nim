## test_ast.nim
## Phase 2.5 — the full AST pipeline (block parser + inline parser + the token
## adapter), and the scoped-parse contract the restyle depends on.
##
## Ported from `ASTPipelineTests.swift` plus the scoping cases that
## `normalizeScopes` has to survive.

import std/[unittest, sequtils, strutils]
import markdownengine

proc lineRangeOf(t: Utf16Text, needle: string): Range =
  t.lineRange(t.rangeOf(needle))

suite "AST pipeline — scoped parsing":

  test "a scoped list holds only the intersecting physical items":
    var lines = ""
    for i in 0 ..< 2000: lines.add "- [x] item " & $i & "\n"
    let t = initText(lines)
    let targetLine = t.lineRangeOf("- [x] item 1500")

    let nodes = parseDocument(t, @[targetLine], hasScope = true)
    check nodes.len == 1
    check nodes[0].kind == bnList
    check nodes[0].items.mapIt(it.range) == @[targetLine]

  test "scoped parsing normalizes overlapping and unordered scopes":
    let t = initText("- one\n- two\n- three\n- four\n")
    let second = t.lineRangeOf("- two")
    let fourth = t.lineRangeOf("- four")
    let overlappingSecond = rng(second.location + 1, second.length - 1)

    let nodes = parseDocument(t, @[fourth,
                                   rng(t.len + 1, 1),
                                   overlappingSecond,
                                   second,
                                   rng(0, 0)], hasScope = true)
    check nodes.len == 1
    check nodes[0].kind == bnList
    check nodes[0].items.mapIt(it.range) == @[second, fourth]

  test "scoped parsing rejects malformed ranges":
    let t = initText("- one\n- two\n- three\n")
    let second = t.lineRangeOf("- two")
    let nodes = parseDocument(t, @[rng(-1, 1),
                                   rng(high(int) - 1, 4),
                                   rng(t.len, 1),
                                   second], hasScope = true)
    check nodes.len == 1
    check nodes[0].kind == bnList
    check nodes[0].items.mapIt(it.range) == @[second]

  test "an unscoped parse covers every block":
    let t = initText("# H\n\npara\n\n- a\n")
    let nodes = parseDocument(t)
    check nodes.mapIt(it.kind) ==
      @[bnHeading, bnBlank, bnParagraph, bnBlank, bnList]

suite "AST pipeline — tokens":

  test "no inline markup tokens inside a fenced code block":
    let tokens = parseTokens("```swift\n*not italic* `not code`\n```\n")
    check tokens.len > 0
    check tokens.allIt(it.kind == tkCodeBlock)

  test "a link with balanced parens in the URL is one whole link token":
    let tokens = parseTokens("see [w](a(b)) end")
    let links = tokens.filterIt(it.kind == tkLink)
    check links.len == 1
    check links[0].range == rng(4, 9)

  test "no spurious latex token across code spans":
    let tokens = parseTokens("the `$a` and `$b` vars")
    check not tokens.anyIt(it.kind == tkInlineLatex)
    check tokens.countIt(it.kind == tkInlineCode) == 2

  test "block-level tokens survive alongside inline ones":
    let tokens = parseTokens("# Title *x*")
    check tokens.anyIt(it.kind == tkHeading)
    check tokens.anyIt(it.kind == tkItalic)

  test "a blockquote emits one token per quoted line":
    let tokens = parseTokens("> a\n> b\n")
    check tokens.countIt(it.kind == tkBlockquote) == 2

  test "an escape is its own token, and suppresses the emphasis":
    let tokens = parseTokens(r"\*a\*")
    check tokens.countIt(it.kind == tkBackslashEscape) == 2
    check not tokens.anyIt(it.kind == tkItalic)

  test "a registered extension contributes a span token carrying its id":
    let registry = initRegistry(@[newHighlightExtension()])
    let tokens = parseTokens(initText("a ==b== c"), registry)
    let spans = tokens.filterIt(it.kind == tkExtensionSpan)
    check spans.len == 1
    check spans[0].extensionID == highlightExtensionID

suite "AST pipeline — collectors":

  test "code ranges cover both fenced blocks and inline spans":
    let t = initText("`a`\n\n```\nb\n```\n")
    let ranges = collectCodeRanges(parseDocument(t))
    check ranges.len == 2
    check t.substring(ranges[0]) == "`a`"
    check t.substring(ranges[1]).startsWith("```")

  test "link ranges cover markdown links and wiki links":
    let t = initText("[a](b) and [[C]]")
    let ranges = collectLinkRanges(parseDocument(t))
    check ranges.mapIt(t.substring(it)) == @["[a](b)", "[[C]]"]

  test "checkbox ranges are the task markers only":
    let t = initText("- [ ] todo\n- [x] done\n")
    let ranges = collectCheckboxRanges(parseDocument(t))
    check ranges.mapIt(t.substring(it)) == @["[ ]", "[x]"]
