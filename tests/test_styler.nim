## test_styler.nim
## Phase 2.5b — the AST styler composes nested and combined inline styles
## instead of overwriting them, which is what the flat 18-pass styler got
## wrong.
##
## Ported from `MarkdownASTStylerTests.swift` (including its task-checkbox
## geometry suite), `ThematicBreakMarkTests.swift`, `FlattenedRunsTests.swift`,
## `BlockBackgroundFillTests.swift` and `CaretColorTests.swift`.

import std/[unittest, sequtils, math, strformat, algorithm, strutils]
import markdownengine

const base = 14.0

proc styleOf(text: string, caret = -1, cfg = initConfiguration(),
             scoped: seq[Range] = @[], hasScope = false): seq[StyledRange] =
  var c = cfg
  c.fontSize = base
  styleAttributes(initText(text), c, caretLocation = caret,
                  containerWidth = 600.0, scopedRanges = scoped,
                  hasScope = hasScope)

proc fontAt(attrs: seq[StyledRange], pos: int): (FontDesc, bool) =
  ## Effective font at `pos`: the last styled range covering it that sets one.
  result = (FontDesc(), false)
  for (r, a) in attrs:
    if r.contains(pos) and a.has(akFont): result = (a.get(akFont).fontVal, true)

proc colorAt(attrs: seq[StyledRange], pos: int): (Color, bool) =
  result = (Color(), false)
  for (r, a) in attrs:
    if r.contains(pos) and a.has(akForegroundColor):
      result = (a.get(akForegroundColor).colorVal, true)

proc paragraphAt(attrs: seq[StyledRange], pos: int): ParagraphStyle =
  for (r, a) in attrs:
    if r.contains(pos) and a.has(akParagraphStyle):
      result = a.get(akParagraphStyle).paraVal

let hiddenSize = initConfiguration().markers.hiddenMarkerFontSize

proc isHiddenMarkerFont(attrs: seq[StyledRange], pos: int): bool =
  let (f, ok) = fontAt(attrs, pos)
  ok and f.size == hiddenSize

suite "AST styler — font composition":

  test "bold inside a heading stays heading-size and consistent":
    # The bug this fixes: `# **n*o*des**` rendered "o" big and "n/des" small.
    let attrs = styleOf("# **n*o*des**")
    # Positions: n=4, o=6, d=8
    let (n, nOk) = fontAt(attrs, 4)
    let (o, oOk) = fontAt(attrs, 6)
    let (d, dOk) = fontAt(attrs, 8)
    check nOk and oOk and dOk
    check n.size == o.size
    check n.size == d.size
    check n.size > base                     # heading-size, not base
    check ftBold in n.traits
    check ftBold in d.traits
    check ftBold in o.traits
    check ftItalic in o.traits

  test "nested emphasis in a paragraph composes bold+italic":
    let attrs = styleOf("**a *b* c**")
    # Positions: a=2, b=5
    let (a, _) = fontAt(attrs, 2)
    let (b, _) = fontAt(attrs, 5)
    check ftBold in a.traits
    check ftItalic notin a.traits
    check ftBold in b.traits
    check ftItalic in b.traits

suite "AST styler — spell check and combined runs":

  test "code blocks and inline code suppress spell check; prose does not":
    # Code is not prose: fenced blocks and inline spans must carry
    # `spellingState: 0`, matching links, wiki-links, LaTeX and tables.
    let text = "prose word\n\n```\nfencedcd notaword\n```\n\nplain `inlnecode` tail"
    let t = initText(text)
    let attrs = styleOf(text)

    proc spellingStates(within: Range): seq[int] =
      for (r, a) in attrs:
        if intersects(r, within) and a.has(akSpellingState):
          result.add a.intOf(akSpellingState, -1)

    check 0 in spellingStates(t.rangeOf("fencedcd notaword"))
    check 0 in spellingStates(t.rangeOf("`inlnecode`"))
    check spellingStates(t.rangeOf("prose word")).len == 0

  test "inline code inside a link receives both code and link styling":
    let attrs = styleOf("[`App`](u)")
    let codeContent = 2
    check attrs.anyIt(it[0].contains(codeContent) and it[1].has(akBackgroundColor))
    check attrs.anyIt(it[0].contains(codeContent) and it[1].has(akLink))

  test "a revealed link target is muted like its brackets":
    #                   0123456789012345678901
    let attrs = styleOf("see [Nodes](nodes.app) now", caret = 6)
    let muted = defaultTheme.mutedText
    check colorAt(attrs, 13)[0] == muted      # inside `nodes.app`
    check colorAt(attrs, 11)[0] == muted      # the `(` beside it
    check colorAt(attrs, 5)[0] != muted       # the label keeps the link ink

