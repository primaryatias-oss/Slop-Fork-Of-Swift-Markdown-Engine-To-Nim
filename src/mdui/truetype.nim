## truetype.nim
## MarkdownEngine (Nim port) — UI layer
##
## A TrueType parser and glyph rasterizer written against the Nim standard
## library only.
##
## This is what replaces CoreText. The Swift engine asked `NSFont` for metrics
## and `NSAttributedString` for measurement and drawing; on Linux, with SDL3
## for the window and nothing else allowed, there is no text engine in the
## picture at all — so the font work is done here: parse the `sfnt` container,
## read the metric and character-mapping tables, build glyph outlines from
## `glyf`, and rasterize them to 8-bit coverage.
##
## Scope is deliberate. It handles what a Markdown editor needs from a modern
## TrueType font:
##
## * tables `head`, `hhea`, `maxp`, `hmtx`, `cmap` (formats 4, 6, 12), `loca`,
##   `glyf`, `OS/2`, `kern` (format 0)
## * simple and composite glyphs, including component scaling
## * quadratic outlines, flattened adaptively and filled with analytic
##   anti-aliasing (the signed-area accumulation method: one pass over the
##   edges, then a prefix sum per row)
## * synthetic bold and synthetic oblique, for families that ship no such face
##
## It does NOT handle CFF/OpenType outlines (`.otf`), `GPOS` kerning, or
## shaping. A `.otf` is rejected at load so the font manager can fall back to a
## TrueType family rather than drawing nothing.

import std/[math, streams, tables]

type
  TtfError* = object of CatchableError

  GlyphMetrics* = object
    advance*: float      ## horizontal advance, in font units
    leftSideBearing*: float
    xMin*, yMin*, xMax*, yMax*: float

  FontMetricsRaw* = object
    ## Vertical metrics in FONT UNITS; the caller scales by `size / unitsPerEm`.
    unitsPerEm*: float
    ascender*: float
    descender*: float    ## negative, as stored
    lineGap*: float
    capHeight*: float
    xHeight*: float
    underlinePosition*: float
    underlineThickness*: float

  Point = object
    x, y: float

  Contour = object
    points: seq[Point]

  Outline* = object
    ## A glyph's contours in font units, already flattened to line segments.
    contours*: seq[Contour]
    xMin*, yMin*, xMax*, yMax*: float

  TrueTypeFont* = ref object
    data: string
    tables: Table[string, tuple[offset, length: int]]
    numGlyphs*: int
    indexToLocFormat: int
    locaOffset, locaLength: int
    glyfOffset, glyfLength: int
    hmtxOffset: int
    numberOfHMetrics: int
    cmapTable: Table[int, int]     ## code point → glyph index (lazily filled)
    cmapSubtableOffset: int
    cmapFormat: int
    kernPairs: Table[uint32, float]
    metrics*: FontMetricsRaw
    familyName*: string
    path*: string

# ---------------------------------------------------------------------------
# Big-endian readers
# ---------------------------------------------------------------------------

template checkBounds(data: string, offset, count: int) =
  if offset < 0 or offset + count > data.len:
    raise newException(TtfError, "read past end of font data")

func readU8(data: string, offset: int): int {.inline.} =
  checkBounds(data, offset, 1)
  int(uint8(data[offset]))

func readI8(data: string, offset: int): int {.inline.} =
  checkBounds(data, offset, 1)
  cast[int8](uint8(data[offset])).int

func readU16(data: string, offset: int): int {.inline.} =
  checkBounds(data, offset, 2)
  (int(uint8(data[offset])) shl 8) or int(uint8(data[offset + 1]))

func readI16(data: string, offset: int): int {.inline.} =
  let v = readU16(data, offset)
  if v >= 0x8000: v - 0x10000 else: v

func readU32(data: string, offset: int): int {.inline.} =
  checkBounds(data, offset, 4)
  (int(uint8(data[offset])) shl 24) or (int(uint8(data[offset + 1])) shl 16) or
  (int(uint8(data[offset + 2])) shl 8) or int(uint8(data[offset + 3]))

