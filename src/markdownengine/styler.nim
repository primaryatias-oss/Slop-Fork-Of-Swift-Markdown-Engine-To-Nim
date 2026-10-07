## styler.nim
## MarkdownEngine (Nim port)
##
## The styler facade. It builds the styling context, runs the AST styler for
## all text styling, then appends the passes that still consume TOKENS because
## they place rendered artefacts rather than text attributes:
##
## * block / inline LaTeX
## * image embeds (`![[…]]`) and image links (`![](…)`)
## * rendered tables
##
## Those three share one mechanism, the same one the directive glyph pass uses:
## the source characters are NEVER removed. They collapse to zero width via
## clear colour, the tiny marker font and negative kern, while one anchor
## character carries the artefact plus enough positive kern to occupy its
## width. Selection, find, copy and undo all still see the real characters —
## which is exactly what the "markers shrink, they don't disappear" invariant
## protects.
##
## Where the Swift original rasterised to `NSImage`, this port emits handles
## and lets the renderer draw: the engine never decodes, rasterises or paints
## anything.

import std/[algorithm, math, sets, strutils, tables]
import ./ranges, ./utf16text, ./color, ./font, ./attributes, ./theme
import ./services, ./configuration
import ./token, ./tokenizer, ./block_parser, ./detection
import ./ast_styler, ./table as tbl

export ast_styler

type
  IndexedToken* = tuple[index: int, token: MarkdownToken]

  ClassifiedStyleTokens* = object
    ## Per-kind token arrays (each with the token's index into the full array,
    ## for the active-token set), built ONCE in the parse classification and
    ## reused across keystrokes. Lets the artefact passes iterate a small,
    ## scope-sliced array instead of walking every document token per pass.
    inlineLatex*: seq[IndexedToken]
    blockLatex*: seq[IndexedToken]
    imageEmbed*: seq[IndexedToken]
    imageLink*: seq[IndexedToken]
    table*: seq[IndexedToken]
    heading*: seq[IndexedToken]
    blockquote*: seq[IndexedToken]
    code*: seq[MarkdownToken]   ## codeBlock + inlineCode, for the code checks

  StylingContext* = object
    text*: Utf16Text
    tokens*: seq[MarkdownToken]
    classified*: ClassifiedStyleTokens
    activeTokenIndices*: HashSet[int]
    config*: MarkdownEditorConfiguration
    tm*: TextMetrics
    widths*: WidthCache
    appearance*: Appearance
    baseFont*: FontDesc
    baseLineHeight*: float
    latexMarkerFont*: FontDesc
    containerWidth*: float
    scopeLo*: int
    scopeHi*: int
    hasScope*: bool
      ## Union bounds of the restyle's paragraph scope. Attribute application
      ## clips per paragraph anyway, so the artefact passes can skip tokens
      ## wholly outside these bounds instead of walking every token in the
      ## document per keystroke.

func services*(ctx: StylingContext): MarkdownEditorServices {.inline.} =
  ctx.config.services

func theme*(ctx: StylingContext): MarkdownEditorTheme {.inline.} = ctx.config.theme

func outsideScope*(ctx: StylingContext, r: Range): bool {.inline.} =
  ## True when `r` lies entirely outside the restyle scope — its attributes
  ## would be clipped away at application time.
  if not ctx.hasScope: return false
  maxRange(r) <= ctx.scopeLo or r.location >= ctx.scopeHi

proc classify*(tokens: seq[MarkdownToken]): ClassifiedStyleTokens =
  for i, tok in tokens:
    case tok.kind
    of tkInlineLatex: result.inlineLatex.add (i, tok)
    of tkBlockLatex: result.blockLatex.add (i, tok)
    of tkImageEmbed: result.imageEmbed.add (i, tok)
    of tkImageLink: result.imageLink.add (i, tok)
    of tkTable: result.table.add (i, tok)
    of tkHeading: result.heading.add (i, tok)
    of tkBlockquote: result.blockquote.add (i, tok)
    of tkCodeBlock, tkInlineCode: result.code.add tok
    else: discard

