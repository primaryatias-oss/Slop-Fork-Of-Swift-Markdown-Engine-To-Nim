## fontmanager.nim
## MarkdownEngine (Nim port) — UI layer
##
## Resolves the engine's `FontDesc` (a family key, a size and symbolic traits)
## onto concrete TrueType faces, measures strings, and caches rasterized
## glyphs.
##
## This is the other half of the seam `font.nim` opens: the engine declares
## `TextMetrics` as two procs and never looks at a font file; this module
## supplies them. It is also where the port honours a promise AppKit made for
## free — asking for bold italic when a family ships no such face falls back to
## the nearest face plus synthetic emboldening or shearing, rather than
## silently rendering regular.

import std/[math, os, strutils, tables, unicode]
import ../markdownengine/[font, ranges, utf16text]
import ./truetype

type
  FaceKey = tuple[family: string, bold: bool, italic: bool]

  Face* = ref object
    ## One resolved face plus whatever synthesis it needs to stand in for a
    ## face the family does not ship.
    font*: TrueTypeFont
    synthBold*: bool
    synthItalic*: bool
    path*: string

  GlyphKey = tuple[facePath: string, glyph: int, pixelSize: int,
                   bold: bool, italic: bool]

  FontManager* = ref object
    searchPaths: seq[string]
    groups: Table[string, seq[seq[string]]]
      ## family key → candidate GROUPS, best first; each group is
      ## `[regular, bold, italic, boldItalic]`
    resolvedGroup: Table[string, seq[string]]
      ## family key → the group that actually loaded
    faces: Table[FaceKey, Face]
    glyphs: Table[GlyphKey, GlyphBitmap]
    metricsCache: Table[FontDesc, FontMetrics]
    widthCacheHits*: int
    glyphCacheOrder: seq[GlyphKey]
    glyphCacheCap: int
    fallbackFaces: seq[Face]
      ## Consulted in order when the primary face has no glyph for a scalar —
      ## the port's stand-in for the system font cascade.
    fallbacksLoaded: bool

