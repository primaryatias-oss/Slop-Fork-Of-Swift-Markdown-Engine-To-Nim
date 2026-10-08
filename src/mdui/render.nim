## render.nim
## MarkdownEngine (Nim port) — UI layer
##
## What `MarkdownTextLayoutFragment` did: draw the laid-out text and every
## decoration the styler tagged.
##
## The draw order is the Swift fragment's, for the same reasons:
##
## 1. code-block backgrounds (full container width, behind everything)
## 2. line-box fills (`==highlight==` and friends — taller than the glyphs)
## 3. glyph-box backgrounds (inline code)
## 4. find-match highlights, then the selection
## 5. artefacts: tables, images, LaTeX (behind the text, whose source is
##    collapsed to nothing anyway)
## 6. the text itself
## 7. underlines and strikethroughs
## 8. task checkboxes, bullet glyphs, ordered markers — all painted OVER the
##    source characters the styler cleared, so a cleared slot is never empty
## 9. thematic breaks (full width, painted late so nothing fights them)
## 10. blockquote bars (left gutter)
## 11. the caret
##
## Two of those orderings carry a bug fix from the original, noted at the call
## sites: a cleared bullet or checkbox MUST always be repainted (a
## selection-skip there left blank slots), and an ordered marker must NOT flip
## back to its source digits under a selection (the number is positional).

import std/[math, tables, unicode]
import ../markdownengine/[ranges, color, font, attributes, theme, services,
                          configuration, ast_styler]
import ./fontmanager, ./textstorage, ./layout, ./atlas, ./painter, ./tablerender

type
  RenderContext* = object
    painter*: Painter
    atlas*: GlyphAtlas
    fonts*: FontManager
    images*: ImageStore
    layout*: TextLayout
    storage*: TextStorage
    config*: MarkdownEditorConfiguration
    widths*: WidthCache
    baseFont*: FontDesc
    scrollY*: float
    viewportTop*: float
    viewportHeight*: float
    viewX*: float
      ## Left edge of the text column in VIEW coordinates, so document x can be
      ## mapped straight through.
    viewY*: float
    containerWidth*: float
    selection*: Range
    hasFocus*: bool
    caretVisible*: bool
    findMatches*: seq[Range]
    currentMatch*: int
    tableOffsets*: Table[int, float]
      ## sourceID → horizontal scroll offset for a wide table.

func theme*(ctx: RenderContext): MarkdownEditorTheme {.inline.} = ctx.config.theme

func toView(ctx: RenderContext, x, y: float): (float, float) {.inline.} =
  (x + ctx.viewX, y - ctx.scrollY + ctx.viewY)

proc isCodeBackground(ctx: RenderContext, c: Color): bool {.inline.} =
  ## The styler marks a fenced block by painting the highlighter's background
  ## colour on it, and the renderer recognises a code line by that colour —
  ## exactly the test the Swift fragment used.
  c == ctx.config.services.syntaxHighlighter.backgroundColor()

# ---------------------------------------------------------------------------
# Backgrounds
# ---------------------------------------------------------------------------

proc codeBackgroundOf(ctx: RenderContext,
                      line: LineFragment): (Color, bool) =
  ## Only the line's FIRST character decides, mirroring the original: an inline
  ## code span inside prose carries the same colour but must not flood the
  ## line.
  if line.items.len == 0: return (clearColor, false)
  let first = line.items[0].attributes
  if not first.has(akBackgroundColor): return (clearColor, false)
  let fill = first.colorOf(akBackgroundColor, clearColor)
  if not ctx.isCodeBackground(fill) or fill.isClear: return (clearColor, false)
  (fill, true)