func scopedSlice*(arr: seq[IndexedToken], lo, hi: int): seq[IndexedToken] =
  ## Binary-searched slice of a location-sorted, non-overlapping per-kind array
  ## whose tokens intersect `[lo, hi)` — tokens outside are never visited.
  if arr.len == 0: return @[]
  var low = 0
  var high = arr.len
  while low < high:                             # first maxRange > lo
    let m = (low + high) div 2
    if maxRange(arr[m].token.range) > lo: high = m else: low = m + 1
  let start = low
  high = arr.len
  while low < high:                             # first location >= hi
    let m = (low + high) div 2
    if arr[m].token.range.location >= hi: high = m else: low = m + 1
  arr[start ..< low]

func scoped*(ctx: StylingContext, arr: seq[IndexedToken]): seq[IndexedToken] =
  if not ctx.hasScope: arr else: scopedSlice(arr, ctx.scopeLo, ctx.scopeHi)

# ---------------------------------------------------------------------------
# Shared collapse machinery
# ---------------------------------------------------------------------------

proc markerWidth(ctx: StylingContext, s: string): float {.inline.} =
  textWidth(ctx.widths, ctx.tm, s, ctx.latexMarkerFont)

proc hiddenKern(ctx: StylingContext, s: string): float {.inline.} =
  ## Per-character kern that collapses a hidden run to zero width.
  ##
  ## Kern is applied to EVERY character in the range, so a run of `n`
  ## characters ends up `width + n * kern` wide — feeding it the whole run's
  ## width made a long run `(n - 1)` widths too NEGATIVE, which poisons the
  ## document's usage bounds for every line.
  let count = max(1, utf16Len(s))
  markerWidth(ctx, s) / float(count)

proc appendSecondaryMarkers(ctx: StylingContext, tok: MarkdownToken,
                            attrs: var seq[StyledRange]) =
  for marker in tok.markerRanges:
    attrs.add (marker, @[(akForegroundColor, av(ctx.theme.mutedText))])

type
  ArtefactKind = enum
    afImage
    afLatex
    afTable

  Artefact = object
    kind: ArtefactKind
    image: ImageHandle
    width: float
    height: float
    baselineOffset: float
    tableSourceID: int
    tableNaturalWidth: float
    tableFullRange: Range

