## test_inline_parser.nim
## Phase 2 — the inline parser.
##
## Ported from `InlineParserTests.swift` and `InlineSpanDensityTests.swift`.
## Ranges are relative to the parsed string.
##
## The node here is a flat record rather than Swift's enum with associated
## values, so the expectations are built with small constructors instead of
## `.emphasis(…)` cases. The geometry asserted is the same.

import std/unittest
import markdownengine

proc r(location, length: int): Range = rng(location, length)

proc txt(location, length: int): InlineNode =
  InlineNode(kind: inText, range: r(location, length))

proc code(range, content: Range): InlineNode =
  InlineNode(kind: inCode, range: range, contentRange: content)

proc emph(kind: EmphasisKind, range: Range, markers: seq[Range],
          children: seq[InlineNode]): InlineNode =
  InlineNode(kind: inEmphasis, range: range, emphasis: kind,
             contentRange: rng(maxRange(markers[0]),
                               markers[1].location - maxRange(markers[0])),
             markers: markers, children: children)

proc link(range, textRange, url: Range, markers: seq[Range],
          children: seq[InlineNode]): InlineNode =
  InlineNode(kind: inLink, range: range, contentRange: textRange,
             urlRange: url, markers: markers, children: children)

proc image(range, alt, url: Range, markers: seq[Range]): InlineNode =
  InlineNode(kind: inImage, range: range, contentRange: alt, urlRange: url,
             markers: markers)

proc wiki(range, name: Range, id: Range, hasID: bool,
          markers: seq[Range]): InlineNode =
  InlineNode(kind: inWikiLink, range: range, contentRange: name,
             idRange: id, hasID: hasID, markers: markers)

proc embed(range, target: Range, markers: seq[Range]): InlineNode =
  InlineNode(kind: inImageEmbed, range: range, contentRange: target,
             markers: markers)

proc latex(range, content: Range, markers: seq[Range]): InlineNode =
  InlineNode(kind: inInlineLatex, range: range, contentRange: content,
             markers: markers)

proc esc(range, character, marker: Range): InlineNode =
  InlineNode(kind: inEscape, range: range, contentRange: character,
             markers: @[marker])

proc extNode(id: string, range: Range, markers: seq[Range],
             children: seq[InlineNode]): InlineNode =
  InlineNode(kind: inExt, extensionID: id, range: range,
             contentRange: rng(maxRange(markers[0]),
                               markers[1].location - maxRange(markers[0])),
             markers: markers, children: children)

let strikeRegistry = initRegistry(@[newStrikethroughExtension()])
let highlightRegistry = initRegistry(@[newHighlightExtension()])

proc strike(range: Range, markers: seq[Range],
            children: seq[InlineNode]): InlineNode =
  extNode(strikethroughExtensionID, range, markers, children)

proc hi(range: Range, markers: seq[Range],
        children: seq[InlineNode]): InlineNode =
  extNode(highlightExtensionID, range, markers, children)

suite "inline parser — text and code":

  test "empty string yields no nodes":
    check parseInline("").len == 0

  test "plain text is a single text node":
    check parseInline("hello") == @[txt(0, 5)]

  test "a code span splits the surrounding text":
    check parseInline("a `code` b") ==
      @[txt(0, 2), code(r(2, 6), r(3, 4)), txt(8, 2)]

  test "an unclosed backtick run stays literal text":
    check parseInline("a `b") == @[txt(0, 4)]

  test "markdown-looking text inside code remains inert":
    check parseInline("`[a](b)`") == @[code(r(0, 8), r(1, 6))]

suite "inline parser — emphasis":

  test "single asterisks give italic":
    check parseInline("*x*") ==
      @[emph(ekItalic, r(0, 3), @[r(0, 1), r(2, 1)], @[txt(1, 1)])]

  test "double asterisks give bold":
    check parseInline("**x**") ==
      @[emph(ekBold, r(0, 5), @[r(0, 2), r(3, 2)], @[txt(2, 1)])]

  test "triple asterisks give bold+italic":
    check parseInline("***x***") ==
      @[emph(ekBoldItalic, r(0, 7), @[r(0, 3), r(4, 3)], @[txt(3, 1)])]

  test "nested emphasis builds a tree":
    check parseInline("**a *b* c**") == @[
      emph(ekBold, r(0, 11), @[r(0, 2), r(9, 2)], @[
        txt(2, 2),
        emph(ekItalic, r(4, 3), @[r(4, 1), r(6, 1)], @[txt(5, 1)]),
        txt(7, 2)])]

  test "intraword asterisks still emphasize":
    check parseInline("a*b*c") == @[
      txt(0, 1),
      emph(ekItalic, r(1, 3), @[r(1, 1), r(3, 1)], @[txt(2, 1)]),
      txt(4, 1)]

  test "single underscores give italic":
    check parseInline("_x_") ==
      @[emph(ekItalic, r(0, 3), @[r(0, 1), r(2, 1)], @[txt(1, 1)])]

  test "intraword underscores stay literal (GFM)":
    check parseInline("a_b_c") == @[txt(0, 5)]

  test "emphasis wraps a code span":
    check parseInline("*a `c` b*") == @[
      emph(ekItalic, r(0, 9), @[r(0, 1), r(8, 1)], @[
        txt(1, 2), code(r(3, 3), r(4, 1)), txt(6, 2)])]

  test "delimiters inside a code span are ignored":
    check parseInline("`*x*`") == @[code(r(0, 5), r(1, 3))]

