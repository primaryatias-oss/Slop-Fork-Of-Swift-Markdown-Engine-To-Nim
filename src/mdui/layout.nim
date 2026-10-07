## layout.nim
## MarkdownEngine (Nim port) — UI layer
##
## The text layout engine: what replaces TextKit 2.
##
## The Swift engine leaned on `NSTextLayoutManager` for line breaking, line
## metrics, hit testing and caret geometry, and on a custom
## `NSTextLayoutFragment` for the decorations the styler tags. None of that
## exists here, so this module does the whole job:
##
## * paragraph-by-paragraph layout, because paragraph styles apply per
##   paragraph (indents, pinned line heights, spacing, tab stops)
## * line breaking by word or by character, honouring `lineBreakMode`
## * per-scalar advances with font kerning AND the styler's `akKern`, which is
##   what makes the "markers shrink, they don't disappear" mechanism work: a
##   hidden run is real text laid out at ~zero width
## * line metrics with the engine's clamping rule — extra height from a pinned
##   `minimumLineHeight` goes ABOVE the baseline, matching AppKit
## * hit testing, caret rects, and the range↔rect conversions the editor needs
##
## It is a VIEWPORT layout: `layout` walks the whole document to know the
## content height (the editor needs it for the scroller), but it caches per
## paragraph and only re-lays the paragraphs an edit touched.

import std/[math, tables]
import ../markdownengine/[ranges, utf16text, font, attributes]
import ./fontmanager, ./textstorage

type
  GlyphItem* = object
    ## One laid-out scalar (or artefact anchor), positioned in line-local
    ## coordinates.
    location*: int          ## UTF-16 offset in the document
    length*: int            ## 1, or 2 for a surrogate pair
    codePoint*: int
    x*: float               ## left edge, relative to the line's text origin
    advance*: float         ## total advance including kern
    font*: FontDesc
    attributes*: Attrs
    isTab*: bool

  LineFragment* = object
    ## One visual line. `range` covers the characters it lays out, INCLUDING a
    ## trailing line terminator when the line ends a paragraph.
    range*: Range
    origin*: tuple[x, y: float]   ## top-left of the line box, document coords
    width*: float                 ## used width of the text
    height*: float                ## line box height
    baseline*: float              ## distance from the line box top to baseline
    ascent*: float
    descent*: float
    textOriginX*: float           ## where glyph x = 0 sits, document coords
    paragraph*: ParagraphStyle
    isParagraphStart*: bool
    isParagraphEnd*: bool
    items*: seq[GlyphItem]

  ParagraphLayout = object
    range: Range
    lines: seq[LineFragment]
    height: float                 ## including spacing before/after
    spacingBefore: float
    spacingAfter: float

  TextLayout* = ref object
    storage*: TextStorage
    fonts*: FontManager
    containerWidth*: float
    containerInsetX*: float
      ## Left inset of the text container inside the view, so document
      ## coordinates already include it.
    baseFont*: FontDesc
    baseParagraph*: ParagraphStyle
    paragraphs: seq[ParagraphLayout]
    cache: Table[int, ParagraphLayout]
      ## paragraph start → layout, keyed so an untouched paragraph is reused
    cacheWidth: float
    contentHeight*: float
    lines*: seq[LineFragment]     ## flattened, in document order

proc newTextLayout*(storage: TextStorage, fonts: FontManager,
                    baseFont: FontDesc,
                    baseParagraph: ParagraphStyle): TextLayout =
  TextLayout(storage: storage, fonts: fonts, containerWidth: 0,
             containerInsetX: 0, baseFont: baseFont,
             baseParagraph: baseParagraph, paragraphs: @[],
             cache: initTable[int, ParagraphLayout](), cacheWidth: -1,
             contentHeight: 0, lines: @[])

proc invalidate*(layout: TextLayout) =
  ## Drop every cached paragraph — a font, theme or width change invalidates
  ## all of them.
  layout.cache.clear()
  layout.cacheWidth = -1