func readTag(data: string, offset: int): string {.inline.} =
  checkBounds(data, offset, 4)
  data[offset ..< offset + 4]

func readF2Dot14(data: string, offset: int): float {.inline.} =
  float(readI16(data, offset)) / 16384.0

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

proc parseKernTable(font: TrueTypeFont) =
  ## `kern` format 0 only — a sorted list of (left, right) → value pairs. It is
  ## what DejaVu, Liberation and most other TrueType families ship, and it is
  ## all the engine asks for: no shaping, no contextual positioning.
  if not font.tables.hasKey("kern"): return
  let base = font.tables["kern"].offset
  let data = font.data
  try:
    let nTables = readU16(data, base + 2)
    var offset = base + 4
    for _ in 0 ..< nTables:
      let subtableLength = readU16(data, offset + 2)
      let coverage = readU16(data, offset + 4)
      let format = coverage shr 8
      if format == 0:
        let nPairs = readU16(data, offset + 6)
        var p = offset + 14
        for _ in 0 ..< nPairs:
          let left = readU16(data, p)
          let right = readU16(data, p + 2)
          let value = float(readI16(data, p + 4))
          if value != 0:
            font.kernPairs[(uint32(left) shl 16) or uint32(right)] = value
          p += 6
      if subtableLength <= 0: break
      offset += subtableLength
  except TtfError, IndexDefect:
    font.kernPairs.clear()

proc selectCmapSubtable(font: TrueTypeFont) =
  ## Prefer a Unicode subtable: (3,10) full repertoire, then (3,1) BMP, then
  ## (0,*), then (3,0) symbol, then (1,0) Mac Roman as a last resort.
  if not font.tables.hasKey("cmap"): return
  let base = font.tables["cmap"].offset
  let data = font.data
  let numTables = readU16(data, base + 2)
  var best = -1
  var bestScore = -1
  for i in 0 ..< numTables:
    let rec = base + 4 + i * 8
    let platformID = readU16(data, rec)
    let encodingID = readU16(data, rec + 2)
    let offset = readU32(data, rec + 4)
    let score =
      if platformID == 3 and encodingID == 10: 100
      elif platformID == 3 and encodingID == 1: 90
      elif platformID == 0: 80
      elif platformID == 3 and encodingID == 0: 50
      elif platformID == 1 and encodingID == 0: 10
      else: 1
    if score > bestScore:
      bestScore = score
      best = base + offset
  if best < 0: return
  font.cmapSubtableOffset = best
  font.cmapFormat = readU16(data, best)

proc readName(font: TrueTypeFont): string =
  ## Family name (name id 1) from the `name` table, preferring a Unicode
  ## record. Used only for diagnostics and family matching.
  if not font.tables.hasKey("name"): return ""
  let base = font.tables["name"].offset
  let data = font.data
  try:
    let count = readU16(data, base + 2)
    let stringOffset = base + readU16(data, base + 4)
    for i in 0 ..< count:
      let rec = base + 6 + i * 12
      let platformID = readU16(data, rec)
      let nameID = readU16(data, rec + 6)
      if nameID != 1: continue
      let length = readU16(data, rec + 8)
      let offset = readU16(data, rec + 10)
      if platformID == 3 or platformID == 0:
        # UTF-16BE
        var s = ""
        var k = 0
        while k + 1 < length:
          let unit = readU16(data, stringOffset + offset + k)
          if unit < 128: s.add char(unit)
          k += 2
        if s.len > 0: return s
      elif platformID == 1:
        return data[stringOffset + offset ..< stringOffset + offset + length]
  except TtfError, IndexDefect:
    discard
  ""