suite "inline parser — links, images, wiki-links":

  test "plain wiki-link":
    check parseInline("[[Name]]") ==
      @[wiki(r(0, 8), r(2, 4), r(0, 0), false, @[r(0, 2), r(6, 2)])]

  test "wiki-link with id":
    check parseInline("[[Name|abc]]") ==
      @[wiki(r(0, 12), r(2, 4), r(7, 3), true, @[r(0, 2), r(10, 2)])]

  test "image embed":
    check parseInline("![[Pic]]") ==
      @[embed(r(0, 8), r(3, 3), @[r(0, 3), r(6, 2)])]

  test "markdown link, text recursively parsed":
    check parseInline("[text](url)") == @[
      link(r(0, 11), r(1, 4), r(7, 3),
           @[r(0, 1), r(5, 1), r(6, 1), r(10, 1)], @[txt(1, 4)])]

  test "markdown link permits inline code inside its label":
    check parseInline("[`App`](/tmp/App.swift:56)") == @[
      link(r(0, 26), r(1, 5), r(8, 17),
           @[r(0, 1), r(6, 1), r(7, 1), r(25, 1)],
           @[code(r(1, 5), r(2, 3))])]

  test "markdown link permits multiple inline code spans in its label":
    check parseInline("[`a` and `b`](u)") == @[
      link(r(0, 16), r(1, 11), r(14, 1),
           @[r(0, 1), r(12, 1), r(13, 1), r(15, 1)],
           @[code(r(1, 3), r(2, 1)), txt(4, 5), code(r(9, 3), r(10, 1))])]

  test "a claimed span crossing a link-label boundary rejects the link":
    check parseInline("[a `b](u)`") ==
      @[txt(0, 3), code(r(3, 7), r(4, 5))]

  test "markdown link permits escaped punctuation inside its label":
    check parseInline(r"[\*](u)") == @[
      link(r(0, 7), r(1, 2), r(5, 1),
           @[r(0, 1), r(3, 1), r(4, 1), r(6, 1)],
           @[esc(r(1, 2), r(2, 1), r(1, 1))])]

  test "link URL keeps balanced parentheses":
    check parseInline("[a](b(c))") == @[
      link(r(0, 9), r(1, 1), r(4, 4),
           @[r(0, 1), r(2, 1), r(3, 1), r(8, 1)], @[txt(1, 1)])]

  test "image":
    check parseInline("![alt](u)") ==
      @[image(r(0, 9), r(2, 3), r(7, 1),
              @[r(0, 2), r(5, 1), r(6, 1), r(8, 1)])]

  test "emphasis inside link text":
    check parseInline("[*x*](u)") == @[
      link(r(0, 8), r(1, 3), r(6, 1),
           @[r(0, 1), r(4, 1), r(5, 1), r(7, 1)],
           @[emph(ekItalic, r(1, 3), @[r(1, 1), r(3, 1)], @[txt(2, 1)])])]

  test "emphasis wraps a link":
    check parseInline("*[a](b)*") == @[
      emph(ekItalic, r(0, 8), @[r(0, 1), r(7, 1)], @[
        link(r(1, 6), r(2, 1), r(5, 1),
             @[r(1, 1), r(3, 1), r(4, 1), r(6, 1)], @[txt(2, 1)])])]

suite "inline parser — inline LaTeX":

  test "inline math":
    check parseInline("$a+b$") ==
      @[latex(r(0, 5), r(1, 3), @[r(0, 1), r(4, 1)])]

  test "currency-looking dollars are not math":
    check parseInline("$50$") == @[txt(0, 4)]

  test "a dollar span that would cross a code span is not math":
    check parseInline("$x `c` y$") ==
      @[txt(0, 3), code(r(3, 3), r(4, 1)), txt(6, 3)]

