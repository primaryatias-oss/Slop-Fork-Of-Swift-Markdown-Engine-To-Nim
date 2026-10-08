## textstorage.nim
## MarkdownEngine (Nim port) — UI layer
##
## `NSTextStorage`: the document's UTF-16 text plus its attributes, kept as a
## gap-free run list.
##
## Runs, not a per-character array, for the reason `NSMutableAttributedString`
## uses them: a styled range is applied per paragraph and the result is almost
## always a handful of runs, so a per-character array would cost one `Attrs`
## sequence per code unit on a document where fifty runs describe the whole
## thing.
##
## The application path reproduces `TextStylingService.applyStyledRanges`
## exactly, including the two orderings the Swift comment calls load-bearing:
## paragraphs run in the order given (they may nest, and a later paragraph's
## base-attribute reset wipes what an earlier one painted), and inside a
## paragraph the styled ranges run in their emission order, so a later range
## wins per key.

import ../markdownengine/[ranges, utf16text, attributes]

type
  TextStorage* = ref object
    text*: Utf16Text
    runs*: seq[AttributeRun]     ## tiling `[0, text.len)`, ascending

proc newTextStorage*(initial = ""): TextStorage =
  let t = initText(initial)
  result = TextStorage(text: t, runs: @[])
  if t.len > 0:
    result.runs.add AttributeRun(range: t.fullRange, attributes: @[])

proc len*(storage: TextStorage): int {.inline.} = storage.text.len

proc rebuildRuns(storage: TextStorage) =
  storage.runs = @[]
  if storage.len > 0:
    storage.runs.add AttributeRun(range: storage.text.fullRange, attributes: @[])

proc setText*(storage: TextStorage, text: string) =
  storage.text = initText(text)
  storage.rebuildRuns()

proc setText*(storage: TextStorage, units: sink seq[uint16]) =
  storage.text = initText(units)
  storage.rebuildRuns()

proc runIndexAt*(storage: TextStorage, location: int): int =
  ## Index of the run containing `location`; -1 when out of range.
  if location < 0 or location >= storage.len or storage.runs.len == 0: return -1
  var lo = 0
  var hi = storage.runs.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if storage.runs[mid].range.location <= location: lo = mid else: hi = mid - 1
  if contains(storage.runs[lo].range, location): lo else: -1

proc attributesAt*(storage: TextStorage, location: int): Attrs =
  let index = storage.runIndexAt(location)
  if index < 0: @[] else: storage.runs[index].attributes

proc runsIn*(storage: TextStorage, r: Range): seq[AttributeRun] =
  ## Every run intersecting `r`, clipped to it.
  let c = clamped(r, storage.len)
  if c.length <= 0: return @[]
  var index = storage.runIndexAt(c.location)
  if index < 0: index = 0
  while index < storage.runs.len and storage.runs[index].range.location < maxRange(c):
    let clip = intersection(storage.runs[index].range, c)
    if clip.length > 0:
      result.add AttributeRun(range: clip,
                              attributes: storage.runs[index].attributes)
    inc index

proc spliceRuns(storage: TextStorage, region: Range,
                replacement: seq[AttributeRun]) =
  ## Replace the runs covering `region` with `replacement` (already tiling
  ## `region`), keeping the whole list gap-free.
  var rebuilt: seq[AttributeRun] = @[]
  for run in storage.runs:
    if maxRange(run.range) <= region.location:
      rebuilt.add run
    elif run.range.location < region.location:
      rebuilt.add AttributeRun(
        range: rng(run.range.location, region.location - run.range.location),
        attributes: run.attributes)
  rebuilt.add replacement
  for run in storage.runs:
    if run.range.location >= maxRange(region):
      rebuilt.add run
    elif maxRange(run.range) > maxRange(region):
      rebuilt.add AttributeRun(
        range: rng(maxRange(region), maxRange(run.range) - maxRange(region)),
        attributes: run.attributes)
  # Coalesce neighbours that ended up carrying identical attributes.
  storage.runs = @[]
  for run in rebuilt:
    if run.range.length <= 0: continue
    if storage.runs.len > 0 and
       maxRange(storage.runs[^1].range) == run.range.location and
       storage.runs[^1].attributes == run.attributes:
      storage.runs[^1].range.length += run.range.length
    else:
      storage.runs.add run

proc applyStyledRanges*(storage: TextStorage, styled: seq[StyledRange],
                        paragraphs: seq[Range], baseAttributes: Attrs) =
  ## Lay the base attributes down per paragraph and paint the styled ranges
  ## over them, clipped to the paragraph.
  ##
  ## The per-character expansion is bounded by ONE paragraph, then compressed
  ## back to runs before splicing — so the exact `addAttribute` semantics are
  ## preserved without ever materialising the document character by character.
  if storage.len == 0: return
  for paragraph in paragraphs:
    let p = clamped(paragraph, storage.len)
    if p.length <= 0: continue
    var perChar = newSeq[Attrs](p.length)
    for i in 0 ..< p.length:
      perChar[i] = baseAttributes
    for (r, a) in styled:
      let clip = intersection(r, p)
      if clip.length <= 0: continue
      for i in clip.location ..< maxRange(clip):
        for pair in a:
          perChar[i - p.location].put(pair.key, pair.value)
    var compressed: seq[AttributeRun] = @[]
    var runStart = 0
    for i in 1 .. p.length:
      if i == p.length or perChar[i] != perChar[runStart]:
        compressed.add AttributeRun(
          range: rng(p.location + runStart, i - runStart),
          attributes: perChar[runStart])
        runStart = i
    storage.spliceRuns(p, compressed)