proc appendCollapsedBlock(ctx: StylingContext, tok: MarkdownToken,
                          artefact: Artefact, paragraphSpacingBefore,
                          paragraphSpacing: float, markerTexts: seq[string],
                          scrollableDisplayWidth: float, isScrollable: bool,
                          attrs: var seq[StyledRange]) =
  ## Hide a standalone block's raw source and plant the artefact on an anchor
  ## character inside it.
  ##
  ## The anchor is the first NON-whitespace character of the content, so the
  ## artefact's left edge lands where the content starts rather than inside the
  ## opener's padding. The anchor's paragraph keeps a real line height (grown to
  ## fit the artefact); every other paragraph of the block collapses to 1pt, so
  ## a multi-line source occupies one artefact-sized band instead of N lines.
  let paraRange = ctx.text.paragraphRange(tok.range)
  let neededLineHeight = ceil(artefact.height)

  let para = newParagraphStyle()
  para.minimumLineHeight = max(neededLineHeight, ctx.baseLineHeight)
  para.maximumLineHeight = para.minimumLineHeight
  para.paragraphSpacingBefore = paragraphSpacingBefore
  para.paragraphSpacing = paragraphSpacing
  para.lineBreakMode = lbClipping

  let collapsedPara = newParagraphStyle()
  collapsedPara.maximumLineHeight = 1
  collapsedPara.minimumLineHeight = 1
  collapsedPara.paragraphSpacing = 0
  collapsedPara.paragraphSpacingBefore = 0

  # Leading whitespace of the content is hidden separately, so the anchor is
  # the first visible character.
  var leadingWhitespaceUnits = 0
  while leadingWhitespaceUnits < tok.contentRange.length and
        isWhitespaceOrNewlineUnit(
          ctx.text.charAt(tok.contentRange.location + leadingWhitespaceUnits)):
    inc leadingWhitespaceUnits
  let contentEnd = maxRange(tok.contentRange)
  let anchorLocation = min(tok.contentRange.location + leadingWhitespaceUnits,
                           max(tok.contentRange.location, contentEnd - 1))

  for paragraph in ctx.text.lineRanges(paraRange):
    if contains(paragraph, anchorLocation):
      attrs.add (paragraph, @[(akParagraphStyle, av(para))])
    else:
      attrs.add (paragraph, @[(akParagraphStyle, av(collapsedPara))])

  if leadingWhitespaceUnits > 0:
    let leadingRange = rng(tok.contentRange.location, leadingWhitespaceUnits)
    let leadingText = ctx.text.substring(leadingRange)
    attrs.add (leadingRange, @[(akForegroundColor, av(clearColor)),
                               (akFont, av(ctx.latexMarkerFont)),
                               (akKern, av(-hiddenKern(ctx, leadingText)))])

  let anchorRange = rng(anchorLocation, 1)
  let anchorChar = ctx.text.substring(anchorRange)
  var anchorAttrs: Attrs = @[]
  case artefact.kind
  of afImage:
    anchorAttrs.add (akImageEmbed, av(artefact.image))
    anchorAttrs.add (akImageBounds,
                     av(ImageHandle(width: artefact.width, height: artefact.height,
                                    baselineOffset: artefact.baselineOffset)))
  of afLatex:
    anchorAttrs.add (akLatexImage, av(artefact.image))
    anchorAttrs.add (akLatexBounds,
                     av(ImageHandle(width: artefact.width, height: artefact.height,
                                    baselineOffset: artefact.baselineOffset)))
    anchorAttrs.add (akLatexIsBlock, av(true))
  of afTable:
    anchorAttrs.add (akTableRender, av(artefact.tableFullRange))
    anchorAttrs.add (akScrollableBlockNaturalWidth, av(artefact.tableNaturalWidth))
    anchorAttrs.add (akScrollableBlockTotalHeight, av(artefact.height))
    anchorAttrs.add (akScrollableBlockFullRange, av(artefact.tableFullRange))
    if isScrollable:
      anchorAttrs.add (akScrollableBlockSourceID, av(artefact.tableSourceID))
  anchorAttrs.add (akForegroundColor, av(clearColor))
  anchorAttrs.add (akFont, av(ctx.latexMarkerFont))
  let advanceWidth = if isScrollable: scrollableDisplayWidth else: artefact.width
  anchorAttrs.add (akKern, av(advanceWidth - markerWidth(ctx, anchorChar)))
  attrs.add (anchorRange, anchorAttrs)

  let trailingStart = anchorLocation + 1
  let trailingLength = contentEnd - trailingStart
  if trailingLength > 0:
    let trailingRange = rng(trailingStart, trailingLength)
    let trailingText = ctx.text.substring(trailingRange)
    attrs.add (trailingRange, @[(akForegroundColor, av(clearColor)),
                                (akFont, av(ctx.latexMarkerFont)),
                                (akKern, av(-hiddenKern(ctx, trailingText)))])

  for index, markerRange in tok.markerRanges:
    let markerText = if index < markerTexts.len: markerTexts[index]
                     else: ctx.text.substring(markerRange)
    attrs.add (markerRange, @[(akForegroundColor, av(clearColor)),
                              (akFont, av(ctx.latexMarkerFont)),
                              (akKern, av(-hiddenKern(ctx, markerText)))])

  let preTokenLength = tok.range.location - paraRange.location
  if preTokenLength > 0:
    let preTokenRange = rng(paraRange.location, preTokenLength)
    let preTokenText = ctx.text.substring(preTokenRange)
    attrs.add (preTokenRange, @[(akForegroundColor, av(clearColor)),
                                (akFont, av(ctx.latexMarkerFont)),
                                (akKern, av(-hiddenKern(ctx, preTokenText)))])

# ---------------------------------------------------------------------------
# LaTeX
# ---------------------------------------------------------------------------

proc latexFontSize(ctx: StylingContext, tok: MarkdownToken,
                   headings: seq[IndexedToken]): float =
  ## Use the heading context to scale LaTeX consistently with surrounding text.
  ## `headings` is built ONCE per styling pass — scanning all tokens per LaTeX
  ## token here was O(#latex × #tokens).
  for (_, heading) in headings:
    if contains(heading.contentRange, tok.contentRange.location):
      let level = if heading.markerRanges.len > 0: heading.markerRanges[0].length else: 1
      return ctx.baseFont.size * ctx.config.headings.fontMultiplier(level)
  ctx.baseFont.size

