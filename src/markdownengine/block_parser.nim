## block_parser.nim
## MarkdownEngine (Nim port)
##
## The block-structure pass. Splits the document into a flat, gap-free (tiling)
## sequence of blocks following the CommonMark two-phase model — block
## structure first, inline content later. Inline parsing happens per
## inline-bearing block in a separate step (`ast.nim`).
##
## Ranges are absolute UTF-16 offsets into the source.
##
## Line classification mirrors the recognition the original regex tokenizer /
## styler performed, so block ranges line up with the tokens:
##
## * heading        — `^\s*#{1,6} +…`
## * thematic break — `^\s*(-{3,}|\*{3,}|_{3,})\s*$`
## * fenced code    — opening/closing ``` line
## * blockquote     — `^[ \t]{0,3}(>…)`
##
## **Invariant:** parsing is incremental. The last parse is memoised against
## its UTF-16 buffer, so both per-keystroke callers share one line scan; an
## edit that provably cannot ripple is spliced into the previous block list
## instead of re-scanning the document.
##
## Threading note: the Swift original guarded its caches with an `NSLock`
## because AppKit could restyle off the main thread. This port is
## single-threaded by construction (`--threads:off`, one SDL event loop), so
## the caches are plain module-level state.

import std/[strutils, tables]
import ./ranges, ./utf16text, ./extension

type
  BlockKind* = enum
    bkParagraph      ## inline-bearing
    bkHeading        ## single ATX line (`# …`), inline-bearing content
    bkBlockquote     ## consecutive `>` lines, inline-bearing per line
    bkList           ## consecutive list-item lines (`-`/`*`/`+` or `1.`/`1)`)
    bkFencedCode     ## ```…``` — opaque (no inline parsing inside)
    bkBlockLatex     ## `$$…$$` — opaque
    bkTable          ## GFM table — opaque (rendered as a unit)
    bkThematicBreak  ## `---` / `***` / `___`
    bkBlank          ## blank / whitespace-only line(s) — separator
    bkExt            ## extension-supplied fenced block, inline-bearing content

  Block* = object
    ## One block; `range` is the absolute UTF-16 span of its lines, tiling with
    ## no gaps. `extensionID` is set only for `bkExt`.
    kind*: BlockKind
    range*: Range
    extensionID*: string

  BufferDiff* = object
    ## A resolved contiguous change between two buffer states, in UTF-16 units.
    ## `changeStart ..< changeEndOld` in the old buffer was replaced by
    ## `changeStart ..< changeEndNew` in the new one. The region may be wider
    ## than the minimal diff — splice logic only requires containment.
    changeStart*: int
    changeEndOld*: int
    changeEndNew*: int
    delta*: int

func initBlock*(kind: BlockKind, range: Range, extensionID = ""): Block {.inline.} =
  Block(kind: kind, range: range, extensionID: extensionID)

func `==`*(a, b: Block): bool {.inline.} =
  a.kind == b.kind and a.range == b.range and a.extensionID == b.extensionID

func shifted*(b: Block, d: int): Block {.inline.} =
  Block(kind: b.kind, range: b.range.shifted(d), extensionID: b.extensionID)

# ---------------------------------------------------------------------------
# Line classification
# ---------------------------------------------------------------------------

func isBlankLine*(line: string): bool {.inline.} =
  trimWhitespaceAndNewlines(line).len == 0

func isFence*(line: string): bool {.inline.} =
  ## An opening or closing fence line: starts with three backticks.
  line.startsWith("```")

func isThematicBreak*(line: string): bool =
  ## `^\s*(-{3,}|\*{3,}|_{3,})\s*$` — a solid run of 3+ of one of `- * _`.
  let t = trimWhitespaceAndNewlines(line)
  if t.len < 3: return false
  let first = t[0]
  if first != '-' and first != '*' and first != '_': return false
  for ch in t:
    if ch != first: return false
  true

func isHeadingLine*(line: string): bool =
  ## `^\s*#{1,6} +…` — 1–6 hashes after optional indent, then at least one
  ## space.
  var i = 0
  while i < line.len and (line[i] == ' ' or line[i] == '\t'): inc i
  var hashes = 0
  while i < line.len and line[i] == '#':
    inc hashes
    inc i
  if hashes < 1 or hashes > 6: return false
  i < line.len and line[i] == ' '