proc loadTrueTypeFromData*(data: string, path = ""): TrueTypeFont =
  ## Parse an `sfnt` container. Raises `TtfError` for anything this rasterizer
  ## cannot draw, so the font manager can fall back to another family.
  if data.len < 12:
    raise newException(TtfError, "font data too short")
  var offset = 0
  let firstTag = readTag(data, 0)
  if firstTag == "ttcf":
    # TrueType collection: take the first face.
    offset = readU32(data, 12)
  let version = readTag(data, offset)
  if version == "OTTO":
    raise newException(TtfError,
      "CFF/OpenType outlines are not supported by this rasterizer")
  if version != "\0\1\0\0" and version != "true" and version != "ttcf":
    raise newException(TtfError, "not a TrueType font")

  let font = TrueTypeFont(data: data, tables: initTable[string, tuple[offset, length: int]](),
                          cmapTable: initTable[int, int](),
                          kernPairs: initTable[uint32, float](),
                          cmapSubtableOffset: -1, path: path)
  let numTables = readU16(data, offset + 4)
  for i in 0 ..< numTables:
    let rec = offset + 12 + i * 16
    let tag = readTag(data, rec)
    font.tables[tag] = (readU32(data, rec + 8), readU32(data, rec + 12))

  for required in ["head", "hhea", "maxp", "hmtx", "cmap"]:
    if not font.tables.hasKey(required):
      raise newException(TtfError, "font is missing the '" & required & "' table")
  if not font.tables.hasKey("glyf") or not font.tables.hasKey("loca"):
    raise newException(TtfError, "font has no 'glyf' outlines")

  let head = font.tables["head"].offset
  let unitsPerEm = readU16(data, head + 18)
  if unitsPerEm == 0:
    raise newException(TtfError, "unitsPerEm is zero")
  font.indexToLocFormat = readI16(data, head + 50)

  let hhea = font.tables["hhea"].offset
  font.numberOfHMetrics = readU16(data, hhea + 34)
  font.numGlyphs = readU16(data, font.tables["maxp"].offset + 4)
  font.hmtxOffset = font.tables["hmtx"].offset
  font.locaOffset = font.tables["loca"].offset
  font.locaLength = font.tables["loca"].length
  font.glyfOffset = font.tables["glyf"].offset
  font.glyfLength = font.tables["glyf"].length

  var metrics = FontMetricsRaw(
    unitsPerEm: float(unitsPerEm),
    ascender: float(readI16(data, hhea + 4)),
    descender: float(readI16(data, hhea + 6)),
    lineGap: float(readI16(data, hhea + 8)),
    capHeight: 0, xHeight: 0,
    underlinePosition: -float(unitsPerEm) * 0.1,
    underlineThickness: max(1.0, float(unitsPerEm) * 0.05))

  if font.tables.hasKey("OS/2"):
    let os2 = font.tables["OS/2"].offset
    let os2Version = readU16(data, os2)
    # The typographic ascender/descender are the ones that match the design's
    # intent; `hhea` often carries larger, clipping-safe values.
    let typoAscender = float(readI16(data, os2 + 68))
    let typoDescender = float(readI16(data, os2 + 70))
    if typoAscender > 0:
      metrics.ascender = typoAscender
      metrics.descender = typoDescender
      metrics.lineGap = float(readI16(data, os2 + 72))
    if os2Version >= 2 and font.tables["OS/2"].length >= 96:
      metrics.xHeight = float(readI16(data, os2 + 86))
      metrics.capHeight = float(readI16(data, os2 + 88))
  if font.tables.hasKey("post"):
    let post = font.tables["post"].offset
    metrics.underlinePosition = float(readI16(data, post + 8))
    metrics.underlineThickness = max(1.0, float(readI16(data, post + 10)))
  if metrics.capHeight <= 0: metrics.capHeight = metrics.ascender * 0.72
  if metrics.xHeight <= 0: metrics.xHeight = metrics.ascender * 0.52
  font.metrics = metrics

  font.selectCmapSubtable()
  font.parseKernTable()
  font.familyName = font.readName()
  font

proc loadTrueTypeFile*(path: string): TrueTypeFont =
  var stream = newFileStream(path, fmRead)
  if stream == nil:
    raise newException(TtfError, "cannot open font file: " & path)
  defer: stream.close()
  loadTrueTypeFromData(stream.readAll(), path)

# ---------------------------------------------------------------------------
# Character mapping
# ---------------------------------------------------------------------------