proc invalidateRange*(layout: TextLayout, r: Range) =
  ## Drop the paragraphs intersecting `r`, plus the one before and after: an
  ## edit at a paragraph boundary can merge or split neighbours.
  if layout.cache.len == 0: return
  var doomed: seq[int] = @[]
  for start, paragraph in layout.cache:
    if intersects(paragraph.range, r) or
       maxRange(paragraph.range) == r.location or
       paragraph.range.location == maxRange(r):
      doomed.add start
  for start in doomed: layout.cache.del(start)

# ---------------------------------------------------------------------------
# Line-level helpers
# ---------------------------------------------------------------------------

func isBreakOpportunity(codePoint: int): bool {.inline.} =
  ## Where a word-wrapped line may break AFTER this scalar. Spaces and tabs
  ## plus the usual CJK/punctuation opportunities — enough for prose and for
  ## the long URLs a markdown document is full of.
  codePoint == 0x20 or codePoint == 0x09 or codePoint == 0x2D or
  codePoint == 0x2F or codePoint == 0x5C or codePoint == 0x3F or
  codePoint == 0x26 or codePoint == 0x3D or
  codePoint == 0x200B or
  (codePoint >= 0x3000 and codePoint <= 0x9FFF) or
  (codePoint >= 0xFF00 and codePoint <= 0xFF60)

func isTrailingWhitespace(codePoint: int): bool {.inline.} =
  codePoint == 0x20 or codePoint == 0x09

proc effectiveWidth(layout: TextLayout, paragraph: ParagraphStyle,
                    isFirstLine: bool): tuple[indent, width: float] =
  ## The usable text width for a line, after the paragraph's indents.
  ## `tailIndent` is negative-from-the-right, as in AppKit.
  let ps = if paragraph != nil: paragraph else: layout.baseParagraph
  let head = if isFirstLine: ps.firstLineHeadIndent else: ps.headIndent
  var width = layout.containerWidth - head
  if ps.tailIndent < 0:
    width += ps.tailIndent
  elif ps.tailIndent > 0:
    width = ps.tailIndent - head
  (head, max(1.0, width))

proc lineMetrics(layout: TextLayout, items: seq[GlyphItem],
                 paragraph: ParagraphStyle): tuple[height, baseline, ascent,
                                                   descent: float] =
  ## Line box metrics, with the engine's clamping rule.
  ##
  ## Extra height from a pinned `minimumLineHeight` is added ABOVE the
  ## baseline, which is what AppKit does and what the styler assumes: the
  ## heading and list passes pin min == max and expect the text to sit on the
  ## bottom of that box, not floating in the middle of it.
  let ps = if paragraph != nil: paragraph else: layout.baseParagraph
  var ascent = 0.0
  var descent = 0.0
  var leading = 0.0
  var sawFont = false
  for item in items:
    let m = layout.fonts.metricsFor(item.font)
    ascent = max(ascent, m.ascent)
    descent = max(descent, m.descent)
    leading = max(leading, m.leading)
    sawFont = true
    # An artefact anchor reserves its own height above the baseline.
    let (handle, hasImage) = item.attributes.imageOf(akLatexImage)
    if hasImage:
      ascent = max(ascent, handle.height - handle.baselineOffset)
      descent = max(descent, handle.baselineOffset)
    let (embed, hasEmbed) = item.attributes.imageOf(akImageEmbed)
    if hasEmbed:
      ascent = max(ascent, embed.height - embed.baselineOffset)
      descent = max(descent, embed.baselineOffset)
  if not sawFont:
    let m = layout.fonts.metricsFor(layout.baseFont)
    ascent = m.ascent
    descent = m.descent
    leading = m.leading

  var height = ceil(ascent + descent + leading)
  if ps.minimumLineHeight > 0: height = max(height, ps.minimumLineHeight)
  if ps.maximumLineHeight > 0: height = min(height, ps.maximumLineHeight)
  height = max(1.0, height)
  let baseline = max(ascent, height - descent)
  (height, baseline, ascent, descent)

# ---------------------------------------------------------------------------
# Paragraph layout
# ---------------------------------------------------------------------------