func isBlockquoteLine*(line: string): bool =
  ## `^[ \t]{0,3}>…` — up to 3 leading spaces/tabs, then a `>`.
  var i = 0
  var indent = 0
  while indent < 3 and i < line.len and (line[i] == ' ' or line[i] == '\t'):
    inc i
    inc indent
  i < line.len and line[i] == '>'

func isListItem*(line: string): bool =
  ## A list-item line: optional indent, a bullet (`-`/`*`/`+`) or ordered
  ## marker (`1.`/`1)`), then a space/tab. A bare `-`/`*`/`1.` stays literal.
  var i = 0
  while i < line.len and (line[i] == ' ' or line[i] == '\t'): inc i
  if i >= line.len: return false
  let first = line[i]
  if first == '-' or first == '*' or first == '+':
    inc i
  elif first in {'0' .. '9'}:
    var digits = 0
    while i < line.len and line[i] in {'0' .. '9'} and digits < 9:
      inc i
      inc digits
    if i >= line.len: return false
    if line[i] != '.' and line[i] != ')': return false
    inc i
  else:
    return false
  if i >= line.len: return false
  line[i] == ' ' or line[i] == '\t'

func isTableRow*(line: string): bool =
  ## `^[ \t]*\|.+\|[ \t]*$` — outer pipes, content between.
  let t = trimWhitespaceAndNewlines(line)
  t.len >= 3 and t.startsWith("|") and t.endsWith("|")

func isTableSeparator*(line: string): bool =
  ## `^[ \t]*\|[- \t:|]+\|[ \t]*$` — only `- : |` + whitespace inside.
  let t = trimWhitespaceAndNewlines(line)
  if t.len < 3 or not t.startsWith("|") or not t.endsWith("|"): return false
  let middle = t[1 ..< t.len - 1]
  if middle.len == 0: return false
  for ch in middle:
    if ch notin {'-', ':', '|', ' ', '\t'}: return false
  true

func isBlockLatexOpen*(line: string): bool {.inline.} =
  ## A block-LaTeX opener: a line whose content starts with `$$`.
  trimWhitespaceAndNewlines(line).startsWith("$$")

# ---------------------------------------------------------------------------
# Full parse
# ---------------------------------------------------------------------------

func unionOf(lines: seq[Range], first, last: int): Range {.inline.} =
  rng(lines[first].location, maxRange(lines[last]) - lines[first].location)

