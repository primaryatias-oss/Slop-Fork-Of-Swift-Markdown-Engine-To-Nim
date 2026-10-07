## test_tables.nim
## GFM tables: the source parse, the shared geometry the styler and the
## renderer must agree on, and the cell formatter.
##
## Ported from `TableCellTests.swift`, `TableCellSourceTests.swift`,
## `TableWrappingTests.swift` and `TableScopeSkipTests.swift`.
##
## Table cells reuse the shared inline parser — one parser, one truth —
## instead of a separate re-implementation, so a cell formats identically to
## body text, including nested emphasis a per-cell pattern could not do.

import std/[unittest, sequtils, strutils]
import markdownengine
import mdui/[fontmanager, tablerender]

suite "table source parsing":

  test "a row splits on unescaped pipes only":
    check parseTableRow("| a | b | c |") == @["a", "b", "c"]
    # GFM escapes the delimiter as `\|`, and the escape wins over every inline
    # context — a table row is split before inline parsing runs, so a cell
    # holding `` `a \| b` `` is one cell, not two. The escape is consumed:
    # what reaches the cell is the bare pipe.
    check parseTableRow(r"| a \| b | c |") == @["a | b", "c"]
    check parseTableRow(r"| `x \| y` | z |") == @["`x | y`", "z"]

  test "leading and trailing pipes are optional":
    check parseTableRow("a | b") == @["a", "b"]

  test "alignments come off the separator row":
    check parseTableAlignments("|---|:---|---:|:---:|") ==
      @[tcaLeft, tcaLeft, tcaRight, tcaCenter]

  test "a source without a separator row is not a table":
    check parseTableSource("| a | b |\n| 1 | 2 |")[1] == false

  test "a parsed table carries header, alignments and rows":
    let (parsed, ok) = parseTableSource("| A | B |\n|---|---:|\n| 1 | 2 |\n| 3 | 4 |")
    check ok
    check parsed.header == @["A", "B"]
    check parsed.alignments == @[tcaLeft, tcaRight]
    check parsed.rows == @[@["1", "2"], @["3", "4"]]

  test "a break tag inside a cell becomes a real newline":
    check expandCellLineBreaks("a<br>b") == "a\nb"
    check expandCellLineBreaks("a<br/>b") == "a\nb"
    check expandCellLineBreaks("a<br />b") == "a\nb"

  test "the content hash is stable for the same source and differs otherwise":
    let a = "| A |\n|---|\n| 1 |"
    check stableTableContentHash(a) == stableTableContentHash(a)
    check stableTableContentHash(a) != stableTableContentHash(a & "\n| 2 |")

  test "two identical tables in one document get distinct source ids":
    # The id keys a render cache; two copies of the same table must not share
    # an entry, or editing one repaints the other.
    let source = "| A |\n|---|\n| 1 |"
    check stableTableSourceID(source, 0) != stableTableSourceID(source, 1)
    check stableTableSourceID(source, 0) == stableTableSourceID(source, 0)

suite "table geometry":

  let font = FontDesc(family: defaultFontFamily, size: 15.0)
  let wideSource = """
| Rechtsform | Gründungskosten | Laufende Kosten |
|---|---|---|
| Einzelunternehmen (Kleingewerbe) | 20–60€ Gewerbeanmeldung, jeder Gesellschafter meldet einzeln an | ~0€, nur Steuerberater optional, dreihundert bis achthundert Euro |
| GbR | Notar und Handelsregister etwa dreihundert bis fünfhundert Euro | Gesellschaftervertrag empfohlen, Anwalt fünfhundert bis eintausendfünfhundert |
"""

  proc measure(source: string, availableWidth: float): TableMetrics =
    let (parsed, ok) = parseTableSource(source)
    doAssert ok
    measureTable(parsed, defaultTextMetrics, nil, font, availableWidth)

  proc renderedWidth(m: TableMetrics): float =
    ## What the table actually occupies: the (possibly shrunk) columns plus
    ## the grid lines between and around them. `naturalWidth` is the
    ## UNSHRUNK width — the horizontal-scroll overlay needs that one.
    result = float(m.columnWidths.len + 1) * tableBorderWidth
    for w in m.columnWidths: result += w

  test "a narrow table keeps its natural width":
    let m = measure("| A | B |\n|---|---|\n| 1 | 2 |", 650.0)
    check m.naturalWidth <= 650.5
    check renderedWidth(m) == m.naturalWidth
    check m.columnWidths.len == 2
    check m.rowHeights.len == 2            # header plus one body row

  test "a wide table wraps to the available width":
    # Obsidian-style layout: when the natural width exceeds the container,
    # columns share the available width and cell text WRAPS instead of the
    # table growing sideways.
    let m = measure(wideSource, 650.0)
    check m.naturalWidth > 650.0           # it really would overflow
    check renderedWidth(m) <= 650.5        # …and it was shrunk to fit

  test "wrapping grows the rows instead":
    let narrow = measure(wideSource, 650.0)
    let wide = measure(wideSource, 4000.0)
    # Same content in less width must occupy more height.
    check narrow.totalHeight > wide.totalHeight + 10.0

  test "a column never shrinks below a few characters":
    # When even those floors do not fit, the table stays WIDER than the
    # container and the horizontal-scroll overlay takes over.
    var header = "|"
    var sep = "|"
    for word in ["Rechtsformvergleich", "Gründungskostenaufstellung",
                 "Haftungsbeschränkung", "Steuerberaterkosten",
                 "Handelsregistereintrag", "Stammkapitalanforderung"]:
      header.add " " & word & " |"
      sep.add "---|"
    let m = measure(header & "\n" & sep, 60.0)
    check renderedWidth(m) > 60.0
    for w in m.columnWidths:
      check w >= 3 * tableCellHPadding

  test "the total height is the rows plus the grid lines":
    let m = measure(wideSource, 650.0)
    var sum = float(m.rowHeights.len + 1) * tableBorderWidth
    for h in m.rowHeights: sum += h
    check abs(m.totalHeight - sum) < 0.01

  test "a header is measured at the weight it is drawn":
    # The renderer draws the header row bold. Measuring it at body weight is
    # how a header word ends up overflowing its column and running through
    # the grid line beside it.
    let plain = measure("| aa |\n|---|\n| aa |", 4000.0)
    let wider = measure("| updated |\n|---|\n| aa |", 4000.0)
    check wider.columnWidths[0] >
      textWidth(nil, defaultTextMetrics, "updated", font) + 2 * tableCellHPadding - 0.01
    check plain.columnWidths[0] <= wider.columnWidths[0]

