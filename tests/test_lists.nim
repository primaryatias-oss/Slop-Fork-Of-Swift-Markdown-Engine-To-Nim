## test_lists.nim
## Phase A — list modelling in the AST, and the positional numbering overlay.
##
## Ported from `ListParsingTests.swift` and the engine-level half of
## `OrderedListDisplayNumberingTests.swift` (the AppKit coordinator half lives
## in `test_editor.nim`, against this port's own editor).

import std/[unittest, sequtils, algorithm, strformat]
import markdownengine

proc itemsOf(text: string): seq[ListItem] =
  for b in parseDocument(text):
    if b.kind == bnList: return b.items
  @[]

proc hasList(blocks: seq[Block]): bool =
  blocks.anyIt(it.kind == bkList)

suite "list parsing":

  test "consecutive bullet lines are one list block":
    check computeBlocks("- a\n- b\n- c\n").countIt(it.kind == bkList) == 1

  test "a bullet item is parsed":
    let items = itemsOf("- hello\n")
    check items.len == 1
    check not items[0].ordered
    check not items[0].hasCheckbox
    check items[0].marker.length == 1

  test "an ordered item carries its number":
    let items = itemsOf("3. third\n")
    check items[0].ordered
    check items[0].number == 3
    check items[0].marker.length == 2        # "3."

  test "a task checkbox is parsed":
    check itemsOf("- [x] done\n")[0].checked
    check itemsOf("- [x] done\n")[0].hasCheckbox
    check not itemsOf("- [ ] todo\n")[0].checked
    check itemsOf("- [ ] todo\n")[0].hasCheckbox

  test "indentation is captured":
    check itemsOf("    - nested\n")[0].indent == 4

  test "item inline content is parsed":
    let inlines = itemsOf("- a **b** c\n")[0].inlines
    check inlines.anyIt(it.kind == inEmphasis and it.emphasis == ekBold)

  test "a dash without a space is not a list":
    check not hasList(computeBlocks("-foo\n"))

  test "a triple dash stays a thematic break":
    let blocks = computeBlocks("---\n")
    check not hasList(blocks)
    check blocks.anyIt(it.kind == bkThematicBreak)

  test "a plain line after a list does not merge in":
    let blocks = computeBlocks("- item\ntext\n")
    check hasList(blocks)
    check blocks.anyIt(it.kind == bkParagraph)

  test "the task trigger recognises star and plus markers":
    # The caret-crossing trigger has to see the same task markers the styler
    # does; if it disagrees the raw syntax never reveals on caret entry.
    for line in ["- [ ] task", "* [ ] task", "+ [ ] task"]:
      let (_, ok) = taskSyntaxRange(initText(line), 0)
      checkpoint(line)
      check ok

  test "a bare marker with no following space is not a list yet":
    # Typing `-` (or `*` to start emphasis) stays literal until a space
    # follows, so the bullet and its indent only appear for `- `.
    check not isListItem("-")
    check not isListItem("*")
    check not isListItem("1.")
    check not hasList(computeBlocks("-"))
    check isListItem("- ")
    check isListItem("- x")
    check isListItem("1. x")

# ---------------------------------------------------------------------------
# Ordered display numbering
# ---------------------------------------------------------------------------
#
# Ordered items are numbered by POSITION and painted over the source digits.
# Two things a styler-only test would happily hide:
#  * the block array a SCOPED restyle sees is not the document — the text
#    between two scoped regions is missing, so a run can look continuous when
#    prose actually ended it;
#  * unlike every other markdown construct, the overlay does NOT step aside
#    for the caret or a selection — the source digit is positional, not
#    authored, and revealing it renames the item the reader is pointing at.

proc overlays(attrs: seq[StyledRange]): seq[(int, string)] =
  ## `(markerLocation, paintedMarker)` for every overlaid ordered marker.
  ## Absent means the item paints its own literal digits — the styler emits
  ## the overlay only when the display number differs from the source.
  for (r, a) in attrs:
    if a.has(akOrderedMarker): result.add (r.location, a.stringOf(akOrderedMarker, ""))
  result.sort(proc (x, y: (int, string)): int = cmp(x[0], y[0]))

proc style(text: string, caret = -1, scoped: seq[Range] = @[],
           hasScope = false, selection = Range(),
           hasSelection = false): seq[StyledRange] =
  var cfg = initConfiguration()
  styleAttributes(initText(text), cfg, caretLocation = caret,
                  selection = selection, hasSelection = hasSelection,
                  containerWidth = 600.0, scopedRanges = scoped,
                  hasScope = hasScope)