proc styleBlockLatex*(ctx: StylingContext): seq[StyledRange] =
  for (idx, tok) in ctx.scoped(ctx.classified.blockLatex):
    if isInsideCodeBlock(tok.range, ctx.classified.code): continue
    let isActive = idx in ctx.activeTokenIndices
    let rawLatexContent = ctx.text.substring(tok.contentRange)
    let latexContent = trimWhitespaceAndNewlines(rawLatexContent)

    result.add (tok.range, @[(akSpellingState, av(0))])

    let (_, standalone) = tok.standaloneParagraphRange(ctx.text)
    if not standalone: continue

    # Block `$$` is never inside a heading.
    let fontSize = ctx.baseFont.size

    if isActive:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    if latexContent.len == 0:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    let (entry, rendered) = ctx.services.latex.render(
      latexContent, lrDisplay, fontSize, ctx.theme, ctx.appearance)
    if not rendered:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    appendCollapsedBlock(
      ctx, tok,
      Artefact(kind: afLatex, image: entry.image, width: entry.width,
               height: entry.height, baselineOffset: entry.baselineOffset),
      ctx.config.blockLatex.paragraphSpacingBefore,
      ctx.config.blockLatex.paragraphSpacing,
      @["$$", "$$"], 0.0, false, result)

proc styleInlineLatex*(ctx: StylingContext): seq[StyledRange] =
  ## Tables render their own cell contents (including `$…$`) as one artefact.
  ## If the source `$x^2$` were ALSO tagged with an inline image, the renderer
  ## would draw that tiny image on the collapsed 1pt source line under the
  ## table — visible as a stray dot. So inline LaTeX inside a table is skipped;
  ## the table artefact already covers it.
  let scopedLatex = ctx.scoped(ctx.classified.inlineLatex)
  if scopedLatex.len == 0: return @[]

  # Containers that ENCLOSE an in-scope formula must overlap the scope, so
  # scope-slicing these is exact; built once, not per formula.
  var tableRanges: seq[Range] = @[]
  for (_, tok) in ctx.scoped(ctx.classified.table): tableRanges.add tok.range
  # Quote lines mute their text via the foreground colour, which a rendered
  # formula ignores — render it in `mutedText` instead so it matches the grey.
  var blockquoteRanges: seq[Range] = @[]
  for (_, tok) in ctx.classified.blockquote: blockquoteRanges.add tok.range
  let headings = ctx.scoped(ctx.classified.heading)

  # Each measurement is a real text measure; the two `$` marker widths are
  # loop-invariant (the fonts are constant), so hoist them.
  let tinyDollarWidth = markerWidth(ctx, "$")
  let baseDollarWidth = textWidth(ctx.widths, ctx.tm, "$", ctx.baseFont)

  for (idx, tok) in scopedLatex:
    if isInsideCodeBlock(tok.range, ctx.classified.code): continue
    var insideTable = false
    for tableRange in tableRanges:
      if tok.range.location >= tableRange.location and
         maxRange(tok.range) <= maxRange(tableRange):
        insideTable = true
        break
    if insideTable: continue

    result.add (tok.range, @[(akSpellingState, av(0))])

    let isActive = idx in ctx.activeTokenIndices
    let latexContent = ctx.text.substring(tok.contentRange)
    let fontSize = latexFontSize(ctx, tok, headings)

    if isActive:
      appendSecondaryMarkers(ctx, tok, result)
      continue

    var renderTheme = ctx.theme
    for quoteRange in blockquoteRanges:
      if contains(quoteRange, tok.range.location):
        renderTheme.latexLightModeText = renderTheme.mutedText
        renderTheme.latexDarkModeText = renderTheme.mutedText
        break

    let (entry, rendered) = ctx.services.latex.render(
      latexContent, lrInline, fontSize, renderTheme, ctx.appearance)
    if not rendered:
      appendSecondaryMarkers(ctx, tok, result)
      continue

    let contentLength = tok.contentRange.length
    if contentLength > 0:
      let firstCharRange = rng(tok.contentRange.location, 1)
      let firstChar = ctx.text.substring(firstCharRange)
      result.add (firstCharRange,
                  @[(akLatexImage, av(entry.image)),
                    (akLatexBounds, av(ImageHandle(width: entry.width,
                                                   height: entry.height,
                                                   baselineOffset: entry.baselineOffset))),
                    (akForegroundColor, av(clearColor)),
                    (akFont, av(ctx.latexMarkerFont)),
                    (akKern, av(entry.width - markerWidth(ctx, firstChar)))])
      if contentLength > 1:
        let restRange = rng(tok.contentRange.location + 1, contentLength - 1)
        let restText = ctx.text.substring(restRange)
        result.add (restRange, @[(akForegroundColor, av(clearColor)),
                                 (akFont, av(ctx.latexMarkerFont)),
                                 (akKern, av(-hiddenKern(ctx, restText)))])

    if tok.markerRanges.len >= 2:
      result.add (tok.markerRanges[0], @[(akFont, av(ctx.latexMarkerFont)),
                                         (akForegroundColor, av(clearColor)),
                                         (akKern, av(-tinyDollarWidth))])
      result.add (tok.markerRanges[1], @[(akForegroundColor, av(clearColor)),
                                         (akKern, av(-baseDollarWidth))])

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

