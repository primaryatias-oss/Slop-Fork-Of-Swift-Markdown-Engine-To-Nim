## attributes.nim
## MarkdownEngine (Nim port)
##
## `NSAttributedString.Key` / `[Key: Any]` / `StyledRange`, and
## `NSParagraphStyle`.
##
## Swift could get away with `Any` values; here the value set is closed, which
## is strictly better for a port: a typo in an attribute's type is a compile
## error instead of a silent `as?` failure at draw time.
##
## **Ordering is load-bearing.** `applyStyledRanges` relies on paragraphs being
## applied in the given order and, within a paragraph, on the ranges keeping
## their emission order — repeated `addAttribute` is what makes a LATER range
## win per key. `Attrs` is therefore an ordered association list, not a hash
## table.

import std/[algorithm, math]
import ./ranges, ./color, ./font

type
  AttrKey* = enum
    ## Every attribute the engine puts on text. The first block mirrors the
    ## AppKit keys; the rest are the engine's own (`MarkdownTextLayoutFragment`
    ## and friends declared them as custom `NSAttributedString.Key`s).
    akFont
    akForegroundColor
    akBackgroundColor
    akParagraphStyle
    akUnderlineStyle
    akUnderlineColor
    akStrikethroughStyle
    akStrikethroughColor
    akKern
    akBaselineOffset
    akLink
    akSpellingState
    # Engine-owned keys
    akWikiLinkID              ## "NodeLinkID"
    akTaskCheckbox            ## "TaskCheckbox" — value is the checked flag
    akMarkdownBlockBackground ## line-box-wide fill (highlight spans)
    akBlockquoteLevel
    akBulletMarker
    akOrderedMarker           ## display marker string painted over the source
    akThematicBreak
    akThematicBreakMark
    akThematicBreakMarkScale
    akLatexImage
    akLatexBounds
    akLatexIsBlock
    akLatexBlockOffsetY
    akFindHighlight
    akDirectiveGlyph          ## replacement text/symbol drawn for a directive
    akDirectiveGlyphTint
    akImageEmbed              ## resolved image handle for `![[…]]` / `![](…)`
    akImageBounds
    akTableRender             ## rendered-table handle
    akScrollableBlockNaturalWidth
    akScrollableBlockSourceID
    akScrollableBlockTotalHeight
    akScrollableBlockFullRange

  UnderlineStyle* = enum
    ulNone = 0
    ulSingle = 1
    ulThick = 2
    ulDouble = 9

  LineBreakMode* = enum
    lbWordWrapping
    lbCharWrapping
    lbClipping

  TextAlignment* = enum
    taNatural
    taLeft
    taCenter
    taRight

  TextTab* = object
    location*: float
    alignment*: TextAlignment

  ParagraphStyle* = ref object
    ## `NSMutableParagraphStyle`, restricted to the fields the engine sets.
    ## A reference type because the Swift code mutates one and hands it round;
    ## treat instances as immutable once attached to a styled range.
    minimumLineHeight*: float
    maximumLineHeight*: float
    lineSpacing*: float
    paragraphSpacing*: float
    paragraphSpacingBefore*: float
    firstLineHeadIndent*: float
    headIndent*: float
    tailIndent*: float
    lineBreakMode*: LineBreakMode
    alignment*: TextAlignment
    tabStops*: seq[TextTab]
    defaultTabInterval*: float

  ImageHandle* = object
    ## Opaque handle to a rendered raster the UI layer owns (an embedded image,
    ## a LaTeX formula, a rendered table). The engine only moves it around and
    ## reserves space for it; it never decodes or draws anything.
    id*: int
    width*: float
    height*: float
    baselineOffset*: float

  AttrValueKind* = enum
    avFont
    avColor
    avParagraph
    avFloat
    avInt
    avBool
    avString
    avRange
    avImage
    avUnderline

  AttrValue* = object
    case kind*: AttrValueKind
    of avFont: fontVal*: FontDesc
    of avColor: colorVal*: Color
    of avParagraph: paraVal*: ParagraphStyle
    of avFloat: floatVal*: float
    of avInt: intVal*: int
    of avBool: boolVal*: bool
    of avString: stringVal*: string
    of avRange: rangeVal*: Range
    of avImage: imageVal*: ImageHandle
    of avUnderline: underlineVal*: UnderlineStyle

  Attrs* = seq[tuple[key: AttrKey, value: AttrValue]]
    ## Ordered, small (1–4 entries in practice). Linear lookup beats hashing
    ## at this size and keeps emission order observable.

  StyledRange* = tuple[range: Range, attributes: Attrs]
    ## `typealias StyledRange = (range: NSRange, attributes: [Key: Any])`

# ---------------------------------------------------------------------------
# Value constructors
# ---------------------------------------------------------------------------