suite "table cell inline formatting":

  let fonts = newFontManager()
  let theme = defaultTheme
  let font = FontDesc(family: defaultFontFamily, size: 14.0)
  let codeFont = FontDesc(family: defaultMonoFamily, size: 14.0)
  let registry = initRegistry(@[newHighlightExtension(),
                                newStrikethroughExtension()])

  proc cell(raw: string, header = false): seq[CellRun] =
    var f = font
    if header: f = f.adding({ftBold})
    formatCell(raw, f, codeFont, theme, registry)

  proc rendered(runs: seq[CellRun]): string =
    for run in runs: result.add run.text

  proc traitsOf(runs: seq[CellRun], ch: char): FontTraits =
    ## Traits of the run holding the first occurrence of `ch` in the
    ## marker-stripped rendered string.
    for run in runs:
      if ch in run.text: return run.font.traits
    {}

  test "a plain cell has no emphasis":
    let runs = cell("hello")
    check rendered(runs) == "hello"
    check traitsOf(runs, 'h') == {}

  test "bold and italic strip their markers":
    check rendered(cell("a **b** c")) == "a b c"
    check ftBold in traitsOf(cell("a **b** c"), 'b')
    check ftItalic in traitsOf(cell("a *b* c"), 'b')
    check ftBold in traitsOf(cell("***z***"), 'z')
    check ftItalic in traitsOf(cell("***z***"), 'z')

  test "inline code is marked and switched to the code font":
    let runs = cell("`x`")
    check rendered(runs) == "x"
    check runs[0].isCode                   # the renderer paints its background
    check runs[0].font.family == defaultMonoFamily

  test "strikethrough and highlight are applied":
    check rendered(cell("~~gone~~")) == "gone"
    check rendered(cell("==note==")) == "note"

  test "a header cell starts bold":
    check ftBold in traitsOf(cell("h", header = true), 'h')

  test "nested emphasis composes to any depth":
    # The headline win over a per-cell pattern: `\*\*([^*]+)\*\*` cannot match
    # emphasis nested inside emphasis (the `[^*]+` stops at the inner `*`), so
    # `**a *b* c**` left `a` and `c` unbolded.
    let runs = cell("**a *b* c**")
    check ftBold in traitsOf(runs, 'a')
    check ftItalic notin traitsOf(runs, 'a')
    check ftBold in traitsOf(runs, 'b')
    check ftItalic in traitsOf(runs, 'b')
    check ftBold in traitsOf(runs, 'c')

  test "a link's label renders without its target":
    check rendered(cell("[label](http://x)")) == "label"

  test "an explicit break splits the cell into lines":
    let lines = wrapRuns(cell("one<br>two"), fonts, nil, 1000.0)
    check lines.len == 2
    check rendered(lines[0].runs) == "one"
    check rendered(lines[1].runs) == "two"

  test "a long cell wraps at word boundaries inside the column width":
    let runs = cell("alpha bravo charlie delta echo foxtrot")
    let wide = wrapRuns(runs, fonts, nil, 1000.0)
    let narrow = wrapRuns(runs, fonts, nil, 80.0)
    check wide.len == 1
    check narrow.len > 1
    # Nothing is dropped by the wrap.
    check narrow.mapIt(rendered(it.runs)).join(" ") == rendered(runs)