suite "AST styler — markers shrink, they don't disappear":

  test "highlight markers are muted while the caret is inside":
    var cfg = initConfiguration()
    cfg.extensions = @[newHighlightExtension(), newStrikethroughExtension()]
    let attrs = styleOf("==text==", caret = 4, cfg = cfg)
    for pos in [0, 1, 6, 7]:
      checkpoint(&"position {pos}")
      check colorAt(attrs, pos)[0] == defaultTheme.mutedText

  test "bold markers are muted while the caret is inside":
    let attrs = styleOf("**bold**", caret = 4)
    for pos in [0, 1, 6, 7]:
      checkpoint(&"position {pos}")
      check colorAt(attrs, pos)[0] == defaultTheme.mutedText

  test "an italic marker is muted while the caret is inside":
    let attrs = styleOf("*italic*", caret = 4)
    check colorAt(attrs, 0)[0] == defaultTheme.mutedText
    check colorAt(attrs, 7)[0] == defaultTheme.mutedText

  test "strikethrough markers are muted while the caret is inside":
    var cfg = initConfiguration()
    cfg.extensions = @[newStrikethroughExtension()]
    let attrs = styleOf("~~strike~~", caret = 5, cfg = cfg)
    for pos in [0, 1, 8, 9]:
      checkpoint(&"position {pos}")
      check colorAt(attrs, pos)[0] == defaultTheme.mutedText

  test "inline markers shrink instead of taking the muted colour outside":
    var cfg = initConfiguration()
    cfg.extensions = @[newHighlightExtension(), newStrikethroughExtension()]
    let attrs = styleOf("a ==text== b **bold** c ~~strike~~ d *italic* e",
                        caret = 0, cfg = cfg)
    for pos in [2, 3, 8, 9, 13, 14, 19, 20, 24, 25, 32, 33, 37, 44]:
      checkpoint(&"marker at {pos} should be shrunk")
      check isHiddenMarkerFont(attrs, pos)

suite "AST styler — task checkbox geometry":
  # A hidden task item shares the BULLET list's left geometry: the `[ ] `
  # characters collapse to the hidden-marker font (~zero advance) so task
  # content starts at the same x as bullet content, and the hanging indent
  # measures only `- `. While the caret edits the syntax, the raw characters
  # show at full advance and the indent uses the full `- [ ] ` width.

  let indentPerLevel = initConfiguration().lists.indentPerLevel
  let baseFont = FontDesc(family: defaultFontFamily, size: base)

  proc widthOf(s: string): float =
    textWidth(nil, defaultTextMetrics, s, baseFont)

  proc headIndentAt(attrs: seq[StyledRange], pos: int): float =
    let p = paragraphAt(attrs, pos)
    if p.isNil: -1.0 else: p.headIndent

  test "a hidden task collapses its box and indents like a bullet":
    # "- [ ] task": marker 0..1, spacer 1..2, box 2..5, gap 5..6, content 6…
    let attrs = styleOf("- [ ] task")
    for pos in 2 .. 4:
      checkpoint(&"box char at {pos} should collapse")
      check isHiddenMarkerFont(attrs, pos)
    check isHiddenMarkerFont(attrs, 5)        # the space after the box
    # Marker and spacer keep full advance — that is the drawn square's slot.
    check not isHiddenMarkerFont(attrs, 0)
    check not isHiddenMarkerFont(attrs, 1)

    let taskIndent = headIndentAt(attrs, 0)
    check abs(taskIndent - (indentPerLevel + widthOf("- "))) < 0.01
    check taskIndent == headIndentAt(styleOf("- task"), 0)
    # `[x]` hits the identical collapse branch as `[ ]`.
    check headIndentAt(styleOf("- [x] task"), 0) == taskIndent

  test "a revealed task keeps the full raw syntax width":
    let attrs = styleOf("- [ ] task", caret = 3)
    for pos in 2 .. 5:
      checkpoint(&"box char at {pos} must not collapse while revealed")
      check not isHiddenMarkerFont(attrs, pos)
    # Wrapped lines align with the visible "- [ ] ".
    check abs(headIndentAt(attrs, 0) - (indentPerLevel + widthOf("- [ ] "))) < 0.01

  test "a task item keeps its box with list helpers off":
    var cfg = initConfiguration()
    cfg.lists.helpersEnabled = false
    let attrs = styleOf("- [ ] todo\n- plain\n", cfg = cfg)
    # The attribute IS the checkbox: drawing, hit test and toggle all read it,
    # so without it the feature does not exist.
    check attrs.anyIt(it[1].has(akTaskCheckbox))
    # `- ` → `•` is an editing helper by the setting's own promise and stays
    # off — this is about the box, not about re-rendering lists.
    check not attrs.anyIt(it[1].has(akBulletMarker))

    let boxSize = taskCheckboxSize(defaultTextMetrics, nil, baseFont)
    let markerWidth = widthOf("- ")
    let para = paragraphAt(attrs, 0)
    check not para.isNil
    # The box is drawn to the LEFT of the content, so the line owes it exactly
    # that much room — without it the box sat at a negative x.
    check para.firstLineHeadIndent + markerWidth >= boxSize + taskCheckboxGap - 0.5
    # …and not a point more: helpers off means no list indent.
    check para.firstLineHeadIndent < cfg.lists.indentPerLevel
    # A paragraph style replaces the base one wholesale, so the line metrics
    # have to be carried over with it. Left unpinned, the line fell back to
    # the font's natural height and the document height flipped as the line
    # crossed into being a task item.
    check para.minimumLineHeight ==
      ceil(lineHeight(defaultTextMetrics, baseFont)) +
      cfg.paragraph.lineHeightExtraSpacing

