## font.nim
## MarkdownEngine (Nim port)
##
## The `NSFont` stand-in, split in two on purpose:
##
## * `FontDesc` — the DESCRIPTION of a font (family key, size, symbolic
##   traits). Pure data, which is all the styler needs: its whole model is
##   "compose traits on descent", i.e. `fontDescriptor.withSymbolicTraits`.
## * `TextMetrics` — the MEASUREMENT seam. `NSFont.ascender`/`descender`/
##   `leading` and `NSString.size(withAttributes:)` are CoreText calls; here
##   they are injected procs, supplied by the UI layer's TrueType rasterizer.
##
## Splitting them keeps the engine headless: the parser and styler are testable
## with the built-in approximate metrics, and the real rasterizer plugs in for
## rendering without the engine ever importing SDL.

import std/[math, tables, hashes]

type
  FontTrait* = enum
    ## `NSFontDescriptor.SymbolicTraits`, restricted to what the engine uses.
    ftBold
    ftItalic
    ftMonospace

  FontTraits* = set[FontTrait]

  FontDesc* = object
    ## A font request. `family` is a FAMILY KEY, not a file name — the UI layer
    ## maps it onto concrete faces (regular / bold / italic / bold-italic).
    family*: string
    size*: float
    traits*: FontTraits

  FontMetrics* = object
    ## `NSFont`'s vertical metrics. `descent` is POSITIVE downwards here, where
    ## `NSFont.descender` is negative — conversions live in `lineHeight`.
    ascent*: float
    descent*: float
    leading*: float
    capHeight*: float
    xHeight*: float
    underlinePosition*: float
    underlineThickness*: float

  MeasureProc* = proc (text: string, font: FontDesc): float {.closure, gcsafe.}
  MetricsProc* = proc (font: FontDesc): FontMetrics {.closure, gcsafe.}

  TextMetrics* = object
    ## The measurement seam. Both procs must be cheap: the styler calls
    ## `measure` thousands of times per restyle (the Swift original memoised
    ## it in `HeadingHelpers.textWidth` for exactly that reason, and so does
    ## `measureCached` below).
    measure*: MeasureProc
    metrics*: MetricsProc

const
  defaultFontFamily* = "sans"
  defaultMonoFamily* = "mono"
  defaultFontSize* = 15.0

func initFont*(family: string, size: float, traits: FontTraits = {}): FontDesc {.inline.} =
  FontDesc(family: family, size: size, traits: traits)

func systemFont*(size: float, traits: FontTraits = {}): FontDesc {.inline.} =
  FontDesc(family: defaultFontFamily, size: size, traits: traits)

func monospacedSystemFont*(size: float, traits: FontTraits = {}): FontDesc {.inline.} =
  FontDesc(family: defaultMonoFamily, size: size, traits: traits + {ftMonospace})

func adding*(font: FontDesc, extra: FontTraits): FontDesc {.inline.} =
  ## `NSFont(descriptor: descriptor.withSymbolicTraits(union), size:)` — the
  ## one operation the styler's compose-on-descent model is built from. Keeping
  ## the SIZE is the whole point: descending into bold inside a heading must
  ## not reset the heading's size (the bug the flat pass pipeline had).
  FontDesc(family: font.family, size: font.size, traits: font.traits + extra)

func removing*(font: FontDesc, drop: FontTraits): FontDesc {.inline.} =
  FontDesc(family: font.family, size: font.size, traits: font.traits - drop)

func withSize*(font: FontDesc, size: float): FontDesc {.inline.} =
  FontDesc(family: font.family, size: size, traits: font.traits)

func scaled*(font: FontDesc, factor: float): FontDesc {.inline.} =
  FontDesc(family: font.family, size: font.size * factor, traits: font.traits)

func withFamily*(font: FontDesc, family: string): FontDesc {.inline.} =
  FontDesc(family: family, size: font.size, traits: font.traits)

func isBold*(font: FontDesc): bool {.inline.} = ftBold in font.traits
func isItalic*(font: FontDesc): bool {.inline.} = ftItalic in font.traits

func hash*(f: FontDesc): Hash =
  var h: Hash = 0
  h = h !& hash(f.family)
  h = h !& hash(f.size)
  h = h !& hash(cast[uint8](f.traits))
  !$h