const
  defaultSearchPaths = [
    "/usr/share/fonts/truetype",
    "/usr/share/fonts/TTF",
    "/usr/share/fonts",
    "/usr/local/share/fonts",
    "/run/host/usr/share/fonts"
  ]

  # Families are resolved as a GROUP, not per style. Picking the best file for
  # each style independently is what makes a document look wrong in a subtle
  # way: a system with DejaVu's regular and bold but no DejaVu oblique would
  # borrow Liberation's italic, so one emphasis span inside a paragraph is a
  # different typeface at a different x-height. Choosing the group first and
  # synthesising a missing style from ITS OWN faces keeps the design
  # consistent, which is the behaviour AppKit's family lookup gave for free.
  #
  # Only TrueType (`glyf`) families are listed: the rasterizer rejects CFF
  # outlines, and a family that cannot be drawn must not shadow one that can.
  sansGroups = [
    ["dejavu/DejaVuSans.ttf", "dejavu/DejaVuSans-Bold.ttf",
     "dejavu/DejaVuSans-Oblique.ttf", "dejavu/DejaVuSans-BoldOblique.ttf"],
    ["DejaVuSans.ttf", "DejaVuSans-Bold.ttf",
     "DejaVuSans-Oblique.ttf", "DejaVuSans-BoldOblique.ttf"],
    ["liberation/LiberationSans-Regular.ttf", "liberation/LiberationSans-Bold.ttf",
     "liberation/LiberationSans-Italic.ttf", "liberation/LiberationSans-BoldItalic.ttf"],
    ["LiberationSans-Regular.ttf", "LiberationSans-Bold.ttf",
     "LiberationSans-Italic.ttf", "LiberationSans-BoldItalic.ttf"],
    ["noto/NotoSans-Regular.ttf", "noto/NotoSans-Bold.ttf",
     "noto/NotoSans-Italic.ttf", "noto/NotoSans-BoldItalic.ttf"],
    ["freefont/FreeSans.ttf", "freefont/FreeSansBold.ttf",
     "freefont/FreeSansOblique.ttf", "freefont/FreeSansBoldOblique.ttf"]]

  monoGroups = [
    ["dejavu/DejaVuSansMono.ttf", "dejavu/DejaVuSansMono-Bold.ttf",
     "dejavu/DejaVuSansMono-Oblique.ttf", "dejavu/DejaVuSansMono-BoldOblique.ttf"],
    ["DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf",
     "DejaVuSansMono-Oblique.ttf", "DejaVuSansMono-BoldOblique.ttf"],
    ["liberation/LiberationMono-Regular.ttf", "liberation/LiberationMono-Bold.ttf",
     "liberation/LiberationMono-Italic.ttf", "liberation/LiberationMono-BoldItalic.ttf"],
    ["LiberationMono-Regular.ttf", "LiberationMono-Bold.ttf",
     "LiberationMono-Italic.ttf", "LiberationMono-BoldItalic.ttf"],
    ["freefont/FreeMono.ttf", "freefont/FreeMonoBold.ttf",
     "freefont/FreeMonoOblique.ttf", "freefont/FreeMonoBoldOblique.ttf"]]

  serifGroups = [
    ["liberation/LiberationSerif-Regular.ttf", "liberation/LiberationSerif-Bold.ttf",
     "liberation/LiberationSerif-Italic.ttf", "liberation/LiberationSerif-BoldItalic.ttf"],
    ["LiberationSerif-Regular.ttf", "LiberationSerif-Bold.ttf",
     "LiberationSerif-Italic.ttf", "LiberationSerif-BoldItalic.ttf"],
    ["dejavu/DejaVuSerif.ttf", "dejavu/DejaVuSerif-Bold.ttf",
     "dejavu/DejaVuSerif-Italic.ttf", "dejavu/DejaVuSerif-BoldItalic.ttf"],
    ["freefont/FreeSerif.ttf", "freefont/FreeSerifBold.ttf",
     "freefont/FreeSerifItalic.ttf", "freefont/FreeSerifBoldItalic.ttf"]]

  # Last-resort coverage for scalars the primary face lacks (CJK, symbols,
  # emoji outlines). Each is optional; a missing file is simply skipped.
  fallbackCandidates = ["dejavu/DejaVuSans.ttf",
                        "noto/NotoSansSymbols2-Regular.ttf",
                        "wqy/wqy-zenhei.ttc",
                        "fonts-japanese-gothic.ttf",
                        "freefont/FreeSerif.ttf"]

proc newFontManager*(extraSearchPaths: seq[string] = @[]): FontManager =
  result = FontManager(
    searchPaths: @[], groups: initTable[string, seq[seq[string]]](),
    resolvedGroup: initTable[string, seq[string]](),
    faces: initTable[FaceKey, Face](), glyphs: initTable[GlyphKey, GlyphBitmap](),
    metricsCache: initTable[FontDesc, FontMetrics](), glyphCacheOrder: @[],
    glyphCacheCap: 8192, fallbackFaces: @[], fallbacksLoaded: false)
  for p in extraSearchPaths: result.searchPaths.add p
  for p in defaultSearchPaths: result.searchPaths.add p

  proc register(manager: FontManager, key: string,
                groups: openArray[array[4, string]]) =
    var list: seq[seq[string]] = @[]
    for group in groups:
      var files: seq[string] = @[]
      for f in group: files.add f
      list.add files
    manager.groups[key] = list

  result.register("sans", sansGroups)
  result.register("mono", monoGroups)
  result.register("serif", serifGroups)

proc resolvePath(manager: FontManager, candidate: string): string =
  ## An absolute candidate is taken as-is; a relative one is looked up under
  ## each search path.
  if candidate.len == 0: return ""
  if candidate.isAbsolute:
    return if fileExists(candidate): candidate else: ""
  for base in manager.searchPaths:
    let full = base / candidate
    if fileExists(full): return full
  ""

proc tryLoad(manager: FontManager, candidate: string): (TrueTypeFont, string) =
  let path = manager.resolvePath(candidate)
  if path.len == 0: return (nil, "")
  try:
    (loadTrueTypeFile(path), path)
  except TtfError, IOError, OSError:
    (nil, "")        # unreadable or CFF-only