func av*(v: FontDesc): AttrValue {.inline.} = AttrValue(kind: avFont, fontVal: v)
func av*(v: Color): AttrValue {.inline.} = AttrValue(kind: avColor, colorVal: v)
func av*(v: ParagraphStyle): AttrValue {.inline.} = AttrValue(kind: avParagraph, paraVal: v)
func av*(v: float): AttrValue {.inline.} = AttrValue(kind: avFloat, floatVal: v)
func av*(v: int): AttrValue {.inline.} = AttrValue(kind: avInt, intVal: v)
func av*(v: bool): AttrValue {.inline.} = AttrValue(kind: avBool, boolVal: v)
func av*(v: string): AttrValue {.inline.} = AttrValue(kind: avString, stringVal: v)
func av*(v: Range): AttrValue {.inline.} = AttrValue(kind: avRange, rangeVal: v)
func av*(v: ImageHandle): AttrValue {.inline.} = AttrValue(kind: avImage, imageVal: v)
func av*(v: UnderlineStyle): AttrValue {.inline.} = AttrValue(kind: avUnderline, underlineVal: v)

func `==`*(a, b: AttrValue): bool =
  if a.kind != b.kind: return false
  case a.kind
  of avFont: a.fontVal == b.fontVal
  of avColor: a.colorVal == b.colorVal
  of avParagraph: a.paraVal == b.paraVal
  of avFloat: a.floatVal == b.floatVal
  of avInt: a.intVal == b.intVal
  of avBool: a.boolVal == b.boolVal
  of avString: a.stringVal == b.stringVal
  of avRange: a.rangeVal == b.rangeVal
  of avImage: a.imageVal == b.imageVal
  of avUnderline: a.underlineVal == b.underlineVal

# ---------------------------------------------------------------------------
# Attrs operations
# ---------------------------------------------------------------------------

func get*(attrs: Attrs, key: AttrKey): AttrValue =
  ## LAST wins, matching repeated `addAttribute` on the same key.
  var found = false
  for pair in attrs:
    if pair.key == key:
      result = pair.value
      found = true
  if not found:
    result = AttrValue(kind: avBool, boolVal: false)

func has*(attrs: Attrs, key: AttrKey): bool =
  for pair in attrs:
    if pair.key == key: return true
  false

proc put*(attrs: var Attrs, key: AttrKey, value: AttrValue) =
  ## `addAttribute`: replace in place when present (keeping position), else
  ## append. Keeping position matters for nothing semantic, but it keeps the
  ## debug dumps stable.
  for i in 0 ..< attrs.len:
    if attrs[i].key == key:
      attrs[i].value = value
      return
  attrs.add (key, value)

proc merge*(attrs: var Attrs, other: Attrs) =
  for pair in other: attrs.put(pair.key, pair.value)

func attrs*(pairs: varargs[tuple[key: AttrKey, value: AttrValue]]): Attrs =
  for p in pairs: result.add p

func fontOf*(a: Attrs, fallback: FontDesc): FontDesc =
  let v = a.get(akFont)
  if v.kind == avFont: v.fontVal else: fallback

func colorOf*(a: Attrs, key: AttrKey, fallback: Color): Color =
  let v = a.get(key)
  if v.kind == avColor: v.colorVal else: fallback

func floatOf*(a: Attrs, key: AttrKey, fallback = 0.0): float =
  let v = a.get(key)
  case v.kind
  of avFloat: v.floatVal
  of avInt: float(v.intVal)
  else: fallback

func intOf*(a: Attrs, key: AttrKey, fallback = 0): int =
  let v = a.get(key)
  case v.kind
  of avInt: v.intVal
  of avFloat: int(v.floatVal)
  else: fallback

func boolOf*(a: Attrs, key: AttrKey, fallback = false): bool =
  let v = a.get(key)
  if v.kind == avBool: v.boolVal else: fallback

func stringOf*(a: Attrs, key: AttrKey, fallback = ""): string =
  let v = a.get(key)
  if v.kind == avString: v.stringVal else: fallback

func paragraphOf*(a: Attrs, fallback: ParagraphStyle): ParagraphStyle =
  let v = a.get(akParagraphStyle)
  if v.kind == avParagraph and v.paraVal != nil: v.paraVal else: fallback

func imageOf*(a: Attrs, key: AttrKey): (ImageHandle, bool) =
  let v = a.get(key)
  if v.kind == avImage: (v.imageVal, true)
  else: (ImageHandle(), false)

# ---------------------------------------------------------------------------
# ParagraphStyle
# ---------------------------------------------------------------------------

proc newParagraphStyle*(): ParagraphStyle =
  ParagraphStyle(minimumLineHeight: 0, maximumLineHeight: 0, lineSpacing: 0,
                 paragraphSpacing: 0, paragraphSpacingBefore: 0,
                 firstLineHeadIndent: 0, headIndent: 0, tailIndent: 0,
                 lineBreakMode: lbWordWrapping, alignment: taNatural,
                 tabStops: @[], defaultTabInterval: 0)