func `==`*(a, b: FontDesc): bool {.inline.} =
  a.family == b.family and a.size == b.size and a.traits == b.traits

func `$`*(f: FontDesc): string =
  result = f.family & "-" & $f.size
  if ftBold in f.traits: result.add "-bold"
  if ftItalic in f.traits: result.add "-italic"

# ---------------------------------------------------------------------------
# Approximate metrics: the headless fallback
# ---------------------------------------------------------------------------

func approximateMetrics*(font: FontDesc): FontMetrics =
  ## Ratios close to DejaVu Sans / DejaVu Sans Mono, so engine tests get
  ## plausible line heights without a rasterizer. The real values come from the
  ## UI layer; nothing about LAYOUT correctness depends on these numbers, only
  ## on them being consistent.
  let s = font.size
  if ftMonospace in font.traits:
    FontMetrics(ascent: s * 0.928, descent: s * 0.236, leading: 0.0,
                capHeight: s * 0.729, xHeight: s * 0.545,
                underlinePosition: -s * 0.13, underlineThickness: max(1.0, s * 0.06))
  else:
    FontMetrics(ascent: s * 0.928, descent: s * 0.236, leading: 0.0,
                capHeight: s * 0.729, xHeight: s * 0.545,
                underlinePosition: -s * 0.13, underlineThickness: max(1.0, s * 0.06))

func approximateAdvance*(c: char, font: FontDesc): float =
  ## Per-character advance in units of the em, roughly DejaVu-like.
  if ftMonospace in font.traits:
    return 0.6023
  let base =
    case c
    of 'i', 'j', 'l', '.', ',', ':', ';', '\'', '|', '!': 0.278
    of 'f', 't', 'r', '(', ')', '[', ']', '{', '}', '-', '/', '\\': 0.37
    of 'm', 'M', 'W', 'w', '@': 0.94
    of 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'K', 'N', 'O', 'P', 'Q', 'R',
       'S', 'T', 'U', 'V', 'X', 'Y', 'Z': 0.68
    of 'I': 0.295
    of 'J': 0.32
    of 'L': 0.557
    of ' ': 0.318
    of '\t': 1.27
    of '0'..'9': 0.636
    else: 0.613
  if ftBold in font.traits: base * 1.06 else: base

proc approximateMeasure*(text: string, font: FontDesc): float =
  var total = 0.0
  for ch in text:
    total += approximateAdvance(ch, font)
  total * font.size

let defaultTextMetrics* = TextMetrics(
  measure: proc (text: string, font: FontDesc): float {.closure, gcsafe.} =
    approximateMeasure(text, font),
  metrics: proc (font: FontDesc): FontMetrics {.closure, gcsafe.} =
    approximateMetrics(font))

# ---------------------------------------------------------------------------
# Derived values the styler needs
# ---------------------------------------------------------------------------

func lineHeight*(m: FontMetrics): float {.inline.} =
  ## `ceil(ascender - descender + leading)` — the Swift expression, with
  ## `descent` already positive here.
  ceil(m.ascent + m.descent + m.leading)

proc lineHeight*(tm: TextMetrics, font: FontDesc): float {.inline.} =
  lineHeight(tm.metrics(font))

# ---------------------------------------------------------------------------
# Memoised measurement (`HeadingHelpers.textWidth`)
# ---------------------------------------------------------------------------

type
  WidthCache* = ref object
    ## Bounded memo over `(text, font) → width`. The styler measures a tiny
    ## repeated set — list markers (`- `, `1. `), `$`/`$$`, per-formula slices —
    ## thousands of times per open. Same key, same width, so the cache is
    ## byte-identical to the direct call.
    entries: Table[string, float]
    order: seq[string]
    capacity: int

proc newWidthCache*(capacity = 4096): WidthCache =
  WidthCache(entries: initTable[string, float](), order: @[], capacity: capacity)

proc textWidth*(cache: WidthCache, tm: TextMetrics, text: string,
                font: FontDesc): float =
  if text.len == 0: return 0.0
  if cache == nil: return tm.measure(text, font)
  let key = $font & "|" & text
  cache.entries.withValue(key, hit):
    return hit[]
  let width = tm.measure(text, font)
  cache.entries[key] = width
  cache.order.add key
  if cache.order.len > cache.capacity:
    let evicted = cache.order[0]
    cache.order.delete(0)
    cache.entries.del(evicted)
  width