suite "AST styler — scoped styling":

  test "a scoped continuous list emits only intersecting ranges":
    var text = ""
    for _ in 0 ..< 2000:
      text.add "- [x] **fast** `native` [link](relative.md)\n"
    let t = initText(text)
    let target = t.lineRange(rng(t.len - 10, 0))
    let attrs = styleOf(text, scoped = @[target], hasScope = true)
    check attrs.len > 0
    check attrs.allIt(intersects(it[0], target))

  test "scoped styling equals full styling inside the edited paragraph":
    # The safety net for the `scopedRanges` fast path: per-keystroke it must
    # produce the EXACT same attributes within that paragraph as a full pass.
    let text = "plain one\n\n**bold** in two `code`\n\n- item *x*\n\nhttps://example.com"
    let t = initText(text)
    let para = t.paragraphRange(rng(13, 0))        # the `**bold**…` line

    proc keySnapshot(scoped: seq[Range], hasScope: bool): string =
      ## Canonical, order-independent, so two style runs compare for equality.
      var lines: seq[string] = @[]
      for (r, a) in styleOf(text, scoped = scoped, hasScope = hasScope):
        if not intersects(r, para): continue
        var keys = a.mapIt($it.key)
        keys.sort()
        lines.add &"@{r.location}+{r.length} keys=[{keys.join(\",\")}]"
      lines.sort()
      lines.join("\n")

    check keySnapshot(@[para], true) == keySnapshot(@[], false)

  test "scoped list styling matches the full effective attribute values":
    let text = "- plain *one*\n- [x] **done** `code`\n- [ ] [link](a.md)\n- final _four_\n"
    let t = initText(text)
    let second = t.lineRange(t.rangeOf("- [x]"))
    let fourth = t.lineRange(t.rangeOf("- final"))
    let caret = second.location + 3

    let baseAttrs: Attrs = @[(akFont, av(FontDesc(family: defaultFontFamily,
                                                  size: base)))]
    let full = flattenedRuns(styleOf(text, caret = caret), baseAttrs, t.len)
    let scoped = flattenedRuns(
      styleOf(text, caret = caret, scoped = @[fourth, second], hasScope = true),
      baseAttrs, t.len)

    proc attrsAt(runs: seq[StyledRange], index: int): Attrs =
      for (r, a) in runs:
        if r.contains(index): return a
      @[]

    for scope in [second, fourth]:
      for i in scope.location ..< maxRange(scope):
        checkpoint(&"index {i}")
        require attrsAt(scoped, i) == attrsAt(full, i)