suite "ordered list display numbering — scope":

  test "prose between two lists still ends the run when the scope skips it":
    # A two-region scope (caret paragraph + previous-caret paragraph — what
    # every click builds) drops the prose between the lists from the block
    # array. The count must not flow across that hole.
    let text = "1. one\n2. two\n\nProse paragraph here.\n\n1. alpha\n2. beta\n"
    let t = initText(text)
    let alpha = t.rangeOf("1. alpha")
    let alphaPara = t.paragraphRange(alpha)
    let scoped = @[t.paragraphRange(rng(0, 0)), alphaPara]

    let painted = overlays(style(text, scoped = scoped, hasScope = true))
      .filterIt(alphaPara.contains(it[0]))

    # `1. alpha` is item 1 of its own list: display == literal, nothing to
    # paint. Inheriting the upper list's count would paint "3.".
    check painted.len == 0
    check overlays(style(text)).len == 0      # and the full pass agrees

  test "a scoped tail of a blank-split list keeps counting":
    # A blank line is loose-list spacing, not a terminator, so a scope that
    # only sees the tail must still continue the run above it.
    let text = "1. one\n\n1. two\n"
    let t = initText(text)
    let tail = t.rangeOf("1. two")
    let painted = overlays(style(text, scoped = @[t.paragraphRange(tail)],
                                 hasScope = true))
    check painted.mapIt(it[1]) == @["2."]
    check painted[0][0] == tail.location

  test "a nested ordered list starts at its own number":
    # The seed scans BACKWARD from the item's marker — which for an indented
    # item still sits inside its own line, so counting that item made every
    # nested list render one too high with no gesture at all.
    check overlays(style("- outer\n  1. a\n  2. b")).len == 0
    check overlays(style("- outer\n\t1. a\n\t2. b")).len == 0
    check overlays(style("  1. alpha")).len == 0
    check overlays(style("1. top\n  1. nested\n  2. nested")).len == 0

  test "a scope with holes counts through a loose list":
    # A hole of blank lines between two scoped blocks is loose-list spacing,
    # so the count carries; a hole holding another item re-seeds from the
    # source and lands on the same number. Both must agree with a full pass.
    let text = "1. one\n\n1. two\n\n1. three\n"
    let t = initText(text)
    let scoped = @[t.paragraphRange(rng(0, 0)),
                   t.paragraphRange(t.rangeOf("1. three"))]
    check overlays(style(text, scoped = scoped, hasScope = true)).mapIt(it[1]) ==
      @["3."]
    check overlays(style(text)).mapIt(it[1]) == @["2.", "3."]

  test "disjoint scopes inside one list reseed omitted items":
    let text = "1. one\n1. two\n1. three\n1. four\n"
    let t = initText(text)
    let first = t.lineRange(t.rangeOf("1. one"))
    let fourth = t.lineRange(t.rangeOf("1. four"))
    let painted = overlays(style(text, scoped = @[first, fourth], hasScope = true))
    check painted.mapIt(it[0]) == @[fourth.location]
    check painted.mapIt(it[1]) == @["4."]

suite "ordered list display numbering — caret and selection":

  test "a caret at the line start keeps the display number":
    # Where every whole-line delete and line-join leaves the caret. Treating
    # that as "editing the digits" is what made a 1./2./3. list read 1./1.
    # after deleting item 2.
    let painted = overlays(style("1. a\n1. b", caret = 5))
    check painted.mapIt(it[1]) == @["2."]
    check painted[0][0] == 5

  test "a caret on the digits keeps the display number":
    # The source digit is positional, not authored: in a run written
    # `1./1./1.` every item's source reads `1.`, so revealing it under the
    # caret meant a plain click inside the marker flipped the number back.
    for caret in [6, 7, 8]:                   # between `1` and `.`, the space, content
      checkpoint(&"caret {caret}")
      check overlays(style("1. a\n1. b", caret = caret)).mapIt(it[1]) == @["2."]

  test "a selection over the marker keeps the display number":
    # ⌘A used to swap every marker back to its source digit, so a whole list
    # read one lower than it renders while selected.
    let text = "1. a\n1. b"
    for selection in [rng(5, 3), rng(0, utf16Len(text))]:
      checkpoint($selection)
      check overlays(style(text, selection = selection,
                           hasSelection = true)).mapIt(it[1]) == @["2."]

  test "a run restarts after prose":
    let text = "1. a\n1. b\n\nprose\n\n1. x\n1. y\n"
    check overlays(style(text)).mapIt(it[1]) == @["2.", "2."]