proc groupFor(manager: FontManager, family: string): seq[string] =
  ## The first candidate group whose REGULAR face loads. Decided once per
  ## family and remembered, so every style request lands in the same design.
  manager.resolvedGroup.withValue(family, hit):
    return hit[]
  if manager.groups.hasKey(family):
    for group in manager.groups[family]:
      if group.len < 4: continue
      let (font, _) = manager.tryLoad(group[0])
      if font != nil:
        manager.resolvedGroup[family] = group
        return group
  manager.resolvedGroup[family] = @[]
  @[]

func styleIndex(bold, italic: bool): int {.inline.} =
  if bold and italic: 3 elif bold: 1 elif italic: 2 else: 0

proc normalizedFamily(family: string): string =
  ## Map an arbitrary family name onto one of the three keys this port ships.
  ## The engine's default is `"sans"`; a document that names something else
  ## still has to render, so anything unrecognised reads as sans.
  let lower = family.toLowerAscii
  if lower.len == 0: return "sans"
  if lower.contains("mono") or lower.contains("courier") or
     lower.contains("code") or lower.contains("consol"): return "mono"
  if lower.contains("serif") and not lower.contains("sans"): return "serif"
  if lower.contains("times") or lower.contains("georgia") or
     lower.contains("garamond") or lower.contains("caladea"): return "serif"
  "sans"

proc face*(manager: FontManager, desc: FontDesc): Face =
  ## The best face for `desc`, with synthesis flags set when the family's group
  ## ships no matching file. Returns `nil` only when no readable font exists at
  ## all.
  let family = normalizedFamily(desc.family)
  let wantBold = ftBold in desc.traits
  let wantItalic = ftItalic in desc.traits
  let key: FaceKey = (family, wantBold, wantItalic)
  manager.faces.withValue(key, hit):
    return hit[]

  proc resolveIn(manager: FontManager, group: seq[string]): Face =
    if group.len < 4: return nil
    # The exact style, then drop italic (synthesise it), then drop bold, then
    # the regular face — all WITHIN this group.
    var attempts: seq[tuple[bold, italic, synthBold, synthItalic: bool]] = @[]
    attempts.add (wantBold, wantItalic, false, false)
    if wantItalic: attempts.add (wantBold, false, false, true)
    if wantBold: attempts.add (false, wantItalic, true, false)
    if wantBold and wantItalic: attempts.add (false, false, true, true)
    attempts.add (false, false, wantBold, wantItalic)
    for attempt in attempts:
      let (font, path) = manager.tryLoad(
        group[styleIndex(attempt.bold, attempt.italic)])
      if font != nil:
        return Face(font: font, synthBold: attempt.synthBold,
                    synthItalic: attempt.synthItalic, path: path)
    nil

  var resolved = manager.resolveIn(manager.groupFor(family))
  # Nothing in this family: fall back to sans so text still draws.
  if resolved == nil and family != "sans":
    resolved = manager.resolveIn(manager.groupFor("sans"))
  if resolved != nil:
    manager.faces[key] = resolved
  resolved

proc loadFallbacks(manager: FontManager) =
  if manager.fallbacksLoaded: return
  manager.fallbacksLoaded = true
  for candidate in fallbackCandidates:
    let path = manager.resolvePath(candidate)
    if path.len == 0: continue
    try:
      manager.fallbackFaces.add Face(font: loadTrueTypeFile(path), path: path)
    except TtfError, IOError, OSError:
      discard

proc faceForScalar*(manager: FontManager, desc: FontDesc,
                    codePoint: int): (Face, int) =
  ## The face that can draw `codePoint`, plus the glyph index in it.
  ##
  ## AppKit cascaded automatically; here the cascade is explicit: the requested
  ## face first, then the fallback list. A scalar nothing covers returns glyph 0
  ## so the reader sees a `.notdef` box rather than a silent gap.
  let primary = manager.face(desc)
  if primary == nil: return (nil, 0)
  let glyph = primary.font.glyphIndex(codePoint)
  if glyph != 0 or codePoint == 0x20: return (primary, glyph)
  manager.loadFallbacks()
  for fallback in manager.fallbackFaces:
    if fallback.path == primary.path: continue
    let candidate = fallback.font.glyphIndex(codePoint)
    if candidate != 0:
      # Keep the requested synthesis so a bold run stays bold in the fallback.
      return (Face(font: fallback.font, synthBold: ftBold in desc.traits,
                   synthItalic: ftItalic in desc.traits, path: fallback.path),
              candidate)
  (primary, 0)

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