suite "AST styler — thematic breaks":

  test "a thematic break carries the rule attribute and collapses its source":
    let attrs = styleOf("a\n\n---\n\nb")
    check attrs.anyIt(it[1].has(akThematicBreak))
    # The source characters go clear rather than shrinking: the rule is drawn
    # across the line box the `---` already occupies, so its advance is wanted.
    for pos in 3 .. 5:
      checkpoint(&"rule char at {pos}")
      check colorAt(attrs, pos)[0] == clearColor

  test "the rule is suppressed while the caret edits the line":
    check not styleOf("a\n\n---\n\nb", caret = 4).anyIt(it[1].has(akThematicBreak))

  test "no mark is configured by default — every marker draws the rule":
    # CommonMark gives `---`, `***` and `___` one meaning and one rendering.
    for source in ["---\n", "***\n", "___\n"]:
      checkpoint(source)
      check not styleOf(source).anyIt(it[1].has(akThematicBreakMark))

  test "a configured mark rides along for its own marker only":
    # The marker character survives into the configuration so an embedder can
    # give one of the three a different look WITHOUT inventing syntax.
    var cfg = initConfiguration()
    cfg.thematicBreak = initThematicBreakStyle(
      asteriskMark = ThematicBreakMark(text: "\u{2042}", scale: 1.5),
      hasAsteriskMark = true)

    proc markOf(text: string): (string, float) =
      for (_, a) in styleOf(text, cfg = cfg):
        if a.has(akThematicBreakMark):
          return (a.stringOf(akThematicBreakMark, ""),
                  a.floatOf(akThematicBreakMarkScale, 0.0))
      ("", 0.0)

    check markOf("***\n") == ("\u{2042}", 1.5)
    check markOf("---\n") == ("", 0.0)
    check markOf("___\n") == ("", 0.0)