proc computeBlocks*(t: Utf16Text, registry = emptyRegistry()): seq[Block] =
  let length = t.len
  if length == 0: return @[]

  # 1. Slice into physical lines (each includes its trailing newline).
  var lines: seq[Range] = @[]
  var cursor = 0
  while cursor < length:
    let r = t.lineRange(caretAt(cursor))
    if r.length <= 0: break
    lines.add r
    cursor = maxRange(r)

  var lineTexts = newSeq[string](lines.len)
  for i in 0 ..< lines.len:
    lineTexts[i] = t.substring(lines[i])

  template lineText(i: int): string = lineTexts[i]

  proc fenceCloseIndex(start: int): int =
    ## Line index of the fence closing a code block opened at `start`; -1 when
    ## unclosed.
    var scan = start + 1
    while scan < lineTexts.len:
      if isFence(lineTexts[scan]): return scan
      inc scan
    -1

  proc blockLatexCloseIndex(start: int): int =
    ## Line index of the `$$` closing a block-LaTeX run opened at `start`;
    ## -1 if none.
    let open = trimWhitespaceAndNewlines(lineTexts[start])
    if open.len > 2 and open[2 .. ^1].contains("$$"): return start
    var j = start + 1
    while j < lineTexts.len:
      if lineTexts[j].contains("$$"): return j
      inc j
    -1

  # 2. Classify + group.
  var i = 0
  while i < lines.len:
    let line = lineText(i)

    if isBlankLine(line):
      var stop = i
      while stop + 1 < lines.len and isBlankLine(lineText(stop + 1)): inc stop
      result.add initBlock(bkBlank, unionOf(lines, i, stop))
      i = stop + 1

    elif isFence(line) and fenceCloseIndex(i) >= 0:
      let stop = fenceCloseIndex(i)
      result.add initBlock(bkFencedCode, unionOf(lines, i, stop))
      i = stop + 1

    elif isThematicBreak(line):
      result.add initBlock(bkThematicBreak, lines[i])
      inc i

    elif isHeadingLine(line):
      result.add initBlock(bkHeading, lines[i])
      inc i

    elif isBlockquoteLine(line):
      var stop = i
      while stop + 1 < lines.len and isBlockquoteLine(lineText(stop + 1)): inc stop
      result.add initBlock(bkBlockquote, unionOf(lines, i, stop))
      i = stop + 1

    elif isListItem(line):
      # Consecutive list-item lines form one list block; per-item detail is
      # parsed in `ast.nim`.
      var stop = i
      while stop + 1 < lines.len and isListItem(lineText(stop + 1)): inc stop
      result.add initBlock(bkList, unionOf(lines, i, stop))
      i = stop + 1

    elif isTableRow(line) and i + 1 < lines.len and isTableSeparator(lineText(i + 1)):
      # GFM table: a `|…|` header, a `|-…-|` separator, then data rows.
      var stop = i + 1
      while stop + 1 < lines.len and isTableRow(lineText(stop + 1)): inc stop
      result.add initBlock(bkTable, unionOf(lines, i, stop))
      i = stop + 1

    elif isBlockLatexOpen(line) and blockLatexCloseIndex(i) >= 0:
      # Block LaTeX `$$…$$` — a single line or a `$$`-delimited run.
      let stop = blockLatexCloseIndex(i)
      result.add initBlock(bkBlockLatex, unionOf(lines, i, stop))
      i = stop + 1

    else:
      let (entry, isExt) = registry.blockEntryOpening(line)
      if isExt:
        # Extension fenced block: consume through the closing fence line (or to
        # EOF if none) — mirrors ``` semantics. Built-ins classify first, so a
        # fence colliding with a built-in line form never reaches here.
        var stop = lines.len - 1
        var scan = i + 1
        while scan < lines.len:
          if lineText(scan).startsWith(entry.fence):
            stop = scan
            break
          inc scan
        result.add initBlock(bkExt, unionOf(lines, i, stop), entry.id)
        i = stop + 1
      else:
        # Paragraph: merge consecutive plain (non-blank, non-special) lines.
        var stop = i
        while stop + 1 < lines.len:
          let nextLine = lineText(stop + 1)
          if isBlankLine(nextLine) or isThematicBreak(nextLine) or
             isHeadingLine(nextLine) or isBlockquoteLine(nextLine) or
             isListItem(nextLine):
            break
          # A table (row + separator), a CLOSED code fence, a block-LaTeX run,
          # or an extension fence interrupts it — an unclosed opener stays part
          # of the paragraph.
          if isFence(nextLine) and fenceCloseIndex(stop + 1) >= 0: break
          if isTableRow(nextLine) and stop + 2 < lines.len and
             isTableSeparator(lineText(stop + 2)): break
          if isBlockLatexOpen(nextLine) and blockLatexCloseIndex(stop + 1) >= 0: break
          if registry.blockEntryOpening(nextLine)[1]: break
          inc stop
        result.add initBlock(bkParagraph, unionOf(lines, i, stop))
        i = stop + 1

proc computeBlocks*(text: string, registry = emptyRegistry()): seq[Block] {.inline.} =
  computeBlocks(initText(text), registry)

# ---------------------------------------------------------------------------
# Incremental parse
# ---------------------------------------------------------------------------

func scanDiff*(old, new: seq[uint16]): (BufferDiff, bool) =
  ## Common prefix/suffix scan; `false` when the buffers are identical.
  let oldLen = old.len
  let newLen = new.len
  var p = 0
  let maxPre = min(oldLen, newLen)
  while p < maxPre and old[p] == new[p]: inc p
  if p == oldLen and oldLen == newLen: return (BufferDiff(), false)
  var s = 0
  let maxSuf = maxPre - p
  while s < maxSuf and old[oldLen - 1 - s] == new[newLen - 1 - s]: inc s
  (BufferDiff(changeStart: p, changeEndOld: oldLen - s, changeEndNew: newLen - s,
              delta: newLen - oldLen), true)