proc metricsFor*(manager: FontManager, desc: FontDesc): FontMetrics =
  ## Vertical metrics in pixels. Cached per `FontDesc` — the styler asks for
  ## the base, code and heading fonts on every restyle.
  manager.metricsCache.withValue(desc, hit):
    return hit[]
  let resolved = manager.face(desc)
  if resolved == nil:
    result = approximateMetrics(desc)
  else:
    let raw = resolved.font.metrics
    let scale = desc.size / raw.unitsPerEm
    result = FontMetrics(
      ascent: raw.ascender * scale,
      descent: -raw.descender * scale,
      leading: max(0.0, raw.lineGap * scale),
      capHeight: raw.capHeight * scale,
      xHeight: raw.xHeight * scale,
      underlinePosition: raw.underlinePosition * scale,
      underlineThickness: max(1.0, raw.underlineThickness * scale))
  manager.metricsCache[desc] = result

# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------

iterator runeCodePoints(s: string): int =
  for r in s.runes: yield int(r)

proc measureString*(manager: FontManager, text: string, desc: FontDesc): float =
  ## Advance width of `text` in pixels, with kerning applied between adjacent
  ## glyphs of the same face.
  if text.len == 0: return 0.0
  let resolved = manager.face(desc)
  if resolved == nil: return approximateMeasure(text, desc)
  let scale = desc.size / resolved.font.metrics.unitsPerEm
  let synthWidth = if resolved.synthBold:
                     resolved.font.metrics.unitsPerEm * 0.044 * scale
                   else: 0.0
  var total = 0.0
  var previousGlyph = -1
  var previousFace: Face = nil
  for cp in text.runeCodePoints:
    if cp == 0x0A or cp == 0x0D: continue        # a newline has no advance
    let (glyphFace, glyph) = manager.faceForScalar(desc, cp)
    if glyphFace == nil: continue
    let faceScale = desc.size / glyphFace.font.metrics.unitsPerEm
    if previousGlyph >= 0 and previousFace != nil and
       previousFace.path == glyphFace.path:
      total += glyphFace.font.kerning(previousGlyph, glyph) * faceScale
    total += glyphFace.font.advanceWidth(glyph) * faceScale + synthWidth
    previousGlyph = glyph
    previousFace = glyphFace
  total

proc measureCodePoint*(manager: FontManager, codePoint: int,
                       desc: FontDesc): float =
  ## Advance of a single scalar — what the layout engine asks per character.
  if codePoint == 0x0A or codePoint == 0x0D: return 0.0
  let (glyphFace, glyph) = manager.faceForScalar(desc, codePoint)
  if glyphFace == nil: return approximateAdvance(' ', desc) * desc.size
  let scale = desc.size / glyphFace.font.metrics.unitsPerEm
  let synthWidth = if glyphFace.synthBold:
                     glyphFace.font.metrics.unitsPerEm * 0.044 * scale
                   else: 0.0
  glyphFace.font.advanceWidth(glyph) * scale + synthWidth

proc kerningBetween*(manager: FontManager, left, right: int,
                     desc: FontDesc): float =
  ## Kerning between two scalars, 0 unless both land in the same face.
  if left <= 0 or right <= 0: return 0.0
  let (leftFace, leftGlyph) = manager.faceForScalar(desc, left)
  let (rightFace, rightGlyph) = manager.faceForScalar(desc, right)
  if leftFace == nil or rightFace == nil: return 0.0
  if leftFace.path != rightFace.path: return 0.0
  leftFace.font.kerning(leftGlyph, rightGlyph) *
    (desc.size / leftFace.font.metrics.unitsPerEm)

