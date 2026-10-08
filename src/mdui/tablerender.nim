## tablerender.nim
## MarkdownEngine (Nim port) — UI layer
##
## Draws a GFM table.
##
## The Swift engine rasterized the whole table into an `NSImage` and planted it
## on a collapsed source line, with a bitmap cache keyed by source, font,
## colours and appearance. This port draws it directly instead, for two
## reasons: the renderer already has a text engine, and drawn cells stay crisp
## at any scale and under any appearance with no cache to invalidate.
##
## Cell content keeps its inline markdown — emphasis, code spans, links — with
## the markers STRIPPED, which is what `formattedCellString` did. A cell is not
## a document: it has no caret, so there is nothing for a revealed marker to
## serve.

import std/[math, strutils, unicode]
import ../markdownengine/[ranges, utf16text, color, font, theme,
                          extension, services, configuration, inline_parser]
import ../markdownengine/table as mdtable
import ../markdownengine/styler as mdstyler
import ./fontmanager, ./atlas, ./painter

type
  CellRun* = object
    ## One formatted piece of a cell: text plus how to draw it.
    text*: string
    font*: FontDesc
    color*: Color
    hasColor*: bool
    isCode*: bool

  CellLine* = object
    runs*: seq[CellRun]
    width*: float

proc appendInline(nodes: seq[InlineNode], t: Utf16Text, font: FontDesc,
                  theme: MarkdownEditorTheme, registry: ExtensionRegistry,
                  codeFont: FontDesc, runs: var seq[CellRun])

proc appendPlain(t: Utf16Text, r: Range, font: FontDesc, color: Color,
                 hasColor: bool, isCode: bool, runs: var seq[CellRun]) =
  let text = t.substring(r)
  if text.len == 0: return
  if runs.len > 0 and runs[^1].font == font and runs[^1].isCode == isCode and
     runs[^1].hasColor == hasColor and
     (not hasColor or runs[^1].color == color):
    runs[^1].text.add text
  else:
    runs.add CellRun(text: text, font: font, color: color, hasColor: hasColor,
                     isCode: isCode)

proc appendInline(nodes: seq[InlineNode], t: Utf16Text, font: FontDesc,
                  theme: MarkdownEditorTheme, registry: ExtensionRegistry,
                  codeFont: FontDesc, runs: var seq[CellRun]) =
  for node in nodes:
    case node.kind
    of inText:
      appendPlain(t, node.range, font, theme.bodyText, false, false, runs)
    of inCode:
      appendPlain(t, node.contentRange, codeFont, theme.bodyText, false, true, runs)
    of inEmphasis:
      let traits = case node.emphasis
                   of ekItalic: {ftItalic}
                   of ekBold: {ftBold}
                   of ekBoldItalic: {ftBold, ftItalic}
      appendInline(node.children, t, font.adding(traits), theme, registry,
                   codeFont, runs)
    of inLink:
      # The label only; the destination is syntax.
      var labelRuns: seq[CellRun] = @[]
      appendInline(node.children, t, font, theme, registry, codeFont, labelRuns)
      for run in labelRuns.mitems:
        run.color = theme.link
        run.hasColor = true
      for run in labelRuns: runs.add run
    of inWikiLink:
      appendPlain(t, node.contentRange, font, theme.link, true, false, runs)
    of inImage, inImageEmbed:
      appendPlain(t, node.contentRange, font, theme.mutedText, true, false, runs)
    of inInlineLatex:
      # No renderer inside a cell, so the formula shows as its source, muted —
      # the same fallback the engine uses when no LaTeX renderer is supplied.
      appendPlain(t, node.contentRange, font, theme.mutedText, true, false, runs)
    of inEscape:
      appendPlain(t, node.contentRange, font, theme.bodyText, false, false, runs)
    of inExt:
      appendInline(node.children, t, font, theme, registry, codeFont, runs)
      if node.children.len == 0:
        appendPlain(t, node.contentRange, font, theme.bodyText, false, false, runs)

proc formatCell*(raw: string, font, codeFont: FontDesc,
                 theme: MarkdownEditorTheme,
                 registry: ExtensionRegistry): seq[CellRun] =
  ## Raw cell → formatted runs: inline markdown applied, markers stripped,
  ## `<br>` turned into a real newline.
  let expanded = expandCellLineBreaks(raw)
  let t = initText(expanded)
  appendInline(parseInline(expanded, registry), t, font, theme, registry,
               codeFont, result)

proc wrapRuns*(runs: seq[CellRun], fonts: FontManager, widths: WidthCache,
               available: float): seq[CellLine] =
  ## Break the runs into lines at explicit newlines and, failing that, at word
  ## boundaries inside the column width.
  var lines: seq[CellLine] = @[]
  var current = CellLine()
  let tm = fonts.textMetrics()

  for run in runs:
    let segments = run.text.split('\n')
    for index, segment in segments:
      if segment.len > 0:
        # Greedy word wrap within the column.
        var pending = ""
        for word in strutils.splitWhitespace(segment):
          let candidate = if pending.len == 0: word else: pending & " " & word
          let candidateWidth = textWidth(widths, tm, candidate, run.font)
          if current.width + candidateWidth <= available or
             (current.runs.len == 0 and pending.len == 0):
            pending = candidate
          else:
            if pending.len > 0:
              current.runs.add CellRun(text: pending, font: run.font,
                                       color: run.color, hasColor: run.hasColor,
                                       isCode: run.isCode)
              current.width += textWidth(widths, tm, pending, run.font)
            lines.add current
            current = CellLine()
            pending = word
        if pending.len > 0:
          current.runs.add CellRun(text: pending, font: run.font,
                                   color: run.color, hasColor: run.hasColor,
                                   isCode: run.isCode)
          current.width += textWidth(widths, tm, pending, run.font)
      if index + 1 < segments.len:
        lines.add current
        current = CellLine()
  if current.runs.len > 0 or lines.len == 0:
    lines.add current
  lines