proc lookupCmapFormat4(font: TrueTypeFont, codePoint: int): int =
  let data = font.data
  let base = font.cmapSubtableOffset
  let segCountX2 = readU16(data, base + 6)
  let segCount = segCountX2 div 2
  let endCodes = base + 14
  let startCodes = endCodes + segCountX2 + 2
  let idDeltas = startCodes + segCountX2
  let idRangeOffsets = idDeltas + segCountX2

  # Binary search for the first segment whose end code is >= codePoint.
  var lo = 0
  var hi = segCount
  while lo < hi:
    let mid = (lo + hi) div 2
    if readU16(data, endCodes + mid * 2) >= codePoint: hi = mid else: lo = mid + 1
  if lo >= segCount: return 0
  let startCode = readU16(data, startCodes + lo * 2)
  if codePoint < startCode: return 0
  let idRangeOffset = readU16(data, idRangeOffsets + lo * 2)
  if idRangeOffset == 0:
    let delta = readU16(data, idDeltas + lo * 2)
    return (codePoint + delta) and 0xFFFF
  let glyphAddress = idRangeOffsets + lo * 2 + idRangeOffset +
                     (codePoint - startCode) * 2
  let glyph = readU16(data, glyphAddress)
  if glyph == 0: return 0
  let delta = readU16(data, idDeltas + lo * 2)
  (glyph + delta) and 0xFFFF

proc lookupCmapFormat12(font: TrueTypeFont, codePoint: int): int =
  let data = font.data
  let base = font.cmapSubtableOffset
  let nGroups = readU32(data, base + 12)
  var lo = 0
  var hi = nGroups
  while lo < hi:
    let mid = (lo + hi) div 2
    let group = base + 16 + mid * 12
    if codePoint < readU32(data, group): hi = mid
    elif codePoint > readU32(data, group + 4): lo = mid + 1
    else: return readU32(data, group + 8) + (codePoint - readU32(data, group))
  0

proc lookupCmapFormat6(font: TrueTypeFont, codePoint: int): int =
  let data = font.data
  let base = font.cmapSubtableOffset
  let first = readU16(data, base + 6)
  let count = readU16(data, base + 8)
  if codePoint < first or codePoint >= first + count: return 0
  readU16(data, base + 10 + (codePoint - first) * 2)

proc lookupCmapFormat0(font: TrueTypeFont, codePoint: int): int =
  if codePoint < 0 or codePoint > 255: return 0
  readU8(font.data, font.cmapSubtableOffset + 6 + codePoint)

proc glyphIndex*(font: TrueTypeFont, codePoint: int): int =
  ## Glyph index for a Unicode scalar; 0 (the `.notdef` box) when unmapped.
  if font.cmapSubtableOffset < 0: return 0
  font.cmapTable.withValue(codePoint, hit):
    return hit[]
  var glyph = 0
  try:
    case font.cmapFormat
    of 0: glyph = font.lookupCmapFormat0(codePoint)
    of 4: glyph = font.lookupCmapFormat4(codePoint)
    of 6: glyph = font.lookupCmapFormat6(codePoint)
    of 12: glyph = font.lookupCmapFormat12(codePoint)
    else: glyph = 0
  except TtfError, IndexDefect:
    glyph = 0
  if glyph >= font.numGlyphs: glyph = 0
  font.cmapTable[codePoint] = glyph
  glyph

proc hasGlyph*(font: TrueTypeFont, codePoint: int): bool {.inline.} =
  font.glyphIndex(codePoint) != 0

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

proc advanceWidth*(font: TrueTypeFont, glyph: int): float =
  ## Horizontal advance in font units. Glyphs past `numberOfHMetrics` all share
  ## the last entry's advance, which is how monospaced tails are encoded.
  if font.numberOfHMetrics == 0: return 0
  let index = min(glyph, font.numberOfHMetrics - 1)
  try:
    float(readU16(font.data, font.hmtxOffset + index * 4))
  except TtfError, IndexDefect:
    0.0

proc kerning*(font: TrueTypeFont, leftGlyph, rightGlyph: int): float =
  ## Kerning adjustment in font units, 0 when the pair isn't listed.
  if font.kernPairs.len == 0: return 0
  let key = (uint32(leftGlyph) shl 16) or uint32(rightGlyph)
  font.kernPairs.getOrDefault(key, 0.0)