proc buildItems(layout: TextLayout, paragraph: Range,
                paragraphStyle: var ParagraphStyle): seq[GlyphItem] =
  ## One item per scalar, with advances resolved. The paragraph style is taken
  ## from the FIRST run that carries one, mirroring AppKit: a paragraph style
  ## applies to the whole paragraph regardless of the sub-range it was set on.
  var style: ParagraphStyle = nil
  for run in layout.storage.runsIn(paragraph):
    let candidate = run.attributes.paragraphOf(nil)
    if candidate != nil and style == nil: style = candidate
    let runFont = run.attributes.fontOf(layout.baseFont)
    let kern = run.attributes.floatOf(akKern, 0.0)
    for (index, length, codePoint) in scalars(layout.storage.text, run.range):
      var item = GlyphItem(location: index, length: length, codePoint: codePoint,
                           font: runFont, attributes: run.attributes)
      if codePoint == 0x0A or codePoint == 0x0D:
        item.advance = 0.0
      elif codePoint == 0x09:
        item.isTab = true
        item.advance = 0.0        # resolved against the tab stops while placing
      else:
        item.advance = layout.fonts.measureCodePoint(codePoint, runFont) + kern
      result.add item
  paragraphStyle = if style != nil: style else: layout.baseParagraph

proc layoutParagraph(layout: TextLayout, paragraph: Range,
                     originY: float): ParagraphLayout =
  var paragraphStyle: ParagraphStyle = nil
  let items = layout.buildItems(paragraph, paragraphStyle)
  let ps = paragraphStyle
  result.range = paragraph
  result.spacingBefore = ps.paragraphSpacingBefore
  result.spacingAfter = ps.paragraphSpacing

  var y = originY + ps.paragraphSpacingBefore
  var index = 0
  var isFirstLine = true

  if items.len == 0:
    # An empty paragraph still occupies a line, so the caret has somewhere to
    # sit and the following text does not slide up.
    let (indent, _) = layout.effectiveWidth(ps, true)
    let (height, baseline, ascent, descent) =
      layout.lineMetrics(@[], ps)
    result.lines.add LineFragment(
      range: paragraph, origin: (layout.containerInsetX + indent, y),
      width: 0, height: height, baseline: baseline, ascent: ascent,
      descent: descent, textOriginX: layout.containerInsetX + indent,
      paragraph: ps, isParagraphStart: true, isParagraphEnd: true, items: @[])
    result.height = height + ps.paragraphSpacingBefore + ps.paragraphSpacing
    return result

  while index < items.len:
    let (indent, available) = layout.effectiveWidth(ps, isFirstLine)
    var penX = 0.0
    var lastBreak = -1              # item index AFTER which we may break
    var lastBreakX = 0.0
    var lineEnd = index
    var hardBreak = false
    var previousCodePoint = -1
    var lineItems: seq[GlyphItem] = @[]

    while lineEnd < items.len:
      var item = items[lineEnd]
      if item.codePoint == 0x0A or item.codePoint == 0x0D:
        # Consume the terminator (and a CRLF pair) and end the line.
        item.x = penX
        lineItems.add item
        inc lineEnd
        if item.codePoint == 0x0D and lineEnd < items.len and
           items[lineEnd].codePoint == 0x0A:
          var lf = items[lineEnd]
          lf.x = penX
          lineItems.add lf
          inc lineEnd
        hardBreak = true
        break

      # Font kerning between adjacent scalars of the same run's font.
      if previousCodePoint >= 0:
        penX += layout.fonts.kerningBetween(previousCodePoint, item.codePoint,
                                            item.font)
      if item.isTab:
        let stop = nextTabStop(ps, penX)
        item.advance = max(1.0, stop - penX)

      let fits = penX + item.advance <= available + 0.01
      if not fits and lineItems.len > 0:
        break
      item.x = penX
      lineItems.add item
      penX += item.advance
      previousCodePoint = item.codePoint
      inc lineEnd
      if isBreakOpportunity(item.codePoint):
        lastBreak = lineEnd
        lastBreakX = penX

    if not hardBreak and lineEnd < items.len:
      # Word wrap: retreat to the last break opportunity when there was one
      # and the paragraph asks for word wrapping.
      if ps.lineBreakMode == lbWordWrapping and lastBreak > index and
         lastBreak < lineEnd:
        lineEnd = lastBreak
        penX = lastBreakX
        while lineItems.len > 0 and lineItems[^1].location >= items[lineEnd].location:
          lineItems.setLen(lineItems.len - 1)
      elif ps.lineBreakMode == lbClipping:
        # Clipping keeps the whole run on one line; the renderer clips it.
        while lineEnd < items.len and
              items[lineEnd].codePoint != 0x0A and items[lineEnd].codePoint != 0x0D:
          var item = items[lineEnd]
          item.x = penX
          lineItems.add item
          penX += item.advance
          inc lineEnd

    if lineItems.len == 0:
      # Nothing fit at all (a single glyph wider than the column): force one
      # item so layout always advances.
      var item = items[index]
      item.x = 0
      lineItems.add item
      penX = item.advance
      lineEnd = index + 1

    # Trailing whitespace does not count toward the used width.
    var usedWidth = penX
    var k = lineItems.len - 1
    while k >= 0 and (isTrailingWhitespace(lineItems[k].codePoint) or
                      lineItems[k].codePoint == 0x0A or
                      lineItems[k].codePoint == 0x0D):
      usedWidth = lineItems[k].x
      dec k

    let (height, baseline, ascent, descent) = layout.lineMetrics(lineItems, ps)
    let textOriginX = layout.containerInsetX + indent
    var lineRange = rng(items[index].location,
                        (if lineEnd < items.len: items[lineEnd].location
                         else: maxRange(paragraph)) - items[index].location)
    if lineRange.length < 0: lineRange.length = 0

    result.lines.add LineFragment(
      range: lineRange, origin: (textOriginX, y), width: max(0.0, usedWidth),
      height: height, baseline: baseline, ascent: ascent, descent: descent,
      textOriginX: textOriginX, paragraph: ps,
      isParagraphStart: isFirstLine,
      isParagraphEnd: lineEnd >= items.len,
      items: lineItems)

    y += height
    if lineEnd < items.len: y += ps.lineSpacing
    index = lineEnd
    isFirstLine = false

  y += ps.paragraphSpacing
  result.height = y - originY