proc drawCodeBlockBackgrounds(ctx: RenderContext, top, bottom: float) =
  ## Full-width fill behind a fenced code block, drawn as ONE rectangle per
  ## run of code lines.
  ##
  ## Per line it would leave a seam at every line break: the code paragraph
  ## style carries 2pt of spacing before and after, and the styler puts it on
  ## every line of the block because each source line is its own paragraph.
  ## The Swift fragment filled `layoutFragmentFrame.height`, which already
  ## included that spacing; merging the run here is the same fill by another
  ## route, and it also survives a block whose lines differ in height.
  var runTop = 0.0
  var runBottom = 0.0
  var runColor = clearColor
  var active = false

  proc flush(ctx: RenderContext) =
    if not active: return
    ctx.painter.fillRect(ctx.viewX, ctx.painter.snap(runTop),
                         ctx.containerWidth,
                         ctx.painter.snap(runBottom) - ctx.painter.snap(runTop),
                         runColor)
    active = false

  for line in ctx.layout.visibleLines(top, bottom):
    let (fill, isCode) = ctx.codeBackgroundOf(line)
    if not isCode:
      ctx.flush()
      continue
    let (_, vy) = ctx.toView(0.0, line.origin.y)
    if active and fill == runColor and vy <= runBottom + 0.51:
      runBottom = max(runBottom, vy + line.height)
    else:
      ctx.flush()
      active = true
      runColor = fill
      runTop = vy
      runBottom = vy + line.height
  ctx.flush()

proc drawBlockBackgrounds(ctx: RenderContext, line: LineFragment) =
  ## `akMarkdownBlockBackground` covers the whole LINE BOX, not the glyph box,
  ## so a highlight that wraps over several lines reads as one solid block
  ## instead of a band per line with a gap between them.
  var runStart = -1
  var runColor = clearColor
  var runLeft = 0.0
  var runRight = 0.0

  proc flush(ctx: RenderContext) =
    if runStart < 0 or runColor.isClear: return
    let (_, vy) = ctx.toView(0.0, line.origin.y)
    ctx.painter.fillRect(runLeft + ctx.viewX, vy, runRight - runLeft,
                         line.height, runColor)
    runStart = -1

  for i, item in line.items:
    let fill = item.attributes.colorOf(akMarkdownBlockBackground, clearColor)
    if fill.isClear or item.codePoint == 0x0A or item.codePoint == 0x0D:
      ctx.flush()
      continue
    let left = line.textOriginX + item.x
    let right = left + item.advance
    if runStart >= 0 and fill == runColor and abs(left - runRight) < 0.51:
      runRight = right
    else:
      ctx.flush()
      runStart = i
      runColor = fill
      runLeft = left
      runRight = right
  ctx.flush()

proc drawGlyphBackgrounds(ctx: RenderContext, line: LineFragment) =
  ## `akBackgroundColor` on an inline run — the code-span tint. Coalesced into
  ## spans so a `code` span is one rectangle, not one per character.
  var runStart = -1
  var runColor = clearColor
  var runLeft = 0.0
  var runRight = 0.0

  proc flush(ctx: RenderContext) =
    if runStart < 0 or runColor.isClear: return
    let (_, vy) = ctx.toView(0.0, line.origin.y)
    let inset = max(0.0, (line.height - (line.ascent + line.descent)) * 0.5)
    ctx.painter.fillRoundedRect(runLeft + ctx.viewX, vy + inset,
                                runRight - runLeft,
                                line.height - inset * 2.0, 3.0, runColor)
    runStart = -1

  let (_, lineIsCode) = ctx.codeBackgroundOf(line)
  if lineIsCode: return        # the fenced block already drew its full-width fill
  for i, item in line.items:
    let fill = item.attributes.colorOf(akBackgroundColor, clearColor)
    if fill.isClear or item.codePoint == 0x0A or item.codePoint == 0x0D:
      ctx.flush()
      continue
    let left = line.textOriginX + item.x
    let right = left + item.advance
    if runStart >= 0 and fill == runColor and abs(left - runRight) < 0.51:
      runRight = right
    else:
      ctx.flush()
      runStart = i
      runColor = fill
      runLeft = left
      runRight = right
  ctx.flush()