func hasBlockDelimiter*(buf: seq[uint16], lo, hi: int,
                        fences: seq[seq[uint16]] = @[]): bool =
  ## Does any LINE touched by `[lo, hi)` contain a `$$` or ``` that can ripple?
  ##
  ## Line-expanded, not just ±3 around the edit: block delimiters are
  ## line-classified with a TRIMMED prefix, so editing the leading whitespace
  ## of an indented `$$` opener flips the pairing from arbitrarily far away
  ## from the literal `$$`. The boundary walk is capped; hitting the cap
  ## reports a delimiter (conservative full parse).
  const cap = 4096
  var start = max(0, lo - 3)
  var steps = 0
  while start > 0 and buf[start - 1] != chLF and buf[start - 1] != chCR:
    dec start
    inc steps
    if steps > cap: return true
  var stop = min(buf.len, hi + 3)
  steps = 0
  while stop < buf.len and buf[stop] != chLF and buf[stop] != chCR:
    inc stop
    inc steps
    if steps > cap: return true
  var i = start
  while i < stop:
    if buf[i] == chDollar:
      if i + 1 < stop and buf[i + 1] == chDollar: return true          # $$
    elif buf[i] == chBacktick and i + 2 < stop and
         buf[i + 1] == chBacktick and buf[i + 2] == chBacktick:
      return true                                                       # ```
    # Extension fences pair with a distant partner exactly like ``` — an edit
    # touching one must force the full reparse too.
    for fence in fences:
      if fence.len > 0 and buf[i] == fence[0] and i + fence.len <= stop:
        var match = true
        for k in 0 ..< fence.len:
          if buf[i + k] != fence[k]:
            match = false
            break
        if match: return true
    inc i
  false

proc incrementalParse*(oldChars: seq[uint16], oldBlocks: seq[Block],
                       newChars: seq[uint16], newText: Utf16Text,
                       diff: BufferDiff,
                       registry = emptyRegistry()): (seq[Block], int, bool) =
  ## Splice-parse against a precomputed change region: reparse the affected
  ## block window, splice between untouched prefix/suffix. The third element is
  ## `false` to fall back to a full parse.
  if oldBlocks.len == 0: return (@[], 0, false)
  let oldLen = oldChars.len
  let newLen = newChars.len
  if oldLen == 0 or newLen == 0: return (@[], 0, false)

  let delta = diff.delta
  let changeStart = diff.changeStart
  let changeEnd = diff.changeEndOld       # [changeStart, changeEnd) in old
  if changeStart < 0 or changeEnd > oldLen or diff.changeEndNew > newLen or
     changeStart > changeEnd or changeStart > diff.changeEndNew:
    return (@[], 0, false)

  # A fence/block-LaTeX/extension delimiter in the edit can pair with a distant
  # partner → full reparse.
  let fences = registry.fenceCharsList()
  if hasBlockDelimiter(oldChars, changeStart, changeEnd, fences) or
     hasBlockDelimiter(newChars, changeStart, diff.changeEndNew, fences):
    return (@[], 0, false)

  # Affected old-block window (±1 block margin for merges/splits). Blocks tile
  # the document in order — binary search instead of the linear walks that cost
  # O(#blocks) per keystroke in large documents.
  var lo = 0
  var hi = oldBlocks.len - 1
  while lo < hi:                        # last block starting <= changeStart
    let m = (lo + hi + 1) div 2
    if oldBlocks[m].range.location <= changeStart: lo = m else: hi = m - 1
  let firstIdx = lo
  lo = 0
  hi = oldBlocks.len - 1
  while lo < hi:                        # first block ending >= changeEnd
    let m = (lo + hi) div 2
    if maxRange(oldBlocks[m].range) >= changeEnd: hi = m else: lo = m + 1
  let lastIdx = lo
  let winFirst = max(0, min(firstIdx, lastIdx) - 1)
  let winLast = min(oldBlocks.len - 1, max(firstIdx, lastIdx) + 1)

  # Opaque multi-line blocks (fences / block LaTeX) in the window are fine for
  # INTERIOR edits: the window contains each block wholly, the delimiter guard
  # above already bailed on any edit that creates, destroys or touches a
  # ``` / `$$` pairing, and an edit that UN-closes a block makes the reparsed
  # block reach the window end — caught by the trailing guard below.

  # Window → new-text range (window start is before the edit → unchanged).
  let winStart = oldBlocks[winFirst].range.location
  let winEndNew = maxRange(oldBlocks[winLast].range) + delta
  if winStart < 0 or winEndNew < winStart or winEndNew > newLen:
    return (@[], 0, false)

  # Reparse just the window substring, shift to absolute new coords.
  let windowText = newText.substring(rng(winStart, winEndNew - winStart))
  var reparsed: seq[Block] = @[]
  for b in computeBlocks(windowText, registry):
    reparsed.add b.shifted(winStart)

  # A trailing fence/latex/extension block reaching the window end might
  # continue past it.
  if reparsed.len > 0:
    let last = reparsed[^1]
    if maxRange(last.range) >= winEndNew:
      case last.kind
      of bkFencedCode, bkBlockLatex, bkExt:
        return (@[], 0, false)
      of bkParagraph:
        # The edit may have dissolved the separator that used to end this
        # paragraph (backspace-joining two paragraphs): if the suffix ALSO
        # starts with a paragraph, the two would need to MERGE — a full parse
        # never yields adjacent paragraphs. The splice can't merge across the
        # cut, so fall back.
        if winLast + 1 < oldBlocks.len and oldBlocks[winLast + 1].kind == bkParagraph:
          return (@[], 0, false)
      else: discard

  # Splice: prefix (unchanged) + reparsed window + suffix (shifted).
  var spliced: seq[Block] = @[]
  for k in 0 ..< winFirst: spliced.add oldBlocks[k]
  spliced.add reparsed
  if winLast + 1 < oldBlocks.len:
    for k in winLast + 1 ..< oldBlocks.len:
      spliced.add oldBlocks[k].shifted(delta)

  # Validate gap-free tiling of [0, newLen); else full reparse.
  var tile = 0
  for b in spliced:
    if b.range.location != tile: return (@[], 0, false)
    tile = maxRange(b.range)
  if tile != newLen: return (@[], 0, false)
  (spliced, reparsed.len, true)