func parseEmbedReference(raw: string): EmbeddedImageRequest =
  ## `![[name|optional-id|optional-width]]` → a provider request.
  let parts = raw.split('|')
  result = EmbeddedImageRequest(name: trimWhitespaceAndNewlines(
    if parts.len > 0: parts[0] else: raw))
  if parts.len > 1 and trimWhitespaceAndNewlines(parts[1]).len > 0:
    result.id = trimWhitespaceAndNewlines(parts[1])
    result.hasID = true
  if parts.len > 2:
    try:
      result.requestedWidth = parseFloat(trimWhitespaceAndNewlines(parts[2]))
      result.hasRequestedWidth = true
    except ValueError:
      discard

proc fittedImageSize(ctx: StylingContext, handle: ImageHandle,
                     requestedWidth: float, hasRequestedWidth: bool): (float, float) =
  ## Fit an image to the reading column, honouring an explicit width request
  ## and the configured bounds.
  let style = ctx.config.imageEmbed
  var maxWidth = ctx.containerWidth
  if maxWidth <= 0 or maxWidth > style.unreasonableMaxWidth:
    maxWidth = style.fallbackMaxWidth
  var width = if hasRequestedWidth and requestedWidth > 0: requestedWidth
              else: handle.width
  if width <= 0: width = maxWidth
  width = max(style.minimumWidth, min(width, maxWidth))
  let scale = if handle.width > 0: width / handle.width else: 1.0
  let height = if handle.height > 0: handle.height * scale else: width * 0.6
  (floor(width), floor(height))

proc styleImageEmbeds*(ctx: StylingContext): seq[StyledRange] =
  for (idx, tok) in ctx.scoped(ctx.classified.imageEmbed):
    if isInsideCodeBlock(tok.range, ctx.classified.code): continue
    result.add (tok.range, @[(akSpellingState, av(0))])
    let isActive = idx in ctx.activeTokenIndices or
                   tok.containsSelectionOrStandaloneParagraph(-1, ctx.text) and false
    if isActive:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    let (_, standalone) = tok.standaloneParagraphRange(ctx.text)
    if not standalone:
      # An inline embed stays literal: collapsing it would leave the line with
      # a hole the reader can neither see nor fix.
      appendSecondaryMarkers(ctx, tok, result)
      continue
    let request = parseEmbedReference(ctx.text.substring(tok.contentRange))
    let (handle, found) = ctx.services.images.image(request)
    if not found:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    let (width, height) = fittedImageSize(ctx, handle, request.requestedWidth,
                                          request.hasRequestedWidth)
    appendCollapsedBlock(
      ctx, tok,
      Artefact(kind: afImage, image: handle, width: width, height: height),
      ctx.config.imageEmbed.paragraphSpacing,
      ctx.config.imageEmbed.paragraphSpacing,
      @["![[", "]]"], 0.0, false, result)

proc styleImageLinks*(ctx: StylingContext): seq[StyledRange] =
  for (idx, tok) in ctx.scoped(ctx.classified.imageLink):
    if isInsideCodeBlock(tok.range, ctx.classified.code): continue
    result.add (tok.range, @[(akSpellingState, av(0))])
    if idx in ctx.activeTokenIndices:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    let (_, standalone) = tok.standaloneParagraphRange(ctx.text)
    if not standalone:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    # `markerRanges` is `[ "![", "]", "(", ")" ]`, so the URL is between the
    # last two markers.
    if tok.markerRanges.len < 4:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    let urlRange = rng(maxRange(tok.markerRanges[2]),
                       tok.markerRanges[3].location - maxRange(tok.markerRanges[2]))
    var request = EmbeddedImageRequest(name: ctx.text.substring(urlRange))
    let (handle, found) = ctx.services.images.image(request)
    if not found:
      appendSecondaryMarkers(ctx, tok, result)
      continue
    let (width, height) = fittedImageSize(ctx, handle, 0.0, false)
    appendCollapsedBlock(
      ctx, tok,
      Artefact(kind: afImage, image: handle, width: width, height: height),
      ctx.config.imageEmbed.paragraphSpacing,
      ctx.config.imageEmbed.paragraphSpacing,
      @[], 0.0, false, result)

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