proc copyParagraphStyle*(src: ParagraphStyle): ParagraphStyle =
  if src == nil: return newParagraphStyle()
  ParagraphStyle(minimumLineHeight: src.minimumLineHeight,
                 maximumLineHeight: src.maximumLineHeight,
                 lineSpacing: src.lineSpacing,
                 paragraphSpacing: src.paragraphSpacing,
                 paragraphSpacingBefore: src.paragraphSpacingBefore,
                 firstLineHeadIndent: src.firstLineHeadIndent,
                 headIndent: src.headIndent,
                 tailIndent: src.tailIndent,
                 lineBreakMode: src.lineBreakMode,
                 alignment: src.alignment,
                 tabStops: src.tabStops,
                 defaultTabInterval: src.defaultTabInterval)

proc evenTabStops*(perLevel: float, count = 24): seq[TextTab] =
  ## `(1...24).map { NSTextTab(.left, location: $0 * perLevel) }` — the base
  ## paragraph style's tab ladder.
  for i in 1 .. count:
    result.add TextTab(location: float(i) * perLevel, alignment: taLeft)

func nextTabStop*(ps: ParagraphStyle, x: float): float =
  ## Where a tab at pen position `x` advances to. Explicit stops first, then
  ## `defaultTabInterval`, then a hard 28pt fallback so a tab always advances.
  if ps != nil:
    for stop in ps.tabStops:
      if stop.location > x + 0.01: return stop.location
    if ps.defaultTabInterval > 0:
      let n = floor(x / ps.defaultTabInterval) + 1
      return n * ps.defaultTabInterval
  (floor(x / 28.0) + 1) * 28.0

# ---------------------------------------------------------------------------
# Styled-range post-processing
# ---------------------------------------------------------------------------

proc normalizeParagraphCandidates*(candidates: seq[Range]): seq[Range] =
  ## `TextStylingService.normalize`: drop exact duplicates in one pass, keeping
  ## order and keeping overlapping-but-unequal ranges exactly as they were.
  var seen: seq[int] = @[]
  for candidate in candidates:
    if candidate.location == NotFound or candidate.length <= 0: continue
    let key = candidate.location * 1_000_003 + candidate.length
    if key notin seen:
      seen.add key
      result.add candidate

type
  AttributeRun* = object
    ## A resolved, non-overlapping run — what layout and drawing consume after
    ## the styled ranges have been flattened over the base attributes.
    range*: Range
    attributes*: Attrs

proc applyStyledRanges*(styled: seq[StyledRange], paragraphs: seq[Range],
                        baseAttributes: Attrs,
                        storage: var seq[Attrs]) =
  ## `TextStylingService.applyStyledRanges`, over a per-character attribute
  ## array instead of an `NSMutableAttributedString`.
  ##
  ## Order is load-bearing twice, exactly as the Swift comment says: paragraphs
  ## run in the given order (they may nest, and the later base-attribute reset
  ## wipes what an earlier one painted), and inside a paragraph the ranges run
  ## in their original order, so a later range wins per key.
  for paragraph in paragraphs:
    let p = clamped(paragraph, storage.len)
    for i in p.location ..< maxRange(p):
      storage[i] = baseAttributes
    for (r, a) in styled:
      let clip = intersection(r, p)
      if clip.length <= 0: continue
      for i in clip.location ..< maxRange(clip):
        for pair in a:
          storage[i].put(pair.key, pair.value)

proc flattenRuns*(storage: seq[Attrs], within: Range): seq[AttributeRun] =
  ## Collapse equal neighbouring attribute sets into runs, so layout walks
  ## runs rather than characters.
  let w = clamped(within, storage.len)
  if w.length <= 0: return @[]
  var runStart = w.location
  var i = w.location + 1
  while i < maxRange(w):
    if storage[i] != storage[runStart]:
      result.add AttributeRun(range: Range(location: runStart, length: i - runStart),
                              attributes: storage[runStart])
      runStart = i
    inc i
  result.add AttributeRun(range: Range(location: runStart, length: maxRange(w) - runStart),
                          attributes: storage[runStart])

proc collapsedStyledRanges*(styled: seq[StyledRange], documentLength: int): seq[AttributeRun] =
  ## `MarkdownStyler.collapsed…`: non-overlapping ascending runs, for callers
  ## (tests, the HTML path) that want the styler's output without a storage.
  if documentLength <= 0: return @[]
  var boundaries: seq[int] = @[0, documentLength]
  for (r, _) in styled:
    let c = clamped(r, documentLength)
    if c.length <= 0: continue
    boundaries.add c.location
    boundaries.add maxRange(c)
  boundaries.sort()
  var uniq: seq[int] = @[]
  for b in boundaries:
    if uniq.len == 0 or uniq[^1] != b: uniq.add b
  for i in 0 ..< uniq.len - 1:
    let seg = Range(location: uniq[i], length: uniq[i + 1] - uniq[i])
    if seg.length <= 0: continue
    var acc: Attrs = @[]
    for (r, a) in styled:
      if containsRange(r, seg):
        for pair in a: acc.put(pair.key, pair.value)
    if acc.len > 0:
      result.add AttributeRun(range: seg, attributes: acc)