suite "AST styler — flattened runs":
  # `flattenedRuns` replaced a per-key merge loop that was quadratic in
  # document size. Speed is only half the requirement: the flattened write
  # must land the SAME attributes, including the "later range wins per key"
  # precedence the loop got for free from repeated merges. So these assert
  # equivalence against that loop rather than against hand-written results.

  let baseAttrs: Attrs = @[(akFont, av(FontDesc(family: defaultFontFamily, size: 13.0))),
                           (akForegroundColor, av(labelColor))]

  proc applyNaively(ranges: seq[StyledRange], length: int): seq[Attrs] =
    ## The loop `flattenedRuns` replaced, kept as the oracle.
    result = newSeq[Attrs](length)
    for i in 0 ..< length: result[i] = baseAttrs
    for (r, a) in ranges:
      if r.location == NotFound or r.location < 0 or r.length <= 0: continue
      if maxRange(r) > length: continue
      for i in r.location ..< maxRange(r):
        for pair in a: result[i].put(pair.key, pair.value)

  proc applyFlattened(ranges: seq[StyledRange], length: int): seq[Attrs] =
    result = newSeq[Attrs](length)
    for i in 0 ..< length: result[i] = baseAttrs
    for (r, a) in flattenedRuns(ranges, baseAttrs, length):
      for i in r.location ..< maxRange(r): result[i] = a

  test "disjoint ranges land identically":
    let ranges = @[(rng(4, 5), @[(akForegroundColor, av(systemRed))].Attrs),
                   (rng(16, 3), @[(akForegroundColor, av(systemBlue))].Attrs)]
    check applyFlattened(ranges, 43) == applyNaively(ranges, 43)

  test "a later overlapping range wins per key, and only per key":
    let ranges = @[
      (rng(0, 6), @[(akForegroundColor, av(systemRed)),
                    (akBackgroundColor, av(systemYellow))].Attrs),
      # Overrides the colour on 2 ..< 8 but must leave the background from the
      # first range standing on 2 ..< 6.
      (rng(2, 6), @[(akForegroundColor, av(systemGreen))].Attrs)]
    let flattened = applyFlattened(ranges, 10)
    check flattened == applyNaively(ranges, 10)
    check flattened[3].colorOf(akForegroundColor, clearColor) == systemGreen
    check flattened[3].colorOf(akBackgroundColor, clearColor) == systemYellow

  test "fully nested and identical ranges":
    let ranges = @[
      (rng(0, 40), @[(akForegroundColor, av(systemRed))].Attrs),
      (rng(10, 20), @[(akBackgroundColor, av(systemGray))].Attrs),
      (rng(10, 20), @[(akForegroundColor, av(systemBlue))].Attrs),
      (rng(15, 1), @[(akForegroundColor, av(systemGreen))].Attrs)]
    check applyFlattened(ranges, 40) == applyNaively(ranges, 40)

  test "character-sized adjacent ranges coalesce without changing the result":
    # The shape the incomplete-link pass used to emit: one range per character.
    var ranges: seq[StyledRange] = @[]
    for i in 0 ..< 50:
      ranges.add (rng(i, 1), @[(akForegroundColor, av(systemRed))].Attrs)
    check applyFlattened(ranges, 50) == applyNaively(ranges, 50)
    check flattenedRuns(ranges, baseAttrs, 50).len == 1

  test "touching ranges are not merged when their attributes differ":
    let ranges = @[(rng(0, 5), @[(akForegroundColor, av(systemRed))].Attrs),
                   (rng(5, 5), @[(akForegroundColor, av(systemBlue))].Attrs)]
    check flattenedRuns(ranges, baseAttrs, 10).len == 2
    check applyFlattened(ranges, 10) == applyNaively(ranges, 10)

  test "degenerate ranges are dropped, not applied out of bounds":
    let ranges = @[(rng(5, 0), @[(akForegroundColor, av(systemRed))].Attrs),
                   (notFoundRange(), @[(akForegroundColor, av(systemRed))].Attrs),
                   (rng(18, 10), @[(akForegroundColor, av(systemRed))].Attrs),
                   (rng(2, 4), @[(akForegroundColor, av(systemBlue))].Attrs)]
    let runs = flattenedRuns(ranges, baseAttrs, 20)
    check runs.len == 1
    check runs[0].range == rng(2, 4)

  test "randomised overlap storms stay equivalent to the loop":
    const length = 400
    let colors = [systemRed, systemGreen, systemBlue, systemOrange, systemPurple]
    # Deterministic: a failure must be reproducible from the seed.
    var seed = 0x9E3779B97F4A7C15'u64
    proc next(bound: int): int =
      seed = seed xor (seed shl 13)
      seed = seed xor (seed shr 7)
      seed = seed xor (seed shl 17)
      int(seed mod uint64(bound))
    for _ in 0 ..< 20:
      var ranges: seq[StyledRange] = @[]
      for _ in 0 ..< 120:
        let location = next(length)
        let maxLength = length - location
        let rangeLength = if maxLength == 0: 0 else: next(min(maxLength, 25)) + 1
        var a: Attrs = @[(akForegroundColor, av(colors[next(colors.len)]))]
        if next(2) == 0: a.add (akBackgroundColor, av(colors[next(colors.len)]))
        if next(3) == 0: a.add (akUnderlineStyle, av(ulSingle))
        ranges.add (rng(location, rangeLength), a)
      require applyFlattened(ranges, length) == applyNaively(ranges, length)

suite "AST styler — block backgrounds":

  test "a fenced block paints a character background across its code range":
    let t = initText("```\ncode\n```\n")
    var painted = Range()
    for (r, a) in styleOf($t):
      if a.has(akBackgroundColor) and r.length > painted.length: painted = r
    check painted.location == 0
    check maxRange(painted) > t.rangeOf("code").location

  test "a highlight span paints the LINE BOX, not the glyph box":
    # `akMarkdownBlockBackground`, not `akBackgroundColor`: a glyph-box fill
    # leaves a gap between lines where the highlight should be continuous.
    var cfg = initConfiguration()
    cfg.extensions = @[newHighlightExtension()]
    let attrs = styleOf("a ==hi== b", cfg = cfg)
    check attrs.anyIt(it[1].has(akMarkdownBlockBackground))

  test "an inline code span paints a character background":
    let attrs = styleOf("a `code` b")
    check attrs.anyIt(it[1].has(akBackgroundColor))
    check not attrs.anyIt(it[1].has(akMarkdownBlockBackground))

  test "a blockquote carries its nesting level":
    let attrs = styleOf("> one\n>> two\n")
    var levels: seq[int] = @[]
    for (_, a) in attrs:
      if a.has(akBlockquoteLevel): levels.add a.intOf(akBlockquoteLevel, 0)
    check 1 in levels
    check 2 in levels