proc drawHighlightRects(ctx: RenderContext, line: LineFragment,
                        ranges: seq[Range], fill: Rgba) =
  for r in ranges:
    if r.length <= 0: continue
    if maxRange(line.range) <= r.location or line.range.location >= maxRange(r):
      continue
    var lo = high(float)
    var hi = low(float)
    for item in line.items:
      if item.location + item.length <= r.location: continue
      if item.location >= maxRange(r): break
      lo = min(lo, line.textOriginX + item.x)
      let advance = if item.codePoint == 0x0A or item.codePoint == 0x0D:
                      max(4.0, item.advance)
                    else: item.advance
      hi = max(hi, line.textOriginX + item.x + advance)
    if lo > hi: continue
    let (_, vy) = ctx.toView(0.0, line.origin.y)
    ctx.painter.fillRect(lo + ctx.viewX, vy, hi - lo, line.height, fill)

# ---------------------------------------------------------------------------
# Artefacts
# ---------------------------------------------------------------------------

proc drawArtefacts(ctx: RenderContext, line: LineFragment) =
  ## Tables, images and LaTeX, each anchored on a single character whose kern
  ## reserves the artefact's width.
  for item in line.items:
    let (_, vy) = ctx.toView(0.0, line.origin.y)
    let x = line.textOriginX + item.x + ctx.viewX

    # A rendered table: drawn from the parse, with the same metrics the styler
    # measured, so the reserved band and the drawn grid always agree.
    if item.attributes.has(akTableRender):
      let sourceRange = item.attributes.get(akTableRender)
      if sourceRange.kind != avRange: continue
      let naturalWidth = item.attributes.floatOf(akScrollableBlockNaturalWidth,
                                                 ctx.containerWidth)
      let totalHeight = item.attributes.floatOf(akScrollableBlockTotalHeight,
                                                line.height)
      let isWide = naturalWidth > ctx.containerWidth + 0.01
      var offsetX = 0.0
      if isWide and item.attributes.has(akScrollableBlockSourceID):
        offsetX = ctx.tableOffsets.getOrDefault(
          item.attributes.intOf(akScrollableBlockSourceID), 0.0)
      let source = ctx.storage.substring(sourceRange.rangeVal)
      ctx.painter.withClip(ctx.viewX, vy, ctx.containerWidth, totalHeight + 2.0):
        drawTable(ctx.painter, ctx.atlas, ctx.fonts, ctx.widths, ctx.config,
                  source, x - offsetX, vy, ctx.containerWidth, ctx.baseFont)
      if isWide:
        # The horizontal strip under a wide table, so it reads as scrollable.
        let stripY = vy + totalHeight + 2.0
        let visibleFraction = min(1.0, ctx.containerWidth / naturalWidth)
        let knobWidth = max(24.0, ctx.containerWidth * visibleFraction)
        let travel = max(1.0, naturalWidth - ctx.containerWidth)
        let knobX = ctx.viewX + (ctx.containerWidth - knobWidth) *
                    clamp(offsetX / travel, 0.0, 1.0)
        ctx.painter.fillRoundedRect(ctx.viewX, stripY, ctx.containerWidth, 4.0,
                                    2.0, withAlpha(ctx.theme.scrollerKnob, 0.12))
        ctx.painter.fillRoundedRect(knobX, stripY, knobWidth, 4.0, 2.0,
                                    ctx.theme.scrollerKnob)
      continue

    let (latex, hasLatex) = item.attributes.imageOf(akLatexImage)
    let (embed, hasEmbed) = item.attributes.imageOf(akImageEmbed)
    if not hasLatex and not hasEmbed: continue
    let handle = if hasLatex: latex else: embed
    let boundsKey = if hasLatex: akLatexBounds else: akImageBounds
    let (bounds, hasBounds) = item.attributes.imageOf(boundsKey)
    let width = if hasBounds and bounds.width > 0: bounds.width else: handle.width
    let height = if hasBounds and bounds.height > 0: bounds.height else: handle.height
    if width <= 0 or height <= 0: continue
    let isBlock = item.attributes.boolOf(akLatexIsBlock, false)
    let baselineY = vy + line.baseline
    let y = if isBlock: vy + max(0.0, (line.height - height) * 0.5)
            else: baselineY - (height - handle.baselineOffset)
    if not ctx.painter.drawImage(ctx.images, handle, x, y, width, height):
      # No texture behind the handle (a format with no decoder here, or a
      # provider that only reserved space): draw a labelled placeholder rather
      # than a hole, so the reader can see what is missing and fix the source.
      ctx.painter.fillRoundedRect(x, y, width, height, 4.0,
                                  withAlpha(ctx.theme.mutedText, 0.10))
      ctx.painter.strokeRect(x, y, width, height,
                             ctx.painter.resolve(withAlpha(ctx.theme.mutedText, 0.35)))
      let label = ctx.storage.substring(item.attributes.get(akTableRender).rangeVal)
      discard label

# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------

proc drawGlyphs(ctx: RenderContext, line: LineFragment) =
  let (_, vy) = ctx.toView(0.0, line.origin.y)
  let baselineY = ctx.painter.snap(vy + line.baseline)
  var previousCodePoint = -1
  for item in line.items:
    if item.codePoint == 0x0A or item.codePoint == 0x0D or item.isTab:
      previousCodePoint = -1
      continue
    # A run the styler collapsed to the hidden-marker font still has to be laid
    # out (that is the whole point of "markers shrink, they don't disappear"),
    # but at 0.1pt there is nothing to rasterize — skip the atlas round trip.
    if item.font.size < 1.0:
      previousCodePoint = item.codePoint
      continue
    let fg = item.attributes.colorOf(akForegroundColor, ctx.theme.bodyText)
    let resolved = ctx.painter.resolve(fg)
    if resolved.a <= 0.003:
      previousCodePoint = item.codePoint
      continue
    let entry = ctx.atlas.entryFor(item.font, item.codePoint)
    if entry.valid:
      ctx.atlas.drawGlyph(entry, line.textOriginX + item.x + ctx.viewX,
                          baselineY, resolved)
    previousCodePoint = item.codePoint

proc drawTextDecorations(ctx: RenderContext, line: LineFragment) =
  ## Underlines and strikethroughs, coalesced per run so a link's underline is
  ## one rectangle.
  let (_, vy) = ctx.toView(0.0, line.origin.y)
  let baselineY = vy + line.baseline

  proc sweep(ctx: RenderContext, styleKey, colorKey: AttrKey,
             defaultColor: Color, offsetOf: proc (m: FontMetrics): float) =
    var runLeft = 0.0
    var runRight = 0.0
    var runColor = clearColor
    var runOffset = 0.0
    var runThickness = 1.0
    var haveRealMetrics = false
    var active = false

    proc flush(ctx: RenderContext) =
      if not active: return
      ctx.painter.hLine(runLeft + ctx.viewX, baselineY + runOffset,
                        runRight - runLeft, ctx.painter.resolve(runColor),
                        runThickness)
      active = false

    for item in line.items:
      let style = item.attributes.get(styleKey)
      let underlined = (style.kind == avUnderline and style.underlineVal != ulNone) or
                       (style.kind == avInt and style.intVal != 0)
      if not underlined or item.codePoint == 0x0A or item.codePoint == 0x0D:
        ctx.flush()
        haveRealMetrics = false
        continue
      let c = item.attributes.colorOf(colorKey,
                item.attributes.colorOf(akForegroundColor, defaultColor))
      let left = line.textOriginX + item.x
      let right = left + item.advance
      if active and c == runColor and abs(left - runRight) < 0.51:
        runRight = right
      else:
        ctx.flush()
        active = true
        haveRealMetrics = false
        runColor = c
        runLeft = left
        runRight = right
        # Until a real font turns up, fall back to the line's own metrics.
        runOffset = offsetOf(ctx.fonts.metricsFor(ctx.baseFont))
        runThickness = 1.0
      # A collapsed marker run carries the 0.1pt hidden font, whose x-height is
      # effectively zero. Taking the offset from it put a checked task's strike
      # on the baseline instead of through the text, so the geometry comes from
      # the first run character with a real font.
      if not haveRealMetrics and item.font.size >= 1.0:
        let m = ctx.fonts.metricsFor(item.font)
        runOffset = offsetOf(m)
        runThickness = max(1.0, m.underlineThickness)
        haveRealMetrics = true
    ctx.flush()

  ctx.sweep(akUnderlineStyle, akUnderlineColor, ctx.theme.link,
            proc (m: FontMetrics): float = -m.underlinePosition)
  ctx.sweep(akStrikethroughStyle, akStrikethroughColor,
            ctx.theme.strikethroughColor,
            proc (m: FontMetrics): float = -m.xHeight * 0.5)