type
  TableMetrics* = object
    ## The geometry the renderer and the styler must agree on, derived from the
    ## parse alone so both can compute it from the same source.
    columnWidths*: seq[float]
    rowHeights*: seq[float]
    naturalWidth*: float
    totalHeight*: float

const
  tableCellHPadding* = 8.0
  tableCellVPadding* = 4.0
  tableBorderWidth* = 1.0

proc measureTable*(parsed: ParsedTable, tm: TextMetrics, widths: WidthCache,
                   font: FontDesc, availableWidth: float): TableMetrics =
  ## Column widths from the widest cell, then shrunk proportionally to fit the
  ## available width; row heights from the wrapped line count.
  let columnCount = parsed.alignments.len
  if columnCount == 0: return TableMetrics()
  var columnWidths = newSeq[float](columnCount)

  proc consider(cell: string, col: int) =
    var widest = 0.0
    for line in expandCellLineBreaks(cell).splitLines():
      widest = max(widest, textWidth(widths, tm, line, font))
    columnWidths[col] = max(columnWidths[col], widest + 2 * tableCellHPadding)

  for col in 0 ..< columnCount:
    if col < parsed.header.len: consider(parsed.header[col], col)
  for row in parsed.rows:
    for col in 0 ..< min(columnCount, row.len): consider(row[col], col)

  var total = 0.0
  for w in columnWidths: total += w
  total += float(columnCount + 1) * tableBorderWidth
  let naturalWidth = total

  # Shrink proportionally when the natural width overflows, with a floor so a
  # column never collapses below a few characters.
  if availableWidth > 0 and total > availableWidth:
    let floorWidth = 3 * tableCellHPadding
    var flexible = 0.0
    for w in columnWidths:
      if w > floorWidth: flexible += w - floorWidth
    let overflow = total - availableWidth
    if flexible > 0:
      let ratio = min(1.0, overflow / flexible)
      for i in 0 ..< columnCount:
        if columnWidths[i] > floorWidth:
          columnWidths[i] -= (columnWidths[i] - floorWidth) * ratio

  let lh = lineHeight(tm, font)
  proc rowHeight(cells: seq[string]): float =
    var lines = 1
    for col in 0 ..< min(columnCount, cells.len):
      var cellLines = 0
      let avail = max(1.0, columnWidths[col] - 2 * tableCellHPadding)
      for line in expandCellLineBreaks(cells[col]).splitLines():
        let w = textWidth(widths, tm, line, font)
        cellLines += max(1, int(ceil(w / avail)))
      lines = max(lines, cellLines)
    float(lines) * lh + 2 * tableCellVPadding

  var rowHeights = @[rowHeight(parsed.header)]
  for row in parsed.rows: rowHeights.add rowHeight(row)
  var totalHeight = float(rowHeights.len + 1) * tableBorderWidth
  for h in rowHeights: totalHeight += h
  TableMetrics(columnWidths: columnWidths, rowHeights: rowHeights,
               naturalWidth: naturalWidth, totalHeight: totalHeight)