# ---------------------------------------------------------------------------
# Document layout
# ---------------------------------------------------------------------------

proc layout*(layout: TextLayout, containerWidth: float, insetX = 0.0) =
  ## Lay the whole document out at `containerWidth`, reusing cached paragraphs
  ## whose text has not moved.
  if containerWidth != layout.cacheWidth or insetX != layout.containerInsetX:
    layout.cache.clear()
  layout.containerWidth = max(1.0, containerWidth)
  layout.containerInsetX = insetX
  layout.cacheWidth = containerWidth

  layout.paragraphs = @[]
  layout.lines = @[]
  var y = 0.0
  var cursor = 0
  let length = layout.storage.len

  if length == 0:
    # An empty document still shows one body line of height, so the caret is
    # visible and the view does not collapse.
    var paragraphLayout = ParagraphLayout(range: rng(0, 0))
    let m = layout.fonts.metricsFor(layout.baseFont)
    var height = ceil(m.ascent + m.descent + m.leading)
    if layout.baseParagraph.minimumLineHeight > 0:
      height = max(height, layout.baseParagraph.minimumLineHeight)
    paragraphLayout.lines.add LineFragment(
      range: rng(0, 0), origin: (insetX, 0.0), width: 0, height: height,
      baseline: max(m.ascent, height - m.descent), ascent: m.ascent,
      descent: m.descent, textOriginX: insetX,
      paragraph: layout.baseParagraph, isParagraphStart: true,
      isParagraphEnd: true, items: @[])
    paragraphLayout.height = height
    layout.paragraphs.add paragraphLayout
    layout.lines.add paragraphLayout.lines[0]
    layout.contentHeight = height
    return

  while cursor < length:
    let paragraph = layout.storage.text.paragraphRange(caretAt(cursor))
    if paragraph.length <= 0: break
    var paragraphLayout: ParagraphLayout
    var reused = false
    layout.cache.withValue(paragraph.location, hit):
      if hit[].range == paragraph:
        paragraphLayout = hit[]
        reused = true
    if reused:
      # Shift the cached lines to the paragraph's new vertical origin.
      let previousY = if paragraphLayout.lines.len > 0:
                        paragraphLayout.lines[0].origin.y -
                          paragraphLayout.spacingBefore
                      else: 0.0
      let shift = y - previousY
      if shift != 0:
        for i in 0 ..< paragraphLayout.lines.len:
          paragraphLayout.lines[i].origin.y += shift
    else:
      paragraphLayout = layout.layoutParagraph(paragraph, y)
      layout.cache[paragraph.location] = paragraphLayout
    layout.paragraphs.add paragraphLayout
    for line in paragraphLayout.lines: layout.lines.add line
    y += paragraphLayout.height
    cursor = maxRange(paragraph)

  # A document whose last character is a newline has one more (empty) line
  # after it, exactly as a text view shows.
  if length > 0 and isLineBreakUnit(layout.storage.text.charAt(length - 1)):
    let m = layout.fonts.metricsFor(layout.baseFont)
    var height = ceil(m.ascent + m.descent + m.leading)
    if layout.baseParagraph.minimumLineHeight > 0:
      height = max(height, layout.baseParagraph.minimumLineHeight)
    let trailing = LineFragment(
      range: rng(length, 0), origin: (insetX, y), width: 0, height: height,
      baseline: max(m.ascent, height - m.descent), ascent: m.ascent,
      descent: m.descent, textOriginX: insetX,
      paragraph: layout.baseParagraph, isParagraphStart: true,
      isParagraphEnd: true, items: @[])
    layout.lines.add trailing
    y += height

  layout.contentHeight = y

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