# ---------------------------------------------------------------------------
# Marker overlays
# ---------------------------------------------------------------------------

proc drawString(ctx: RenderContext, text: string, x, baselineY: float,
                desc: FontDesc, c: Rgba) =
  ## Draw a short string of our own (a bullet, a display number, a mark) with
  ## the same atlas the document text uses.
  var penX = x
  var previous = -1
  for rune in text.runes:
    let cp = int(rune)
    if previous >= 0:
      penX += ctx.fonts.kerningBetween(previous, cp, desc)
    let entry = ctx.atlas.entryFor(desc, cp)
    if entry.valid:
      ctx.atlas.drawGlyph(entry, penX, baselineY, c)
    penX += ctx.fonts.measureCodePoint(cp, desc)
    previous = cp

proc drawTaskCheckboxes(ctx: RenderContext, line: LineFragment) =
  ## A `akTaskCheckbox` range means the styler cleared the raw `- [ ]` and
  ## collapsed the box's advance, so the box must ALWAYS be drawn — including
  ## while the range sits inside a selection. Skipping it under a selection
  ## leaves an empty marker-width gap (the bullet-slot bug's twin). Unlike
  ## bullets, the raw source cannot be painted here instead: its advance is
  ## collapsed, so raw glyphs would overlap the content. Raw reveal stays
  ## caret-based, in the styler.
  let (_, vy) = ctx.toView(0.0, line.origin.y)
  let baselineY = vy + line.baseline
  # Draw once per RUN, not per character: the `[ ]` the attribute sits on is
  # three code units, so keying on the location alone painted the box three
  # times on top of itself.
  var previousHadBox = false
  for item in line.items:
    let hasBox = item.attributes.has(akTaskCheckbox)
    if not hasBox:
      previousHadBox = false
      continue
    if previousHadBox: continue
    previousHadBox = true
    let checked = item.attributes.boolOf(akTaskCheckbox, false)
    # The box collapsed to ~0pt, so the item's x sits at the content edge; the
    # square is right-aligned to it, sharing the geometry with the hit test.
    let contentX = line.textOriginX + item.x + ctx.viewX
    let m = ctx.fonts.metricsFor(ctx.baseFont)
    let size = taskCheckboxSize(ctx.fonts.textMetrics(), ctx.widths, ctx.baseFont)
    let boxX = ctx.painter.snap(taskCheckboxBoxX(contentX, size))
    let centerY = baselineY + (m.descent - m.ascent) * 0.5
    let boxY = ctx.painter.snap(centerY - size * 0.5)
    if checked:
      ctx.painter.fillRoundedRect(boxX, boxY, size, size, size * 0.22,
                                  ctx.theme.checkboxFill)
      ctx.painter.drawCheckGlyph(boxX, boxY, size,
                                 ctx.painter.resolve(ctx.theme.checkboxGlyph))
    else:
      ctx.painter.strokeRect(boxX, boxY, size, size,
                             ctx.painter.resolve(ctx.theme.checkboxBorder),
                             max(1.0, size * 0.08))