proc drawCellRuns(painter: Painter, atlas: GlyphAtlas, fonts: FontManager,
                  lines: seq[CellLine], x, y, available, lineHeight: float,
                  alignment: TableAlignment, theme: MarkdownEditorTheme,
                  codeBackground: Color) =
  var cursorY = y
  for line in lines:
    var penX = x
    case alignment
    of tcaCenter: penX = x + max(0.0, (available - line.width) * 0.5)
    of tcaRight: penX = x + max(0.0, available - line.width)
    of tcaLeft: discard
    let metrics = if line.runs.len > 0: fonts.metricsFor(line.runs[0].font)
                  else: fonts.metricsFor(initFont("sans", 15.0))
    let baselineY = painter.snap(cursorY + metrics.ascent)
    for run in line.runs:
      let runWidth = fonts.measureString(run.text, run.font)
      if run.isCode and not codeBackground.isClear:
        painter.fillRoundedRect(penX - 1.0, cursorY + 1.0, runWidth + 2.0,
                                lineHeight - 2.0, 2.0, codeBackground)
      let tint = painter.resolve(if run.hasColor: run.color else: theme.bodyText)
      var glyphX = penX
      var previous = -1
      for rune in run.text.runes:
        let cp = int(rune)
        if previous >= 0:
          glyphX += fonts.kerningBetween(previous, cp, run.font)
        let entry = atlas.entryFor(run.font, cp)
        if entry.valid:
          atlas.drawGlyph(entry, glyphX, baselineY, tint)
        glyphX += fonts.measureCodePoint(cp, run.font)
        previous = cp
      penX += runWidth
    cursorY += lineHeight

proc drawTable*(painter: Painter, atlas: GlyphAtlas, fonts: FontManager,
                widths: WidthCache, config: MarkdownEditorConfiguration,
                source: string, x, y, availableWidth: float,
                baseFont: FontDesc) =
  ## Draw the table whose markdown source is `source`, with its top-left at
  ## `(x, y)`.
  ##
  ## The geometry comes from the same `measureTable` the styler used to reserve
  ## the band, so the drawn grid can never disagree with the space it was given.
  let (parsed, ok) = parseTableSource(source)
  if not ok: return
  let theme = config.theme
  let registry = config.extensionRegistry()
  let codeFont = config.services.syntaxHighlighter.codeFont(
    round(baseFont.size * config.codeBlock.fontSizeScale))
  let codeBackground = config.services.syntaxHighlighter.backgroundColor()
  let metrics = measureTable(parsed, fonts.textMetrics(), widths, baseFont,
                             availableWidth)
  if metrics.columnWidths.len == 0: return
  let lineHeight = lineHeight(fonts.textMetrics(), baseFont)
  let gridColor = painter.resolve(theme.tableGrid)

  # Header band, so the first row reads as a header without bold text alone
  # carrying it.
  if metrics.rowHeights.len > 0:
    painter.fillRect(x, y, metrics.naturalWidth, metrics.rowHeights[0],
                     theme.tableHeaderBackground)

  # Horizontal rules.
  var rowY = y
  painter.hLine(x, rowY, metrics.naturalWidth, gridColor, tableBorderWidth)
  for height in metrics.rowHeights:
    rowY += height + tableBorderWidth
    painter.hLine(x, rowY - tableBorderWidth, metrics.naturalWidth, gridColor,
                  tableBorderWidth)

  # Vertical rules.
  let totalHeight = metrics.totalHeight
  var columnX = x
  painter.vLine(columnX, y, totalHeight, gridColor, tableBorderWidth)
  for width in metrics.columnWidths:
    columnX += width + tableBorderWidth
    painter.vLine(columnX - tableBorderWidth, y, totalHeight, gridColor,
                  tableBorderWidth)

  # Cells.
  proc drawRow(cells: seq[string], rowTop, rowHeight: float, isHeader: bool) =
    var cellX = x + tableBorderWidth
    for col in 0 ..< metrics.columnWidths.len:
      let columnWidth = metrics.columnWidths[col]
      let available = max(1.0, columnWidth - 2 * tableCellHPadding)
      if col < cells.len and cells[col].len > 0:
        let font = if isHeader: baseFont.adding({ftBold}) else: baseFont
        let runs = formatCell(cells[col], font, codeFont, theme, registry)
        let lines = wrapRuns(runs, fonts, widths, available)
        painter.withClip(cellX, rowTop, columnWidth, rowHeight):
          drawCellRuns(painter, atlas, fonts, lines,
                       cellX + tableCellHPadding, rowTop + tableCellVPadding,
                       available, lineHeight, parsed.alignments[col], theme,
                       codeBackground)
      cellX += columnWidth + tableBorderWidth

  var cursorY = y + tableBorderWidth
  if metrics.rowHeights.len > 0:
    drawRow(parsed.header, cursorY, metrics.rowHeights[0], true)
    cursorY += metrics.rowHeights[0] + tableBorderWidth
  for i, row in parsed.rows:
    if i + 1 >= metrics.rowHeights.len: break
    drawRow(row, cursorY, metrics.rowHeights[i + 1], false)
    cursorY += metrics.rowHeights[i + 1] + tableBorderWidth