proc lineIndexForLocation*(layout: TextLayout, location: int): int =
  ## The line that owns `location`. A caret at a soft-wrap boundary belongs to
  ## the SECOND line, which is where a text view puts it.
  if layout.lines.len == 0: return -1
  var lo = 0
  var hi = layout.lines.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if layout.lines[mid].range.location <= location: lo = mid else: hi = mid - 1
  # Walk forward over zero-length lines so the caret lands on a real one.
  while lo + 1 < layout.lines.len and
        layout.lines[lo + 1].range.location <= location:
    inc lo
  lo

proc lineIndexForY*(layout: TextLayout, y: float): int =
  if layout.lines.len == 0: return -1
  if y < layout.lines[0].origin.y: return 0
  var lo = 0
  var hi = layout.lines.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if layout.lines[mid].origin.y <= y: lo = mid else: hi = mid - 1
  lo

proc itemIndexForX*(line: LineFragment, x: float): int =
  ## Index of the item whose box contains `x`, or -1 past the end.
  for i, item in line.items:
    if x < item.x + item.advance: return i
  -1

proc locationAtPoint*(layout: TextLayout, x, y: float): int =
  ## Character offset nearest the point, rounding to the closer edge of the
  ## glyph — what a click expects.
  if layout.lines.len == 0: return 0
  let lineIndex = layout.lineIndexForY(y)
  if lineIndex < 0: return 0
  let line = layout.lines[lineIndex]
  let localX = x - line.textOriginX
  if line.items.len == 0: return line.range.location
  if localX <= line.items[0].x: return line.range.location
  for item in line.items:
    if item.codePoint == 0x0A or item.codePoint == 0x0D:
      return item.location
    if localX < item.x + item.advance:
      let midpoint = item.x + item.advance * 0.5
      return if localX < midpoint: item.location
             else: item.location + item.length
  let last = line.items[^1]
  if last.codePoint == 0x0A or last.codePoint == 0x0D: last.location
  else: last.location + last.length

proc caretRect*(layout: TextLayout, location: int): tuple[x, y, w, h: float] =
  ## Caret rectangle in document coordinates.
  if layout.lines.len == 0:
    return (layout.containerInsetX, 0.0, 1.0, 16.0)
  let lineIndex = layout.lineIndexForLocation(location)
  let line = layout.lines[max(0, lineIndex)]
  var x = line.textOriginX
  for item in line.items:
    if item.location == location:
      x = line.textOriginX + item.x
      break
    if location > item.location and location < item.location + item.length:
      x = line.textOriginX + item.x
      break
    if location >= item.location + item.length:
      if item.codePoint == 0x0A or item.codePoint == 0x0D:
        x = line.textOriginX + item.x
      else:
        x = line.textOriginX + item.x + item.advance
  (x, line.origin.y, 2.0, line.height)