proc textMetrics*(manager: FontManager): TextMetrics =
  ## The engine's measurement seam, bound to this manager.
  let m = manager
  TextMetrics(
    measure: proc (text: string, desc: FontDesc): float {.closure, gcsafe.} =
      {.cast(gcsafe).}: m.measureString(text, desc),
    metrics: proc (desc: FontDesc): FontMetrics {.closure, gcsafe.} =
      {.cast(gcsafe).}: m.metricsFor(desc))

# ---------------------------------------------------------------------------
# Glyph raster cache
# ---------------------------------------------------------------------------

proc glyphBitmap*(manager: FontManager, desc: FontDesc,
                  codePoint: int): (GlyphBitmap, bool) =
  ## Rasterized coverage for one scalar at `desc`'s size, memoised.
  ##
  ## The cache is keyed by everything that determines the pixels, so a changed
  ## size or trait simply produces a different key — no invalidation needed.
  ## It is FIFO-capped rather than unbounded: a document that scrolls through a
  ## large glyph repertoire at several sizes would otherwise grow without end.
  if codePoint == 0x0A or codePoint == 0x0D or codePoint == 0x09:
    return (GlyphBitmap(), false)
  let (glyphFace, glyph) = manager.faceForScalar(desc, codePoint)
  if glyphFace == nil: return (GlyphBitmap(), false)
  let pixelSize = int(round(desc.size * 64.0))     # 1/64px quantisation
  let key: GlyphKey = (glyphFace.path, glyph, pixelSize,
                       glyphFace.synthBold, glyphFace.synthItalic)
  manager.glyphs.withValue(key, hit):
    inc manager.widthCacheHits
    return (hit[], hit[].width > 0 and hit[].height > 0)

  let bitmap = glyphFace.font.rasterizeGlyph(glyph, desc.size,
                                             glyphFace.synthBold,
                                             glyphFace.synthItalic)
  manager.glyphs[key] = bitmap
  manager.glyphCacheOrder.add key
  if manager.glyphCacheOrder.len > manager.glyphCacheCap:
    let evicted = manager.glyphCacheOrder[0]
    manager.glyphCacheOrder.delete(0)
    manager.glyphs.del(evicted)
  (bitmap, bitmap.width > 0 and bitmap.height > 0)

proc glyphCacheKeyString*(manager: FontManager, desc: FontDesc,
                          codePoint: int): string =
  ## A stable identity for the atlas to key its uploaded regions by.
  let (glyphFace, glyph) = manager.faceForScalar(desc, codePoint)
  if glyphFace == nil: return ""
  glyphFace.path & "|" & $glyph & "|" & $int(round(desc.size * 64.0)) & "|" &
    (if glyphFace.synthBold: "b" else: "") &
    (if glyphFace.synthItalic: "i" else: "")

proc availableFamilies*(manager: FontManager): seq[string] =
  ## Which of the three family keys actually resolved to a file — surfaced so
  ## the demo can report an environment with no usable fonts instead of drawing
  ## nothing.
  for key in ["sans", "mono", "serif"]:
    if manager.groupFor(key).len > 0: result.add key

# ---------------------------------------------------------------------------
# UTF-16 helpers the layout engine needs
# ---------------------------------------------------------------------------

iterator scalars*(t: Utf16Text, r: Range): tuple[index: int, length: int,
                                                 codePoint: int] =
  ## Walk a UTF-16 range as Unicode scalars, recombining surrogate pairs.
  ## `index` and `length` stay in UTF-16 units so callers keep speaking the
  ## engine's coordinate system.
  let c = clamped(r, t.len)
  var i = c.location
  let stop = maxRange(c)
  while i < stop:
    let unit = int(t.charAt(i))
    if unit >= 0xD800 and unit <= 0xDBFF and i + 1 < stop:
      let low = int(t.charAt(i + 1))
      if low >= 0xDC00 and low <= 0xDFFF:
        yield (i, 2, 0x10000 + ((unit - 0xD800) shl 10) + (low - 0xDC00))
        i += 2
        continue
    yield (i, 1, unit)
    inc i