proc drawBulletMarkers(ctx: RenderContext, line: LineFragment) =
  ## Paint a `•` over every hidden bullet marker. A `akBulletMarker` range means
  ## the styler painted the raw char clear, so something must ALWAYS be drawn
  ## over the slot: outside a selection the rendered `•`, and INSIDE one the raw
  ## source char, so selecting a list line reveals its syntax. (The styler's own
  ## reveal is caret-based and doesn't fire for selections; skipping the draw
  ## under a selection left an empty slot.)
  let (_, vy) = ctx.toView(0.0, line.origin.y)
  let baselineY = ctx.painter.snap(vy + line.baseline)
  for item in line.items:
    if not item.attributes.boolOf(akBulletMarker, false): continue
    let selected = ctx.selection.length > 0 and
                   contains(ctx.selection, item.location)
    let raw = ctx.storage.substring(rng(item.location, item.length))
    let glyph = if selected: raw else: "•"
    let markerWidth = ctx.fonts.measureString(raw, item.font)
    let glyphWidth = ctx.fonts.measureString(glyph, item.font)
    let xOffset = max(0.0, (markerWidth - glyphWidth) * 0.5)
    ctx.drawString(glyph, line.textOriginX + item.x + ctx.viewX + xOffset,
                   baselineY, item.font, ctx.painter.resolve(ctx.theme.bodyText))

proc drawOrderedMarkers(ctx: RenderContext, line: LineFragment) =
  ## Paint the whole display marker "N." over the hidden source marker. A
  ## selection does NOT switch this back to the source digits: the number is
  ## positional, and swapping it under select-all made every item below an
  ## insertion read one lower than it renders.
  let (_, vy) = ctx.toView(0.0, line.origin.y)
  let baselineY = ctx.painter.snap(vy + line.baseline)
  # Once per RUN: the source marker is `1.`, two code units, both carrying the
  # attribute — keying on the location painted the number twice.
  var previousMarker = ""
  for item in line.items:
    if not item.attributes.has(akOrderedMarker):
      previousMarker = ""
      continue
    let text = item.attributes.stringOf(akOrderedMarker, "")
    if text.len == 0 or text == previousMarker: continue
    previousMarker = text
    # The BASE font, not the run's: the source marker carries the near-zero
    # hidden-marker font that keeps it invisible under a selection, and drawing
    # the number at 0.1pt would hide it too.
    ctx.drawString(text, line.textOriginX + item.x + ctx.viewX, baselineY,
                   ctx.baseFont, ctx.painter.resolve(ctx.theme.bodyText))

proc drawThematicBreak(ctx: RenderContext, line: LineFragment) =
  if line.items.len == 0: return
  if not line.items[0].attributes.boolOf(akThematicBreak, false): return
  let (_, vy) = ctx.toView(0.0, line.origin.y)
  let mark = line.items[0].attributes.stringOf(akThematicBreakMark, "")
  if mark.len == 0:
    let ruleColor = withAlpha(ctx.theme.thematicBreakRule, 0.55)
    ctx.painter.hLine(ctx.viewX, vy + line.height * 0.5, ctx.containerWidth,
                      ctx.painter.resolve(ruleColor), 1.0)
    return
  # Ink, not a hairline: the rule colour is deliberately faint and reads as a
  # smudge on glyphs, so a mark takes the muted text colour instead.
  let scale = max(0.01, line.items[0].attributes.floatOf(akThematicBreakMarkScale, 1.0))
  let markFont = ctx.baseFont.withSize(ctx.baseFont.size * scale)
  let m = ctx.fonts.metricsFor(markFont)
  let width = ctx.fonts.measureString(mark, markFont)
  let centerY = vy + line.height * 0.5
  # Centre on the INK, not the layout box: an asterisk is drawn high in its em,
  # so box-centring lets the mark drift toward the top of the line as the scale
  # grows. Using cap height as the ink proxy holds it on the optical centre at
  # any scale, in any font, with no per-font tuning.
  let baselineY = centerY + m.capHeight * 0.5
  ctx.drawString(mark, ctx.viewX + (ctx.containerWidth - width) * 0.5,
                 baselineY, markFont, ctx.painter.resolve(ctx.theme.mutedText))

