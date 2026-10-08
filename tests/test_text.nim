## test_text.nim
## The UTF-16 foundation: ranges, the text view over a `seq[uint16]`, and the
## line/paragraph walks every other pass is built on.
##
## Port-specific. The Swift got all of this from `NSString` and `NSRange` for
## free, so there was nothing to test — which also means a bug here would have
## no upstream counterpart to compare against. The semantics pinned below are
## `NSString`'s, because every range in the engine was written against them.

import std/[unittest, sequtils, sets]
import markdownengine

suite "ranges":

  test "the basics":
    check maxRange(rng(3, 4)) == 7
    check rng(0, 0).isEmpty
    check not rng(0, 1).isEmpty
    check notFoundRange().location == NotFound
    check rng(2, 3).contains(2)
    check rng(2, 3).contains(4)
    check not rng(2, 3).contains(5)

  test "containment is about ranges, not points":
    check containsRange(rng(0, 10), rng(2, 3))
    check containsRange(rng(0, 10), rng(0, 10))
    check not containsRange(rng(0, 10), rng(8, 5))
    # An empty range at the boundary is still contained.
    check containsRange(rng(0, 10), rng(10, 0))

  test "intersection and union":
    check intersection(rng(0, 5), rng(3, 5)) == rng(3, 2)
    check intersection(rng(0, 2), rng(5, 2)).length == 0
    check union(rng(0, 2), rng(5, 2)) == rng(0, 7)
    check intersects(rng(0, 5), rng(4, 2))
    check not intersects(rng(0, 5), rng(5, 2))     # touching is not crossing

  test "clamping drops what falls off the end":
    check clamped(rng(2, 10), 6) == rng(2, 4)
    check clamped(rng(8, 2), 6).length == 0

  test "sorting is by location, then by length":
    check sortRanges(@[rng(5, 1), rng(0, 3), rng(0, 1)]) ==
      @[rng(0, 1), rng(0, 3), rng(5, 1)]

  test "normalising scopes merges, orders and rejects":
    check normalizeScopes(@[rng(5, 3), rng(0, 2), rng(1, 2)], 20) ==
      @[rng(0, 3), rng(5, 3)]
    # Touching ranges merge; a gap keeps them apart.
    check normalizeScopes(@[rng(0, 2), rng(2, 2)], 20) == @[rng(0, 4)]
    check normalizeScopes(@[rng(0, 2), rng(3, 2)], 20) == @[rng(0, 2), rng(3, 2)]
    # Malformed geometry is dropped rather than clamped.
    check normalizeScopes(@[rng(-1, 2), rng(0, 0), notFoundRange(),
                            rng(19, 5), rng(high(int) - 1, 4)], 20).len == 0

suite "UTF-16 text":

  test "lengths are UTF-16 units, not runes or bytes":
    check utf16Len("abc") == 3
    check utf16Len("é") == 1                     # one BMP unit, two UTF-8 bytes
    check utf16Len("\u{1F600}") == 2             # a surrogate pair

  test "round trips survive astral planes":
    for source in ["", "plain", "é\u{1F600}ü", "a\nb\r\nc"]:
      checkpoint(source)
      check $initText(source) == source

  test "substring works in UTF-16 coordinates":
    let t = initText("a\u{1F600}b")
    check t.len == 4
    check t.substring(rng(0, 1)) == "a"
    check t.substring(rng(1, 2)) == "\u{1F600}"
    check t.substring(rng(3, 1)) == "b"

  test "search returns UTF-16 ranges":
    let t = initText("one two one")
    check t.rangeOf("two") == rng(4, 3)
    check t.rangeOf("one") == rng(0, 3)
    check t.rangeOf("one", rng(1, t.len - 1)) == rng(8, 3)
    check t.rangeOf("zzz").location == NotFound
    check t.contains("two")