proc styleTables*(ctx: StylingContext): seq[StyledRange] =
  ## Per-content occurrence counter so identical tables get distinct source
  ## ids — the key the renderer reconciles horizontal scroll offsets by.
  var occurrenceByContentHash = initTable[int, int]()

  # A source id is only CONSUMED by a table that renders this pass (inactive +
  # in scope). Equal content implies equal source length, so only tables
  # sharing a length with a rendering table can affect its occurrence index —
  # every other inactive table skips the substring, the parse and the hash.
  # Typing prose renders no table, so all tables skip.
  var neededLengths = initHashSet[int]()
  for (idx, tok) in ctx.classified.table:
    if idx notin ctx.activeTokenIndices and not ctx.outsideScope(tok.range):
      neededLengths.incl tok.range.length

  for (idx, tok) in ctx.classified.table:
    let isActive = idx in ctx.activeTokenIndices
    if not isActive and tok.range.length notin neededLengths: continue
    # The tokenizer already drops tables overlapping fenced code.
    result.add (tok.range, @[(akSpellingState, av(0))])

    let source = ctx.text.substring(tok.range)
    let (parsed, ok) = parseTableSource(source)
    if not ok: continue

    # Advance the occurrence index even for active/out-of-scope tables so
    # inactive duplicates keep stable ids.
    let contentHash = stableTableContentHash(source)
    let occurrenceIndex = occurrenceByContentHash.getOrDefault(contentHash, 0)
    occurrenceByContentHash[contentHash] = occurrenceIndex + 1

    if isActive:
      # Caret inside the table — show editable source, pipes muted like other
      # syntax so the structure stays legible while editing.
      result.add (tok.range, @[(akForegroundColor, av(ctx.theme.bodyText)),
                               (akFont, av(ctx.baseFont))])
      for i in tok.range.location ..< maxRange(tok.range):
        if ctx.text.charAt(i) == chPipe:
          result.add (rng(i, 1), @[(akForegroundColor, av(ctx.theme.mutedText))])
      continue

    # Outside the restyle scope the anchor attrs would be clipped away at
    # application time — skip the measure and the anchor build (the occurrence
    # bookkeeping above already ran, keeping ids stable).
    if ctx.outsideScope(tok.range): continue

    # Cells wrap to the container width; the measure only exceeds it when the
    # per-column floors genuinely don't fit, in which case the renderer's
    # horizontal overlay takes over.
    let metrics = measureTable(parsed, ctx.tm, ctx.widths, ctx.baseFont,
                               ctx.containerWidth)
    # Geometry is fractional in split layouts, so allow floating-point noise;
    # a real sub-point overflow still needs horizontal scrolling.
    let widthEpsilon = 0.01
    let isWide = metrics.naturalWidth - ctx.containerWidth > widthEpsilon
    appendCollapsedBlock(
      ctx, tok,
      Artefact(kind: afTable, width: metrics.naturalWidth,
               height: metrics.totalHeight,
               tableSourceID: stableTableSourceID(source, occurrenceIndex),
               tableNaturalWidth: metrics.naturalWidth,
               tableFullRange: tok.range),
      ctx.baseLineHeight * 0.5, ctx.baseLineHeight * 0.5,
      @[], ctx.containerWidth, isWide, result)

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

proc makeStylingContext*(t: Utf16Text, config: MarkdownEditorConfiguration,
                         tm: TextMetrics, widths: WidthCache,
                         appearance: Appearance,
                         activeTokenIndices: HashSet[int],
                         tokens: seq[MarkdownToken],
                         classified: ClassifiedStyleTokens,
                         containerWidth: float,
                         scopedRanges: seq[Range],
                         hasScope: bool): StylingContext =
  let baseFont = initFont(config.fontName, config.fontSize)
  var lo = 0
  var hi = 0
  var scoped = false
  if hasScope:
    var seen = false
    for r in scopedRanges:
      if r.location == NotFound or r.length <= 0: continue
      if not seen:
        lo = r.location
        hi = maxRange(r)
        seen = true
      else:
        lo = min(lo, r.location)
        hi = max(hi, maxRange(r))
    scoped = seen
  StylingContext(
    text: t, tokens: tokens, classified: classified,
    activeTokenIndices: activeTokenIndices, config: config, tm: tm,
    widths: widths, appearance: appearance, baseFont: baseFont,
    baseLineHeight: lineHeight(tm, baseFont),
    latexMarkerFont: initFont(config.fontName, config.markers.hiddenMarkerFontSize),
    containerWidth: containerWidth, scopeLo: lo, scopeHi: hi, hasScope: scoped)

proc styleAttributes*(t: Utf16Text, config: MarkdownEditorConfiguration,
                      tm = defaultTextMetrics, widths: WidthCache = nil,
                      appearance = apLight, caretLocation = -1,
                      selection = Range(), hasSelection = false,
                      activeTokenIndices = initHashSet[int](),
                      wikiLinkID: WikiLinkIDProvider = nil,
                      precomputedTokens: seq[MarkdownToken] = @[],
                      hasPrecomputedTokens = false,
                      precomputedBlocks: seq[Block] = @[],
                      hasPrecomputedBlocks = false,
                      containerWidth = 0.0,
                      scopedRanges: seq[Range] = @[],
                      hasScope = false): seq[StyledRange] =
  ## The full styling pass: the AST styler for text, then the artefact passes.
  let registry = config.extensionRegistry()
  let tokens = if hasPrecomputedTokens: precomputedTokens
               else: parseTokens(t, registry)
  let ctx = makeStylingContext(t, config, tm, widths, appearance,
                               activeTokenIndices, tokens, classify(tokens),
                               containerWidth, scopedRanges, hasScope)

  result = styleAST(t, config, tm, widths, appearance, caretLocation, selection,
                    hasSelection, wikiLinkID, scopedRanges, hasScope,
                    precomputedBlocks, hasPrecomputedBlocks)
  result.add styleBlockLatex(ctx)
  result.add styleInlineLatex(ctx)
  result.add styleImageEmbeds(ctx)
  result.add styleImageLinks(ctx)
  result.add styleTables(ctx)