# ---------------------------------------------------------------------------
# Memoised entry point
# ---------------------------------------------------------------------------

var
  cachedChars: seq[uint16] = @[]
  cachedBlocks: seq[Block] = @[]
  cachedFingerprint = ""
  cacheValid = false

proc seedBlockCache*(chars: seq[uint16], blocks: seq[Block], fingerprint = "") =
  ## Adopt an externally computed parse (`DocumentParseState` publishes its
  ## per-keystroke result) so static-path callers take the memcmp hit instead
  ## of re-splicing against a one-keystroke-stale cache.
  cachedChars = chars
  cachedBlocks = blocks
  cachedFingerprint = fingerprint
  cacheValid = true

proc resetBlockCache*() =
  cachedChars = @[]
  cachedBlocks = @[]
  cachedFingerprint = ""
  cacheValid = false

proc parseBlocks*(t: Utf16Text, registry = emptyRegistry()): seq[Block] =
  ## Splits `t` into gap-free tiling blocks; memoises the last parse so both
  ## per-keystroke callers share one line scan.
  let newChars = t.units

  if cacheValid and cachedFingerprint == registry.fingerprint:
    # Identical text → memcmp hit (the scan below would walk O(doc)).
    if equalUnits(cachedChars, newChars):
      return cachedBlocks
    let (diff, changed) = scanDiff(cachedChars, newChars)
    if changed:
      let (incr, _, ok) = incrementalParse(cachedChars, cachedBlocks, newChars,
                                           t, diff, registry)
      if ok:
        cachedChars = newChars
        cachedBlocks = incr
        cachedFingerprint = registry.fingerprint
        cacheValid = true
        return incr

  let blocks = computeBlocks(t, registry)
  cachedChars = newChars
  cachedBlocks = blocks
  cachedFingerprint = registry.fingerprint
  cacheValid = true
  blocks

proc parseBlocks*(text: string, registry = emptyRegistry()): seq[Block] {.inline.} =
  parseBlocks(initText(text), registry)