proc rectsForRange*(layout: TextLayout, r: Range): seq[tuple[x, y, w, h: float]] =
  ## One rectangle per visual line the range covers — what selection and find
  ## highlighting draw.
  if r.length <= 0 or layout.lines.len == 0: return @[]
  for line in layout.lines:
    if maxRange(line.range) <= r.location: continue
    if line.range.location >= maxRange(r): break
    var lo = high(float)
    var hi = low(float)
    var sawItem = false
    for item in line.items:
      if item.location + item.length <= r.location: continue
      if item.location >= maxRange(r): break
      lo = min(lo, line.textOriginX + item.x)
      # A trailing newline inside the selection shows as a thin tail, so a
      # multi-line selection reads as continuous.
      let advance = if item.codePoint == 0x0A or item.codePoint == 0x0D:
                      max(4.0, item.advance)
                    else: item.advance
      hi = max(hi, line.textOriginX + item.x + advance)
      sawItem = true
    if not sawItem:
      # The range covers this line's (empty) extent — e.g. a blank line in the
      # middle of a selection.
      if line.range.location >= r.location and
         maxRange(line.range) <= maxRange(r):
        result.add (line.textOriginX, line.origin.y, 4.0, line.height)
      continue
    result.add (lo, line.origin.y, max(0.0, hi - lo), line.height)

proc boundingRectForRange*(layout: TextLayout,
                           r: Range): tuple[x, y, w, h: float] =
  let rects = layout.rectsForRange(r)
  if rects.len == 0:
    let caret = layout.caretRect(r.location)
    return caret
  var lo = rects[0].x
  var hi = rects[0].x + rects[0].w
  var top = rects[0].y
  var bottom = rects[0].y + rects[0].h
  for rect in rects:
    lo = min(lo, rect.x)
    hi = max(hi, rect.x + rect.w)
    top = min(top, rect.y)
    bottom = max(bottom, rect.y + rect.h)
  (lo, top, hi - lo, bottom - top)

proc usedWidth*(layout: TextLayout): float =
  for line in layout.lines:
    result = max(result, line.textOriginX + line.width)

# ---------------------------------------------------------------------------
# Caret movement
# ---------------------------------------------------------------------------

proc nextLocation*(layout: TextLayout, location: int): int =
  ## One scalar forward, never splitting a surrogate pair.
  let length = layout.storage.len
  if location >= length: return length
  let unit = int(layout.storage.text.charAt(location))
  if unit >= 0xD800 and unit <= 0xDBFF and location + 1 < length:
    let low = int(layout.storage.text.charAt(location + 1))
    if low >= 0xDC00 and low <= 0xDFFF: return location + 2
  # Treat CRLF as one position.
  if unit == 0x0D and location + 1 < length and
     layout.storage.text.charAt(location + 1) == chLF:
    return location + 2
  location + 1

proc previousLocation*(layout: TextLayout, location: int): int =
  if location <= 0: return 0
  let unit = int(layout.storage.text.charAt(location - 1))
  if unit >= 0xDC00 and unit <= 0xDFFF and location >= 2:
    let high = int(layout.storage.text.charAt(location - 2))
    if high >= 0xD800 and high <= 0xDBFF: return location - 2
  if unit == 0x0A and location >= 2 and
     layout.storage.text.charAt(location - 2) == chCR:
    return location - 2
  location - 1

proc locationMovingVertically*(layout: TextLayout, location: int, delta: int,
                               desiredX: float): int =
  ## Up/down arrow: keep the desired x, land on the nearest offset of the
  ## target line.
  if layout.lines.len == 0: return 0
  let lineIndex = layout.lineIndexForLocation(location)
  let target = lineIndex + delta
  if target < 0: return 0
  if target >= layout.lines.len: return layout.storage.len
  let line = layout.lines[target]
  layout.locationAtPoint(desiredX, line.origin.y + line.height * 0.5)

