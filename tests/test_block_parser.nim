## test_block_parser.nim
## Phase 1 — the block-structure pass.
##
## Ported from `BlockParserTests.swift`, `PrecomputedBlocksTests.swift` and
## `FenceInteriorIncrementalTests.swift`. Each case pins an exact, *tiling*
## decomposition: every UTF-16 unit is covered exactly once, so a block that
## grows has to shrink its neighbour and the bug shows up here rather than
## three passes later as a mis-styled run.

import std/[unittest, sequtils, strutils]
import markdownengine

proc b(kind: BlockKind, location, length: int): Block =
  initBlock(kind, rng(location, length))

proc assertTiles(text: string) =
  ## The parsed blocks must tile `text` with no gaps and no overlaps.
  let blocks = computeBlocks(text)
  let total = utf16Len(text)
  if total == 0: return
  var cursor = 0
  for blk in blocks:
    check blk.range.location == cursor
    cursor = maxRange(blk.range)
  check cursor == total

suite "block parser":

  test "single line is one paragraph":
    check computeBlocks("hello world") == @[b(bkParagraph, 0, 11)]

  test "blank line separates blocks and the result tiles the whole string":
    let text = "a\n\nb"
    check computeBlocks(text) ==
      @[b(bkParagraph, 0, 2), b(bkBlank, 2, 1), b(bkParagraph, 3, 1)]
    assertTiles(text)

  test "consecutive plain lines merge into one paragraph":
    check computeBlocks("a\nb\nc") == @[b(bkParagraph, 0, 5)]

  test "ATX heading is its own block":
    let text = "# Title\n\nbody"
    check computeBlocks(text) ==
      @[b(bkHeading, 0, 8), b(bkBlank, 8, 1), b(bkParagraph, 9, 4)]
    assertTiles(text)

  test "thematic break is its own block":
    let text = "a\n\n---\n\nb"
    check computeBlocks(text) == @[
      b(bkParagraph, 0, 2), b(bkBlank, 2, 1), b(bkThematicBreak, 3, 4),
      b(bkBlank, 7, 1), b(bkParagraph, 8, 1)]
    assertTiles(text)

  test "fenced code block is a single opaque block":
    check computeBlocks("```\ncode\n```\n") == @[b(bkFencedCode, 0, 13)]

  test "an unclosed fence stays literal — blocks below are not swallowed":
    # ```\n then a table, a thematic break, block LaTeX and a link paragraph.
    # None of them may end up inside a code block.
    let text = "```\n\n|a|b|\n|-|-|\n|1|2|\n\n---\n\n$$x$$\n\n[l](u)"
    let blocks = computeBlocks(text)
    check not blocks.anyIt(it.kind == bkFencedCode)
    check blocks.anyIt(it.kind == bkTable)
    check blocks.anyIt(it.kind == bkThematicBreak)
    check blocks.anyIt(it.kind == bkBlockLatex)
    assertTiles(text)

  test "an unclosed fence merges into the paragraph it starts":
    check computeBlocks("```\n[l](u)") == @[b(bkParagraph, 0, 10)]
    check computeBlocks("a\n```swift") == @[b(bkParagraph, 0, 10)]

  test "a closed fence below an unclosed opener pairs with it":
    # The first ``` pairs with the next fence line — CommonMark pairing — so
    # this is one code block followed by a paragraph.
    let text = "```\ncode\n```\ntail"
    check computeBlocks(text) == @[b(bkFencedCode, 0, 13), b(bkParagraph, 13, 4)]
    assertTiles(text)

  test "consecutive blockquote lines form one block, ended by a plain line":
    let text = "> a\n> b\nc"
    check computeBlocks(text) == @[b(bkBlockquote, 0, 8), b(bkParagraph, 8, 1)]
    assertTiles(text)

  test "consecutive list lines form one list block":
    let text = "- a\n- b\n\ntail"
    check computeBlocks(text) ==
      @[b(bkList, 0, 8), b(bkBlank, 8, 1), b(bkParagraph, 9, 4)]
    assertTiles(text)

  test "a GFM table needs a separator row":
    check computeBlocks("|a|b|\n|-|-|\n|1|2|") == @[b(bkTable, 0, 17)]
    # Without the separator the pipes are just text.
    check computeBlocks("|a|b|\n|1|2|") == @[b(bkParagraph, 0, 11)]

  test "block LaTeX is opaque":
    check computeBlocks("$$\nx = 1\n$$") == @[b(bkBlockLatex, 0, 11)]