proc glyphDataRange(font: TrueTypeFont, glyph: int): (int, int) =
  ## `[start, end)` of a glyph's record inside `glyf`; an empty range means a
  ## blank glyph (a space, typically).
  if glyph < 0 or glyph >= font.numGlyphs: return (0, 0)
  try:
    if font.indexToLocFormat == 0:
      let start = readU16(font.data, font.locaOffset + glyph * 2) * 2
      let stop = readU16(font.data, font.locaOffset + glyph * 2 + 2) * 2
      (start, stop)
    else:
      let start = readU32(font.data, font.locaOffset + glyph * 4)
      let stop = readU32(font.data, font.locaOffset + glyph * 4 + 4)
      (start, stop)
  except TtfError, IndexDefect:
    (0, 0)

# ---------------------------------------------------------------------------
# Outlines
# ---------------------------------------------------------------------------

const
  flagOnCurve = 0x01
  flagXShort = 0x02
  flagYShort = 0x04
  flagRepeat = 0x08
  flagXSame = 0x10
  flagYSame = 0x20

  curveSteps = 8
    ## Fixed subdivision per quadratic segment. At editor sizes (8–60pt) eight
    ## steps is below half a pixel of chord error, and a fixed count keeps the
    ## flattening allocation-free and predictable.

proc flattenQuadratic(contour: var Contour, p0, control, p1: Point) =
  for step in 1 .. curveSteps:
    let t = float(step) / float(curveSteps)
    let mt = 1.0 - t
    contour.points.add Point(
      x: mt * mt * p0.x + 2.0 * mt * t * control.x + t * t * p1.x,
      y: mt * mt * p0.y + 2.0 * mt * t * control.y + t * t * p1.y)