proc drawBlockquoteBars(ctx: RenderContext, line: LineFragment) =
  ## Paint `level` vertical bars in the left gutter of every line carrying
  ## `akBlockquoteLevel`. Each line paints its own segment, so a run of quote
  ## lines reads as one continuous bar.
  if line.items.len == 0: return
  if not line.items[0].attributes.has(akBlockquoteLevel): return
  let level = line.items[0].attributes.intOf(akBlockquoteLevel, 0)
  if level <= 0: return
  let (_, vy) = ctx.toView(0.0, line.origin.y)
  let fill = ctx.painter.resolve(withAlpha(ctx.theme.mutedText, 0.5))
  for i in 0 ..< level:
    let barX = ctx.viewX + float(i) * blockquoteIndentPerLevel +
               blockquoteIndentPerLevel * 0.25
    ctx.painter.fillRect(ctx.painter.snap(barX), vy, blockquoteBarWidth,
                         line.height, fill)

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

proc drawDocument*(ctx: RenderContext) =
  ## Draw every visible line, in the order above.
  let top = ctx.scrollY
  let bottom = ctx.scrollY + ctx.viewportHeight

  # Selection and find highlights are drawn per line alongside the
  # backgrounds, so they sit under the text but over the block fills.
  let selectionFill = ctx.painter.resolve(
    if ctx.hasFocus: ctx.theme.selectionBackground
    else: withAlpha(ctx.theme.selectionBackground, 0.45))
  let matchFill = ctx.painter.resolve(
    withAlpha(ctx.theme.findMatchHighlight, ctx.config.markers.findMatchHighlightAlpha))
  let currentMatchFill = ctx.painter.resolve(ctx.theme.findCurrentMatchHighlight)

  var otherMatches: seq[Range] = @[]
  var focusedMatch: seq[Range] = @[]
  for i, r in ctx.findMatches:
    if i == ctx.currentMatch: focusedMatch.add r else: otherMatches.add r

  ctx.drawCodeBlockBackgrounds(top, bottom)

  for line in ctx.layout.visibleLines(top, bottom):
    ctx.drawBlockBackgrounds(line)
    ctx.drawGlyphBackgrounds(line)
    if otherMatches.len > 0: ctx.drawHighlightRects(line, otherMatches, matchFill)
    if focusedMatch.len > 0:
      ctx.drawHighlightRects(line, focusedMatch, currentMatchFill)
    if ctx.selection.length > 0:
      ctx.drawHighlightRects(line, @[ctx.selection], selectionFill)
    ctx.drawArtefacts(line)
    ctx.drawGlyphs(line)
    ctx.drawTextDecorations(line)
    ctx.drawTaskCheckboxes(line)
    ctx.drawBulletMarkers(line)
    ctx.drawOrderedMarkers(line)
    ctx.drawThematicBreak(line)
    ctx.drawBlockquoteBars(line)

  if ctx.hasFocus and ctx.caretVisible and ctx.selection.length == 0:
    let caret = ctx.layout.caretRect(ctx.selection.location)
    let (_, vy) = ctx.toView(0.0, caret.y)
    ctx.painter.fillRect(ctx.painter.snap(caret.x + ctx.viewX), vy,
                         max(1.0, caret.w * 0.5 + 0.5), caret.h,
                         ctx.theme.caret)