suite "block parser — incremental":

  test "a typed character inside a paragraph splices without reparsing all":
    let old = toUtf16("alpha\n\nbravo\n\ncharlie")
    let oldBlocks = computeBlocks(initText(old))
    let new = toUtf16("alpha\n\nbravoX\n\ncharlie")
    let (diff, ok) = scanDiff(old, new)
    check ok
    let (spliced, _, reused) = incrementalParse(old, oldBlocks, new,
                                                initText(new), diff)
    check reused
    check spliced == computeBlocks(initText(new))

  test "typing a blank line splits a paragraph and still matches a full parse":
    let old = toUtf16("alpha bravo")
    let oldBlocks = computeBlocks(initText(old))
    let new = toUtf16("alpha\n\nbravo")
    let (diff, ok) = scanDiff(old, new)
    check ok
    let (spliced, _, _) = incrementalParse(old, oldBlocks, new,
                                           initText(new), diff)
    check spliced == computeBlocks(initText(new))

  test "an edit deep inside a fence splices and keeps the fence whole":
    # The delimiter guard is line-expanded by ±3 units, so the edit has to be
    # more than a line away from either fence for the cheap path to be taken
    # at all. That is the interesting case: the splice must still produce one
    # opaque block, not reparse the body as paragraphs.
    let body = "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4"
    let old = toUtf16("```\n" & body & "\n```\n\ntail")
    let oldBlocks = computeBlocks(initText(old))
    let new = toUtf16("```\n" & body.replace("b = 2", "b = 22") & "\n```\n\ntail")
    let (diff, ok) = scanDiff(old, new)
    check ok
    let (spliced, _, reused) = incrementalParse(old, oldBlocks, new,
                                                initText(new), diff)
    check reused
    check spliced == computeBlocks(initText(new))
    check spliced[0].kind == bkFencedCode

  test "an edit next to a fence delimiter falls back to a full parse":
    # Conservative by design: touching a line that carries ``` can re-pair
    # every fence below it, so the splice refuses rather than guess.
    let old = toUtf16("```\nlet x = 1\n```\n\ntail")
    let oldBlocks = computeBlocks(initText(old))
    let new = toUtf16("```\nlet x = 12\n```\n\ntail")
    let (diff, ok) = scanDiff(old, new)
    check ok
    let (_, _, reused) = incrementalParse(old, oldBlocks, new,
                                          initText(new), diff)
    check not reused

  test "typing a fence delimiter forces a full reparse":
    # `hasBlockDelimiter` is the guard: once backticks appear in the edited
    # region the cheap splice is unsound, because the pairing of every fence
    # below can change.
    let new = toUtf16("alpha\n```\nbravo")
    check hasBlockDelimiter(new, 6, 9)

  test "a plain word carries no block delimiter":
    let buf = toUtf16("alpha bravo charlie")
    check not hasBlockDelimiter(buf, 6, 11)

  test "scanDiff finds the minimal changed span":
    let (diff, ok) = scanDiff(toUtf16("abcdef"), toUtf16("abXYdef"))
    check ok
    check diff.changeStart == 2
    check diff.changeEndOld == 3
    check diff.changeEndNew == 4
    check diff.delta == 1

  test "scanDiff reports no change for identical buffers":
    let (_, ok) = scanDiff(toUtf16("same"), toUtf16("same"))
    check not ok