suite "inline parser — strikethrough extension":

  test "without a registered extension, tildes stay literal text":
    check parseInline("~~x~~") == @[txt(0, 5)]

  test "strikethrough, content recursively parsed":
    check parseInline("~~x~~", strikeRegistry) ==
      @[strike(r(0, 5), @[r(0, 2), r(3, 2)], @[txt(2, 1)])]

  test "triple tildes do not strike":
    check parseInline("~~~x~~~", strikeRegistry) == @[txt(0, 7)]

  test "a closer must not extend a longer run":
    check parseInline("~~abc~~~", strikeRegistry) == @[txt(0, 8)]

  test "strikethrough wraps emphasis":
    check parseInline("~~*x*~~", strikeRegistry) == @[
      strike(r(0, 7), @[r(0, 2), r(5, 2)],
             @[emph(ekItalic, r(2, 3), @[r(2, 1), r(4, 1)], @[txt(3, 1)])])]

suite "inline parser — highlight extension":

  test "without a registered extension, equals stay literal text":
    check parseInline("==x==") == @[txt(0, 5)]

  test "highlight, content recursively parsed":
    check parseInline("==x==", highlightRegistry) ==
      @[hi(r(0, 5), @[r(0, 2), r(3, 2)], @[txt(2, 1)])]

  test "triple equals do not highlight":
    check parseInline("===x===", highlightRegistry) == @[txt(0, 7)]

  test "a trailing third equals stays plain text":
    check parseInline("==abc===", highlightRegistry) ==
      @[hi(r(0, 7), @[r(0, 2), r(5, 2)], @[txt(2, 3)]), txt(7, 1)]

  test "highlight wraps emphasis":
    check parseInline("==*x*==", highlightRegistry) == @[
      hi(r(0, 7), @[r(0, 2), r(5, 2)],
         @[emph(ekItalic, r(2, 3), @[r(2, 1), r(4, 1)], @[txt(3, 1)])])]

  test "a lone equals inside content aborts the candidate":
    check parseInline("==a=b==", highlightRegistry) == @[txt(0, 7)]

  test "highlight never crosses a code span":
    # The backtick run is claimed first; the == candidate overlapping it loses.
    check parseInline("==a `b==` c", highlightRegistry) ==
      @[txt(0, 4), code(r(4, 5), r(5, 3)), txt(9, 2)]

suite "inline parser — extension interplay":

  test "an extension sharing a built-in trigger char gets its chance":
    # `$50$` is rejected by the built-in math heuristic (currency); a
    # registered `$…$` extension must still match on the fall-through.
    let registry = initRegistry(@[newExtension(
      "dollar-span", inline = initInlineSyntax("$", "$", parsesContent = false),
      hasInline = true)])
    let nodes = parseInline("$50$", registry)
    check nodes.len == 1
    check nodes[0].kind == inExt
    check nodes[0].extensionID == "dollar-span"
    # And the built-in still wins when it matches: real math parses as latex.
    let mathNodes = parseInline("$x^2 + y$", registry)
    check mathNodes.len == 1
    check mathNodes[0].kind == inInlineLatex

  test "both extensions registered: tildes and equals coexist":
    let registry = initRegistry(@[newHighlightExtension(),
                                  newStrikethroughExtension()])
    let nodes = parseInline("~~a~~ ==b==", registry)
    check nodes.len == 3                       # strike, " ", highlight
    check nodes[0].extensionID == strikethroughExtensionID
    check nodes[2].extensionID == highlightExtensionID

suite "inline parser — backslash escapes":

  test "escaped punctuation becomes an escape node":
    check parseInline(r"\*x") == @[esc(r(0, 2), r(1, 1), r(0, 1)), txt(2, 1)]

  test "escaped asterisks do not emphasize":
    check parseInline(r"\*a\*") ==
      @[esc(r(0, 2), r(1, 1), r(0, 1)), txt(2, 1), esc(r(3, 2), r(4, 1), r(3, 1))]

  test "a backslash inside a code span is literal":
    check parseInline(r"`\*`") == @[code(r(0, 4), r(1, 2))]

suite "inline parser — span density":

  test "claimed-range probes stay linear in span count":
    # The quantity is a pure function of the input, which is the point: it
    # reads the same on a laptop and on a loaded CI runner, and quadratic vs.
    # linear differ by orders of magnitude rather than by 1.4x.
    proc probesFor(spans: int): int =
      var line = ""
      for i in 0 ..< spans: line.add "`c` "
      var cost = InlineParseCost()
      discard parseInline(line, emptyRegistry(), cost)
      cost.claimedProbes

    let small = probesFor(50)
    let large = probesFor(200)
    # Four times the spans must not cost sixteen times the probes.
    check large < small * 8

  test "containment tests stay linear too":
    proc testsFor(spans: int): int =
      var line = ""
      for i in 0 ..< spans: line.add "*e* "
      var cost = InlineParseCost()
      discard parseInline(line, emptyRegistry(), cost)
      cost.containmentTests

    check testsFor(200) < testsFor(50) * 8