proc styleTableAttributes*(t: Utf16Text, config: MarkdownEditorConfiguration,
                           tm = defaultTextMetrics, widths: WidthCache = nil,
                           appearance = apLight,
                           activeTokenIndices = initHashSet[int](),
                           precomputedTokens: seq[MarkdownToken] = @[],
                           hasPrecomputedTokens = false,
                           containerWidth = 0.0,
                           scopedRanges: seq[Range] = @[],
                           hasScope = false): seq[StyledRange] =
  ## Width changes only affect table geometry. Bypassing the generic AST pass
  ## and the unrelated artefact passes keeps an all-table resize linear in the
  ## number of tables.
  let registry = config.extensionRegistry()
  let tokens = if hasPrecomputedTokens: precomputedTokens
               else: parseTokens(t, registry)
  let ctx = makeStylingContext(t, config, tm, widths, appearance,
                               activeTokenIndices, tokens, classify(tokens),
                               containerWidth, scopedRanges, hasScope)
  styleTables(ctx)

# ---------------------------------------------------------------------------
# Flattening
# ---------------------------------------------------------------------------

proc flattenedRuns*(ranges: seq[StyledRange], base: Attrs,
                    documentLength: int): seq[StyledRange] =
  ## Collapse styler output into non-overlapping runs, ascending, so a caller
  ## can write each character range exactly once.
  ##
  ## The styler emits ranges pass by pass, so they arrive unordered and heavily
  ## overlapping. Applying them with one write per key per range mutates the
  ## storage once per pair, and every mutation re-splits the attribute-run
  ## array, so the cost of a single call grows with the runs already present —
  ## a quadratic that dominated document open. Writing left to right instead
  ## only ever splits the trailing run.
  ##
  ## Semantics are identical to the loop it replaces: later ranges win per key,
  ## and `base` fills what no range covers.
  type Event = tuple[pos: int, isStart: bool, idx: int]
  var events: seq[Event] = @[]
  for i, styled in ranges:
    let r = styled.range
    if r.location == NotFound or r.location < 0 or r.length <= 0: continue
    if maxRange(r) > documentLength: continue
    events.add (r.location, true, i)
    events.add (maxRange(r), false, i)
  if events.len == 0: return @[]
  # Ends sort before starts at the same position so a range ending where the
  # next begins doesn't briefly overlap it.
  events.sort(proc (a, b: Event): int =
    if a.pos != b.pos: return cmp(a.pos, b.pos)
    if a.isStart != b.isStart: return (if a.isStart: 1 else: -1)
    cmp(a.idx, b.idx))

  # Emission indices of the ranges covering the current position, kept
  # ascending so merging them in order reproduces "later range wins".
  var active: seq[int] = @[]
  var cursor = events[0].pos
  var i = 0
  while i < events.len:
    let pos = events[i].pos
    if pos > cursor and active.len > 0:
      var merged = base
      for idx in active:
        for pair in ranges[idx].attributes: merged.put(pair.key, pair.value)
      let run = rng(cursor, pos - cursor)
      # Adjacent runs frequently carry identical attributes — one styling pass
      # emits a separate range per character — so coalesce before the write
      # instead of paying a mutation per character.
      if result.len > 0 and maxRange(result[^1].range) == run.location and
         result[^1].attributes == merged:
        result[^1].range.length += run.length
      else:
        result.add (run, merged)
    while i < events.len and events[i].pos == pos:
      let event = events[i]
      if event.isStart:
        var slot = active.len
        for k in 0 ..< active.len:
          if active[k] > event.idx:
            slot = k
            break
        active.insert(event.idx, slot)
      else:
        for k in 0 ..< active.len:
          if active[k] == event.idx:
            active.delete(k)
            break
      inc i
    cursor = pos