suite "UTF-16 text — line and paragraph walks":

  test "a line range covers its own terminator":
    let t = initText("one\ntwo\nthree")
    check t.lineRange(rng(0, 0)) == rng(0, 4)
    check t.lineRange(rng(4, 0)) == rng(4, 4)
    check t.lineRange(rng(8, 0)) == rng(8, 5)    # no terminator at the end

  test "a line range already ending at a boundary does not swallow the next":
    # The bug this pins: a range whose end is exactly a line start used to
    # extend through the FOLLOWING line, so a heading's paragraph style landed
    # on the blank line after it and the document grew by a line's height on
    # every restyle.
    let t = initText("# H\n\nbody\n")
    check t.lineRange(rng(0, 4)) == rng(0, 4)
    check t.paragraphRange(rng(0, 4)) == rng(0, 4)

  test "a CRLF pair is one terminator":
    let t = initText("one\r\ntwo")
    check t.lineRange(rng(0, 0)) == rng(0, 5)
    check t.lineRange(rng(5, 0)) == rng(5, 3)

  test "U+2028 and U+2029 terminate a line":
    let t = initText("one\u{2028}two")
    check t.lineRange(rng(0, 0)) == rng(0, 4)

  test "a paragraph range stops at a hard break, not at a line separator":
    # `NSString` draws the line here: U+2028 ends a LINE, U+2029 and \n end a
    # PARAGRAPH. Everything scoped per paragraph depends on the distinction.
    let t = initText("one\u{2028}two\nthree")
    check t.paragraphRange(rng(0, 0)) == rng(0, 8)
    check t.lineRange(rng(0, 0)) == rng(0, 4)

  test "iterating line ranges tiles the region":
    let t = initText("a\nbb\nccc\n")
    let lines = t.lineRangesIn(t.fullRange)
    check lines == @[rng(0, 2), rng(2, 3), rng(5, 4)]
    var cursor = 0
    for line in lines:
      check line.location == cursor
      cursor = maxRange(line)
    check cursor == t.len

  test "trailing newlines trim off a block range":
    let t = initText("---\n\n")
    check t.trimmedTrailingNewlines(rng(0, 5)) == rng(0, 3)
    check t.trimmedTrailingNewlines(rng(0, 3)) == rng(0, 3)

  test "a blank range is whitespace only":
    let t = initText("  \t\n  x")
    check t.isBlankRange(rng(0, 4))
    check not t.isBlankRange(rng(0, 7))

suite "UTF-16 text — editing":

  test "replacing characters splices in UTF-16 coordinates":
    let t = initText("hello world")
    check utf16ToString(t.replacingCharacters(rng(6, 5), toUtf16("there"))) ==
      "hello there"
    check utf16ToString(t.replacingCharacters(rng(5, 0), toUtf16(","))) ==
      "hello, world"
    check utf16ToString(t.replacingCharacters(rng(5, 6), @[])) == "hello"

  test "a replacement spanning a surrogate pair keeps the text well formed":
    let t = initText("a\u{1F600}b")
    check utf16ToString(t.replacingCharacters(rng(1, 2), toUtf16("X"))) == "aXb"

suite "detection":

  test "the triple-backtick census counts runs, not characters":
    check tripleBacktickCount(initText("```")) == 1
    check tripleBacktickCount(initText("``")) == 0
    check tripleBacktickCount(initText("```\ncode\n```")) == 2
    check tripleBacktickCount(initText("``````")) == 2

  test "a location inside a fenced block is detected":
    let t = initText("before\n```\ncode\n```\nafter")
    let tokens = parseTokens(t)
    check isInsideCodeBlock(t.rangeOf("code").location, tokens)
    check not isInsideCodeBlock(t.rangeOf("before").location, tokens)
    check not isInsideCodeBlock(t.rangeOf("after").location, tokens)

  test "a location inside inline LaTeX is detected":
    let t = initText("sum $x^2 + y$ done")
    let tokens = parseTokens(t)
    check isInsideLatex(t.rangeOf("x^2").location, latexTokensOf(tokens))
    check not isInsideLatex(t.rangeOf("done").location, latexTokensOf(tokens))

  test "the active token set is the tokens the caret is inside":
    let t = initText("a **bold** b")
    let tokens = parseTokens(t)
    let active = computeActiveTokenIndices(caretAt(5), tokens, t)
    check active.len == 1
    check tokens[active.toSeq[0]].kind == tkBold
    check computeActiveTokenIndices(caretAt(0), tokens, t).len == 0

suite "auto-link detection":

  proc detected(text: string): seq[string] =
    let t = initText(text)
    detectUrls(t, t.fullRange).mapIt(t.substring(it))

  test "schemes, bare hosts and emails are found":
    check detected("see https://example.com/a?b=1 now") ==
      @["https://example.com/a?b=1"]
    check detected("go to www.example.com please") == @["www.example.com"]
    check detected("mail me@example.com now") == @["me@example.com"]

  test "trailing sentence punctuation is not part of the URL":
    check detected("visit example.com.") == @["example.com"]
    check detected("visit https://example.com, then") == @["https://example.com"]
    check detected("(see https://example.com)") == @["https://example.com"]

  test "a bare word with no TLD is not a host":
    check detected("just some words").len == 0
    check detected("version 1.2 shipped").len == 0

  test "the href gets a scheme when the source has none":
    let t = initText("www.example.com")
    check urlFromDetected(t, t.fullRange) == "https://www.example.com"
    let m = initText("me@example.com")
    check urlFromDetected(m, m.fullRange) == "mailto:me@example.com"
    let s = initText("http://example.com")
    check urlFromDetected(s, s.fullRange) == "http://example.com"