proc lineStartLocation*(layout: TextLayout, location: int): int =
  let index = layout.lineIndexForLocation(location)
  if index < 0: 0 else: layout.lines[index].range.location

proc lineEndLocation*(layout: TextLayout, location: int): int =
  ## End of the visual line, BEFORE its terminator — where Home/End land.
  let index = layout.lineIndexForLocation(location)
  if index < 0: return layout.storage.len
  let line = layout.lines[index]
  var stop = maxRange(line.range)
  while stop > line.range.location and
        isLineBreakUnit(layout.storage.text.charAt(stop - 1)):
    dec stop
  stop

proc wordRangeAt*(layout: TextLayout, location: int): Range =
  ## The word under `location` — double-click selection.
  let t = layout.storage.text
  let length = t.len
  if length == 0: return rng(0, 0)
  let probe = clamp(location, 0, length - 1)

  proc isWordUnit(c: uint16): bool =
    isAlphanumericUnit(c) or c == chUnderscore

  if not isWordUnit(t.charAt(probe)):
    # A click on punctuation or whitespace selects that run instead, so a
    # double-click always selects something.
    let target = t.charAt(probe)
    let wantWhitespace = isWhitespaceUnit(target)
    var lo = probe
    var hi = probe + 1
    while lo > 0 and not isWordUnit(t.charAt(lo - 1)) and
          isWhitespaceUnit(t.charAt(lo - 1)) == wantWhitespace and
          not isLineBreakUnit(t.charAt(lo - 1)): dec lo
    while hi < length and not isWordUnit(t.charAt(hi)) and
          isWhitespaceUnit(t.charAt(hi)) == wantWhitespace and
          not isLineBreakUnit(t.charAt(hi)): inc hi
    return rng(lo, hi - lo)

  var lo = probe
  var hi = probe
  while lo > 0 and isWordUnit(t.charAt(lo - 1)): dec lo
  while hi < length and isWordUnit(t.charAt(hi)): inc hi
  rng(lo, hi - lo)

proc wordBoundaryForward*(layout: TextLayout, location: int): int =
  ## Option-Right: skip the current run of non-word characters, then the word.
  let t = layout.storage.text
  let length = t.len
  var i = location
  while i < length and not (isAlphanumericUnit(t.charAt(i)) or
                            t.charAt(i) == chUnderscore): inc i
  while i < length and (isAlphanumericUnit(t.charAt(i)) or
                        t.charAt(i) == chUnderscore): inc i
  i

proc wordBoundaryBackward*(layout: TextLayout, location: int): int =
  let t = layout.storage.text
  var i = location
  while i > 0 and not (isAlphanumericUnit(t.charAt(i - 1)) or
                       t.charAt(i - 1) == chUnderscore): dec i
  while i > 0 and (isAlphanumericUnit(t.charAt(i - 1)) or
                   t.charAt(i - 1) == chUnderscore): dec i
  i

# ---------------------------------------------------------------------------
# Visible-range culling
# ---------------------------------------------------------------------------

iterator visibleLines*(layout: TextLayout, top, bottom: float): LineFragment =
  ## The lines intersecting `[top, bottom)` — what the renderer draws. Binary
  ## search plus a forward walk, so a long document costs the same per frame as
  ## a short one.
  if layout.lines.len > 0:
    var index = layout.lineIndexForY(top)
    if index < 0: index = 0
    while index > 0 and
          layout.lines[index].origin.y + layout.lines[index].height > top:
      dec index
    while index < layout.lines.len:
      let line = layout.lines[index]
      if line.origin.y >= bottom: break
      if line.origin.y + line.height > top: yield line
      inc index

proc visibleRange*(layout: TextLayout, top, bottom: float): Range =
  ## The character range the viewport shows, for scoping work to it.
  var lo = -1
  var hi = -1
  for line in layout.visibleLines(top, bottom):
    if lo < 0: lo = line.range.location
    hi = maxRange(line.range)
  if lo < 0: rng(0, 0) else: rng(lo, hi - lo)