proc simpleGlyphOutline(font: TrueTypeFont, start: int,
                        outline: var Outline) =
  let data = font.data
  let numContours = readI16(data, start)
  if numContours <= 0: return
  outline.xMin = float(readI16(data, start + 2))
  outline.yMin = float(readI16(data, start + 4))
  outline.xMax = float(readI16(data, start + 6))
  outline.yMax = float(readI16(data, start + 8))

  var endPts = newSeq[int](numContours)
  for i in 0 ..< numContours:
    endPts[i] = readU16(data, start + 10 + i * 2)
  let numPoints = if numContours > 0: endPts[^1] + 1 else: 0
  if numPoints <= 0: return

  let instructionLength = readU16(data, start + 10 + numContours * 2)
  var cursor = start + 10 + numContours * 2 + 2 + instructionLength

  # Flags, with the repeat run expanded.
  var flags = newSeq[int](numPoints)
  var i = 0
  while i < numPoints:
    let flag = readU8(data, cursor)
    inc cursor
    flags[i] = flag
    inc i
    if (flag and flagRepeat) != 0:
      let repeats = readU8(data, cursor)
      inc cursor
      for _ in 0 ..< repeats:
        if i >= numPoints: break
        flags[i] = flag
        inc i

  # Deltas, x run then y run.
  var xs = newSeq[float](numPoints)
  var value = 0
  for k in 0 ..< numPoints:
    let flag = flags[k]
    if (flag and flagXShort) != 0:
      let delta = readU8(data, cursor)
      inc cursor
      value += (if (flag and flagXSame) != 0: delta else: -delta)
    elif (flag and flagXSame) == 0:
      value += readI16(data, cursor)
      cursor += 2
    xs[k] = float(value)
  var ys = newSeq[float](numPoints)
  value = 0
  for k in 0 ..< numPoints:
    let flag = flags[k]
    if (flag and flagYShort) != 0:
      let delta = readU8(data, cursor)
      inc cursor
      value += (if (flag and flagYSame) != 0: delta else: -delta)
    elif (flag and flagYSame) == 0:
      value += readI16(data, cursor)
      cursor += 2
    ys[k] = float(value)

  # Walk each contour, turning the quadratic B-spline into line segments.
  # Implied on-curve points between consecutive control points are the midpoint
  # of the pair, which is what makes a TrueType contour compact.
  var contourStart = 0
  for c in 0 ..< numContours:
    let contourEnd = endPts[c]
    if contourEnd < contourStart:
      contourStart = contourEnd + 1
      continue
    let count = contourEnd - contourStart + 1
    if count < 2:
      contourStart = contourEnd + 1
      continue

    template pt(k: int): Point =
      let idx = contourStart + ((k mod count) + count) mod count
      Point(x: xs[idx], y: ys[idx])
    template onCurve(k: int): bool =
      let idx = contourStart + ((k mod count) + count) mod count
      (flags[idx] and flagOnCurve) != 0

    # Find a starting on-curve point; synthesise one from a midpoint when the
    # whole contour is control points (legal, and some fonts do it).
    var startIndex = -1
    for k in 0 ..< count:
      if onCurve(k):
        startIndex = k
        break
    var contour = Contour()
    var current: Point
    if startIndex < 0:
      startIndex = 0
      let a = pt(0)
      let b = pt(count - 1)
      current = Point(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
    else:
      current = pt(startIndex)
    contour.points.add current

    var k = 1
    while k <= count:
      let index = startIndex + k
      if onCurve(index):
        current = pt(index)
        contour.points.add current
        inc k
      else:
        let control = pt(index)
        var nextOn: Point
        if onCurve(index + 1):
          nextOn = pt(index + 1)
          k += 2
        else:
          let nextControl = pt(index + 1)
          nextOn = Point(x: (control.x + nextControl.x) * 0.5,
                         y: (control.y + nextControl.y) * 0.5)
          inc k
        flattenQuadratic(contour, current, control, nextOn)
        current = nextOn
    if contour.points.len >= 2:
      outline.contours.add contour
    contourStart = contourEnd + 1

proc glyphOutline*(font: TrueTypeFont, glyph: int, depth = 0): Outline =
  ## The glyph's contours in font units. Composite glyphs recurse, with a depth
  ## cap so a malformed font cannot loop forever.
  if depth > 5: return Outline()
  let (start, stop) = font.glyphDataRange(glyph)
  if stop <= start: return Outline()          # blank glyph
  let base = font.glyfOffset + start
  try:
    let numContours = readI16(font.data, base)
    if numContours >= 0:
      font.simpleGlyphOutline(base, result)
      return result

    # Composite glyph.
    result.xMin = float(readI16(font.data, base + 2))
    result.yMin = float(readI16(font.data, base + 4))
    result.xMax = float(readI16(font.data, base + 6))
    result.yMax = float(readI16(font.data, base + 8))
    var cursor = base + 10
    while true:
      let flags = readU16(font.data, cursor)
      let glyphIndex = readU16(font.data, cursor + 2)
      cursor += 4
      const
        argsAreWords = 0x0001
        argsAreXYValues = 0x0002
        weHaveAScale = 0x0008
        moreComponents = 0x0020
        weHaveXYScale = 0x0040
        weHaveTwoByTwo = 0x0080
      var dx = 0.0
      var dy = 0.0
      if (flags and argsAreWords) != 0:
        if (flags and argsAreXYValues) != 0:
          dx = float(readI16(font.data, cursor))
          dy = float(readI16(font.data, cursor + 2))
        cursor += 4
      else:
        if (flags and argsAreXYValues) != 0:
          dx = float(readI8(font.data, cursor))
          dy = float(readI8(font.data, cursor + 1))
        cursor += 2
      var a = 1.0
      var b = 0.0
      var c = 0.0
      var d = 1.0
      if (flags and weHaveAScale) != 0:
        a = readF2Dot14(font.data, cursor)
        d = a
        cursor += 2
      elif (flags and weHaveXYScale) != 0:
        a = readF2Dot14(font.data, cursor)
        d = readF2Dot14(font.data, cursor + 2)
        cursor += 4
      elif (flags and weHaveTwoByTwo) != 0:
        a = readF2Dot14(font.data, cursor)
        b = readF2Dot14(font.data, cursor + 2)
        c = readF2Dot14(font.data, cursor + 4)
        d = readF2Dot14(font.data, cursor + 6)
        cursor += 8

      let component = font.glyphOutline(glyphIndex, depth + 1)
      for contour in component.contours:
        var transformed = Contour()
        for p in contour.points:
          transformed.points.add Point(x: a * p.x + c * p.y + dx,
                                       y: b * p.x + d * p.y + dy)
        result.contours.add transformed
      if (flags and moreComponents) == 0: break
  except TtfError, IndexDefect:
    return Outline()

# ---------------------------------------------------------------------------
# Rasterization
# ---------------------------------------------------------------------------

type
  GlyphBitmap* = object
    ## 8-bit coverage, row-major, `width * height` bytes. `left`/`top` are the
    ## offsets from the pen position (top-down, y growing downwards) at which
    ## the bitmap should be blitted.
    width*, height*: int
    left*, top*: int
    advance*: float
    coverage*: seq[uint8]

proc drawLine(acc: var seq[float32], width, height: int, p0, p1: Point) =
  ## Accumulate one edge's signed area into `acc`.
  ##
  ## This is the analytic-coverage method: each edge contributes signed partial
  ## areas to the cells it crosses, and a prefix sum along each row then yields
  ## exact coverage for the whole path in one pass — no supersampling, no
  ## per-scanline sorting, and correct for overlapping contours.
  if p0.y == p1.y: return
  var dir = 1.0
  var top = p0
  var bottom = p1
  if p0.y > p1.y:
    dir = -1.0
    top = p1
    bottom = p0
  let dxdy = (bottom.x - top.x) / (bottom.y - top.y)
  var x = top.x
  if top.y < 0:
    x -= top.y * dxdy
  let yStart = max(0, int(floor(top.y)))
  let yEnd = min(height, int(ceil(bottom.y)))
  if yStart >= yEnd: return

  # The accumulation row is one cell wider than the bitmap so the rightmost
  # partial cell always has somewhere to land.
  let stride = width + 2
  for y in yStart ..< yEnd:
    let lineStart = y * stride
    let dy = min(float(y + 1), bottom.y) - max(float(y), top.y)
    if dy <= 0:
      continue
    let xNext = x + dxdy * dy
    let d = dy * dir
    var x0 = x
    var x1 = xNext
    if x0 > x1: swap(x0, x1)
    # Clamp horizontally: ink outside the bitmap still has to contribute its
    # winding, or a glyph clipped on the left loses its fill entirely.
    x0 = clamp(x0, 0.0, float(width))
    x1 = clamp(x1, 0.0, float(width))
    let x0floor = floor(x0)
    let x0i = int(x0floor)
    let x1ceil = ceil(x1)
    let x1i = int(x1ceil)

    template bump(index: int, value: float) =
      let slot = lineStart + index
      if index >= 0 and index < stride and slot < acc.len:
        acc[slot] += float32(value)

    if x1i <= x0i + 1:
      # The span is narrower than one cell: split `d` between two neighbours by
      # the midpoint's fractional position.
      let xmf = 0.5 * (x0 + x1) - x0floor
      bump(x0i, d - d * xmf)
      bump(x0i + 1, d * xmf)
    else:
      let s = 1.0 / (x1 - x0)
      let x0f = x0 - x0floor
      let a0 = 0.5 * s * (1.0 - x0f) * (1.0 - x0f)
      let x1f = x1 - x1ceil + 1.0
      let am = 0.5 * s * x1f * x1f
      bump(x0i, d * a0)
      if x1i == x0i + 2:
        bump(x0i + 1, d * (1.0 - a0 - am))
      else:
        let a1 = s * (1.5 - x0f)
        bump(x0i + 1, d * (a1 - a0))
        for xi in x0i + 2 ..< x1i - 1:
          bump(xi, d * s)
        let a2 = a1 + float(x1i - x0i - 3) * s
        bump(x1i - 1, d * (1.0 - a2 - am))
      bump(x1i, d * am)
    x = xNext

proc rasterizeOutline*(outline: Outline, scale: float, subpixelX = 0.0,
                       shear = 0.0, emboldenUnits = 0.0,
                       unitsPerEm = 1000.0): GlyphBitmap =
  ## Rasterize `outline` at `scale` (pixels per font unit).
  ##
  ## `shear` applies a synthetic oblique (x += shear * y) and `emboldenUnits`
  ## a synthetic bold by widening the outline horizontally — both in font units,
  ## so they are resolution-independent. A family that ships real italic/bold
  ## faces never uses either.
  if outline.contours.len == 0 or scale <= 0:
    return GlyphBitmap()

  # Transform to device space (y down) and find the ink bounds.
  var contours: seq[seq[Point]] = @[]
  var minX = high(float)
  var minY = high(float)
  var maxX = low(float)
  var maxY = low(float)
  for contour in outline.contours:
    var devicePoints = newSeqOfCap[Point](contour.points.len)
    for p in contour.points:
      let sheared = p.x + shear * p.y
      let dx = sheared * scale
      let dy = -p.y * scale
      devicePoints.add Point(x: dx, y: dy)
      minX = min(minX, dx)
      maxX = max(maxX, dx)
      minY = min(minY, dy)
      maxY = max(maxY, dy)
    if devicePoints.len >= 2: contours.add devicePoints
  if contours.len == 0: return GlyphBitmap()

  let embolden = emboldenUnits * scale
  minX -= embolden
  maxX += embolden
  minY -= embolden * 0.5
  maxY += embolden * 0.5

  # One pixel of padding on every side absorbs the anti-aliased edge.
  let left = int(floor(minX + subpixelX)) - 1
  let top = int(floor(minY)) - 1
  let width = int(ceil(maxX + subpixelX)) - left + 2
  let height = int(ceil(maxY)) - top + 2
  if width <= 0 or height <= 0 or width > 4096 or height > 4096:
    return GlyphBitmap()

  let stride = width + 2
  var acc = newSeq[float32](stride * height)

  proc emitContour(points: seq[Point], offsetX: float) =
    var previous = Point(x: points[0].x + offsetX + subpixelX - float(left),
                         y: points[0].y - float(top))
    for i in 1 .. points.len:
      let source = points[i mod points.len]
      let current = Point(x: source.x + offsetX + subpixelX - float(left),
                          y: source.y - float(top))
      drawLine(acc, width, height, previous, current)
      previous = current

  for points in contours:
    emitContour(points, 0.0)
  if embolden > 0.01:
    # A second pass offset to the right thickens every stem by `embolden`
    # without needing to offset the outline's normals — good enough for a
    # synthetic bold, and it never self-intersects into holes.
    let steps = max(1, int(ceil(embolden * 2)))
    for step in 1 .. steps:
      let offsetX = embolden * 2.0 * float(step) / float(steps)
      for points in contours:
        emitContour(points, offsetX)

  var coverage = newSeq[uint8](width * height)
  for y in 0 ..< height:
    var total = 0.0
    let accRow = y * stride
    let outRow = y * width
    for x in 0 ..< width:
      total += float(acc[accRow + x])
      let value = abs(total)
      coverage[outRow + x] = uint8(clamp(value, 0.0, 1.0) * 255.0 + 0.5)
  GlyphBitmap(width: width, height: height, left: left, top: top,
              coverage: coverage)

proc rasterizeGlyph*(font: TrueTypeFont, glyph: int, pixelSize: float,
                     synthBold = false, synthItalic = false,
                     subpixelX = 0.0): GlyphBitmap =
  ## Rasterize one glyph at `pixelSize` pixels per em.
  let scale = pixelSize / font.metrics.unitsPerEm
  let outline = font.glyphOutline(glyph)
  let shear = if synthItalic: 0.2122 else: 0.0        # ≈ 12°, the usual oblique
  let embolden = if synthBold: font.metrics.unitsPerEm * 0.022 else: 0.0
  result = rasterizeOutline(outline, scale, subpixelX, shear, embolden,
                            font.metrics.unitsPerEm)
  result.advance = font.advanceWidth(glyph) * scale +
                   (if synthBold: embolden * scale * 2.0 else: 0.0)