proc setAttributes*(storage: TextStorage, r: Range, attrs: Attrs) =
  ## `setAttributes(_:range:)`: replace wholesale over `r`.
  let c = clamped(r, storage.len)
  if c.length <= 0: return
  storage.spliceRuns(c, @[AttributeRun(range: c, attributes: attrs)])

proc addAttribute*(storage: TextStorage, r: Range, key: AttrKey,
                   value: AttrValue) =
  ## `addAttribute(_:value:range:)`: merge one key over `r`, splitting runs.
  let c = clamped(r, storage.len)
  if c.length <= 0: return
  var replacement: seq[AttributeRun] = @[]
  for run in storage.runsIn(c):
    var merged = run.attributes
    merged.put(key, value)
    replacement.add AttributeRun(range: run.range, attributes: merged)
  storage.spliceRuns(c, replacement)

proc removeAttribute*(storage: TextStorage, r: Range, key: AttrKey) =
  let c = clamped(r, storage.len)
  if c.length <= 0: return
  var replacement: seq[AttributeRun] = @[]
  for run in storage.runsIn(c):
    var stripped: Attrs = @[]
    for pair in run.attributes:
      if pair.key != key: stripped.add pair
    replacement.add AttributeRun(range: run.range, attributes: stripped)
  storage.spliceRuns(c, replacement)

# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

proc replaceCharacters*(storage: TextStorage, r: Range,
                        replacement: seq[uint16]) =
  ## Splice the text and shift the runs. The replaced span adopts the
  ## attributes of the run it starts in, which is what every text system does
  ## so typed text inherits the formatting at the caret; the restyle that
  ## follows overwrites it anyway.
  let c = clamped(r, storage.len)
  let inherited =
    if storage.len == 0: @[]
    elif c.location < storage.len: storage.attributesAt(c.location)
    elif c.location > 0: storage.attributesAt(c.location - 1)
    else: @[]
  let delta = replacement.len - c.length

  var units = storage.text.units
  units[c.location ..< maxRange(c)] = replacement
  storage.text = initText(units)

  if storage.len == 0:
    storage.runs = @[]
    return

  var rebuilt: seq[AttributeRun] = @[]
  for run in storage.runs:
    if maxRange(run.range) <= c.location:
      rebuilt.add run
    elif run.range.location < c.location:
      rebuilt.add AttributeRun(
        range: rng(run.range.location, c.location - run.range.location),
        attributes: run.attributes)
  if replacement.len > 0:
    rebuilt.add AttributeRun(range: rng(c.location, replacement.len),
                             attributes: inherited)
  for run in storage.runs:
    if run.range.location >= maxRange(c):
      rebuilt.add AttributeRun(range: run.range.shifted(delta),
                               attributes: run.attributes)
    elif maxRange(run.range) > maxRange(c):
      rebuilt.add AttributeRun(
        range: rng(maxRange(c) + delta, maxRange(run.range) - maxRange(c)),
        attributes: run.attributes)

  storage.runs = @[]
  for run in rebuilt:
    if run.range.length <= 0: continue
    if storage.runs.len > 0 and
       maxRange(storage.runs[^1].range) == run.range.location and
       storage.runs[^1].attributes == run.attributes:
      storage.runs[^1].range.length += run.range.length
    else:
      storage.runs.add run

  # The splice must still tile the document; a mismatch means a bug upstream,
  # and leaving it would read as corrupted attributes rather than a crash.
  if storage.runs.len > 0 and maxRange(storage.runs[^1].range) != storage.len:
    storage.rebuildRuns()

proc replaceCharacters*(storage: TextStorage, r: Range, replacement: string) {.inline.} =
  storage.replaceCharacters(r, toUtf16(replacement))

proc substring*(storage: TextStorage, r: Range): string {.inline.} =
  storage.text.substring(r)

proc `$`*(storage: TextStorage): string {.inline.} = $storage.text

# ---------------------------------------------------------------------------
# Paragraph candidates
# ---------------------------------------------------------------------------

proc paragraphsFor*(storage: TextStorage, ranges: seq[Range]): seq[Range] =
  ## Expand each candidate to whole paragraphs and drop exact duplicates —
  ## the shape the styler's scoped restyle and the attribute application both
  ## expect.
  var expanded: seq[Range] = @[]
  for r in ranges:
    if r.location == NotFound: continue
    expanded.add storage.text.paragraphRange(clamped(r, storage.len))
  normalizeParagraphCandidates(expanded)

proc fullParagraphs*(storage: TextStorage): seq[Range] =
  ## Every paragraph, in order — the initial-load scope.
  if storage.len == 0: return @[]
  var cursor = 0
  while cursor < storage.len:
    let paragraph = storage.text.paragraphRange(caretAt(cursor))
    if paragraph.length <= 0: break
    result.add paragraph
    cursor = maxRange(paragraph)
