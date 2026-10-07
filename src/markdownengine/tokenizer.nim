## tokenizer.nim
## MarkdownEngine (Nim port)
##
## The live tokenization pipeline, fusing three Swift files:
## `BlockLevelTokenizer` (hand scanners for heading / blockquote / fenced code
## / table / block LaTeX / extension blocks), `InlineASTAdapter` (inline AST →
## flat tokens) and `BlockScopedTokenizer` (the memoised document walk).
##
## For each block from `block_parser`: block-level tokens come from the hand
## scanners, while ALL inline tokens come from the AST. Results are offset back
## into document coordinates. Fenced-code blocks emit only their code-block
## token (no inline markup inside).
##
## **Invariant:** the per-block memo (substring → block-relative tokens) means
## only the edited block re-parses — O(change). The document-level memo
## re-tokenizes only the touched blocks; the rest shift by the delta.

import std/[strutils, tables]
import ./ranges, ./utf16text, ./extension, ./token, ./inline_parser, ./block_parser

# ---------------------------------------------------------------------------
# Block-level hand scanners
# ---------------------------------------------------------------------------

func isWS(c: uint16): bool {.inline.} = c == chSpace or c == chTab

func lineBounds(s: Utf16Text, start: int): (int, int) =
  ## Content end (excludes trailing CR/LF) and next-line start for the line at
  ## `start`.
  let length = s.len
  var i = start
  while i < length and s.charAt(i) != chLF and s.charAt(i) != chCR: inc i
  let contentEnd = i
  if i < length and s.charAt(i) == chCR: inc i
  if i < length and s.charAt(i) == chLF: inc i
  (contentEnd, i)

func tokenizeHeading(s: Utf16Text): seq[MarkdownToken] =
  ## Legacy `^\s*(#{1,6}) +(.*)$`
  let length = s.len
  var i = 0
  while i < length and isWS(s.charAt(i)): inc i
  let hashStart = i
  while i < length and s.charAt(i) == chHash: inc i
  let hashEnd = i
  if hashEnd <= hashStart or hashEnd - hashStart > 6: return @[]
  if hashEnd >= length or s.charAt(hashEnd) != chSpace: return @[]
  var contentStart = hashEnd
  while contentStart < length and s.charAt(contentStart) == chSpace: inc contentStart
  let lineEnd = lineBounds(s, 0)[0]
  @[initToken(tkHeading, rng(hashStart, lineEnd - hashStart),
              rng(contentStart, max(0, lineEnd - contentStart)),
              @[rng(hashStart, hashEnd - hashStart), rng(hashEnd, 1)])]

func tokenizeBlockquote(s: Utf16Text): seq[MarkdownToken] =
  ## Legacy `^[ \t]{0,3}((?:>[ \t]?)+)(.*)$`, one token per line.
  let length = s.len
  var lineStart = 0
  while lineStart < length:
    let (contentEnd, nextStart) = lineBounds(s, lineStart)
    var i = lineStart
    var indent = 0
    while i < contentEnd and indent < 3 and isWS(s.charAt(i)):
      inc i
      inc indent
    let markerStart = i
    if i < contentEnd and s.charAt(i) == chGT:
      while i < contentEnd and s.charAt(i) == chGT:
        inc i
        if i < contentEnd and isWS(s.charAt(i)): inc i
      let markerEnd = i
      result.add initToken(tkBlockquote, rng(lineStart, contentEnd - lineStart),
                           rng(markerEnd, contentEnd - markerEnd),
                           @[rng(markerStart, markerEnd - markerStart)])
    if nextStart <= lineStart: break
    lineStart = nextStart

func tokenizeCodeBlock(s: Utf16Text): seq[MarkdownToken] =
  ## Legacy ```` ```lang\n…\n``` ````
  let length = s.len
  if length < 3: return @[]
  let afterOpenLine = lineBounds(s, 0)[1]
  var lineStart = afterOpenLine
  var closingStart = -1
  while lineStart < length:
    if lineStart + 3 <= length and s.charAt(lineStart) == chBacktick and
       s.charAt(lineStart + 1) == chBacktick and s.charAt(lineStart + 2) == chBacktick:
      closingStart = lineStart
      break
    let next = lineBounds(s, lineStart)[1]
    if next <= lineStart: break
    lineStart = next
  if closingStart < 0: return @[]   # no closing fence → legacy didn't match
  @[initToken(tkCodeBlock, rng(0, closingStart + 3),
              rng(afterOpenLine, closingStart - afterOpenLine),
              @[rng(0, afterOpenLine), rng(closingStart, 3)])]

func isTableRowUnits(s: Utf16Text, start, stop: int): bool =
  ## `^[ \t]*\|.+\|[ \t]*$` — a pipe, ≥1 char, a pipe (trailing ws allowed).
  var i = start
  while i < stop and isWS(s.charAt(i)): inc i
  if i >= stop or s.charAt(i) != chPipe: return false
  var j = stop
  while j > i and isWS(s.charAt(j - 1)): dec j
  if j - 1 <= i or s.charAt(j - 1) != chPipe: return false
  (j - 1) - (i + 1) >= 1

func isTableSeparatorUnits(s: Utf16Text, start, stop: int): bool =
  ## `^[ \t]*\|[- \t:|]+\|[ \t]*$` — outer pipes, inner only `- : | space tab`.
  var i = start
  while i < stop and isWS(s.charAt(i)): inc i
  if i >= stop or s.charAt(i) != chPipe: return false
  var j = stop
  while j > i and isWS(s.charAt(j - 1)): dec j
  if j - 1 <= i or s.charAt(j - 1) != chPipe: return false
  var k = i + 1
  var count = 0
  while k < j - 1:
    let c = s.charAt(k)
    if c != chDash and c != chSpace and c != chTab and c != chColon and c != chPipe:
      return false
    inc count
    inc k
  count >= 1

func tokenizeTable(s: Utf16Text): seq[MarkdownToken] =
  ## Legacy header `|…|` + separator `|-…-|` + data rows.
  let length = s.len
  var lineStart = 0
  while lineStart < length:
    let (contentEnd, nextStart) = lineBounds(s, lineStart)
    if isTableRowUnits(s, lineStart, contentEnd) and nextStart < length:
      let (sepEnd, afterSep) = lineBounds(s, nextStart)
      if isTableSeparatorUnits(s, nextStart, sepEnd):
        var rowEnd = sepEnd
        var cursor = afterSep
        while cursor < length:
          let (cEnd, cNext) = lineBounds(s, cursor)
          if not isTableRowUnits(s, cursor, cEnd): break
          rowEnd = cEnd
          if cNext <= cursor:
            cursor = cEnd
            break
          cursor = cNext
        result.add initToken(tkTable, rng(lineStart, rowEnd - lineStart),
                             rng(lineStart, rowEnd - lineStart), @[])
        lineStart = cursor
        continue
    if nextStart <= lineStart: break
    lineStart = nextStart

func tokenizeBlockLatex(s: Utf16Text): seq[MarkdownToken] =
  ## Legacy `(?s)(?<!\$)\$\$(.+?)\$\$`
  let length = s.len
  var i = 0
  while i + 1 < length:
    if s.charAt(i) == chDollar and s.charAt(i + 1) == chDollar:
      if i > 0 and s.charAt(i - 1) == chDollar:    # (?<!\$)
        inc i
        continue
      var j = i + 2
      var closeAt = -1
      while j + 1 < length:
        if s.charAt(j) == chDollar and s.charAt(j + 1) == chDollar and j > i + 2:
          closeAt = j
          break
        inc j
      if closeAt >= 0:
        result.add initToken(tkBlockLatex, rng(i, (closeAt + 2) - i),
                             rng(i + 2, closeAt - (i + 2)),
                             @[rng(i, 2), rng(closeAt, 2)])
        i = closeAt + 2
        continue
    inc i

func tokenizeExtensionBlock(s: Utf16Text, id, fence: string): seq[MarkdownToken] =
  ## Open fence line … closing fence line / EOF.
  let length = s.len
  if length == 0: return @[]
  let afterOpenLine = lineBounds(s, 0)[1]
  # Closing fence: the LAST line, when it starts with the fence (the block
  # parser guarantees no interior fence line).
  var closeStart = -1
  var closeEnd = -1
  if afterOpenLine < length and fence.len > 0:
    var lineStart = afterOpenLine
    while lineStart < length:
      let (contentEnd, next) = lineBounds(s, lineStart)
      if next >= length:
        if s.substring(rng(lineStart, contentEnd - lineStart)).startsWith(fence):
          closeStart = lineStart
          closeEnd = contentEnd
        break
      if next <= lineStart: break
      lineStart = next
  let contentEnd = if closeStart >= 0: closeStart else: length
  var markers = @[rng(0, afterOpenLine)]
  if closeStart >= 0: markers.add rng(closeStart, closeEnd - closeStart)
  @[initToken(tkExtensionBlock, rng(0, length),
              rng(afterOpenLine, max(0, contentEnd - afterOpenLine)),
              markers, id)]

proc blockLevelTokens*(kind: BlockKind, extensionID: string, sub: Utf16Text,
                       registry = emptyRegistry()): seq[MarkdownToken] =
  ## Block-level tokens for one block substring, dispatched by its kind.
  case kind
  of bkFencedCode: tokenizeCodeBlock(sub)
  of bkHeading: tokenizeHeading(sub)
  of bkBlockquote: tokenizeBlockquote(sub)
  of bkTable: tokenizeTable(sub)
  of bkBlockLatex: tokenizeBlockLatex(sub)
  of bkExt:
    let (entry, found) = registry.blockEntryFor(extensionID)
    tokenizeExtensionBlock(sub, extensionID, if found: entry.fence else: "")
  of bkParagraph, bkList, bkThematicBreak, bkBlank:
    # Safety-net table scan; tables and block LaTeX are their own blocks now,
    # and an inline `$$…$$` stays plain.
    tokenizeTable(sub)

# ---------------------------------------------------------------------------
# Inline AST → flat tokens
# ---------------------------------------------------------------------------

func between(markers: seq[Range]): Range {.inline.} =
  ## Content range between a `[open, close]` marker pair.
  let start = maxRange(markers[0])
  rng(start, markers[1].location - start)

proc appendInlineToken(node: InlineNode, acc: var seq[MarkdownToken]) =
  ## Walking the tree and emitting one token per markup node (recursing into
  ## children) reproduces the legacy tokenizer's flat, overlapping token set.
  ## `inText` nodes carry no token.
  case node.kind
  of inText:
    discard
  of inCode:
    let open = rng(node.range.location, node.contentRange.location - node.range.location)
    let close = rng(maxRange(node.contentRange),
                    maxRange(node.range) - maxRange(node.contentRange))
    acc.add initToken(tkInlineCode, node.range, node.contentRange, @[open, close])
  of inEmphasis:
    let kind = case node.emphasis
               of ekItalic: tkItalic
               of ekBold: tkBold
               of ekBoldItalic: tkBoldItalic
    acc.add initToken(kind, node.range, between(node.markers), node.markers)
    for child in node.children: appendInlineToken(child, acc)
  of inLink:
    acc.add initToken(tkLink, node.range, node.contentRange, node.markers)
    for child in node.children: appendInlineToken(child, acc)
  of inImage:
    acc.add initToken(tkImageLink, node.range, node.contentRange, node.markers)
  of inWikiLink:
    acc.add initToken(tkWikiLink, node.range, node.contentRange, node.markers)
  of inImageEmbed:
    acc.add initToken(tkImageEmbed, node.range, node.contentRange, node.markers)
  of inExt:
    acc.add initToken(tkExtensionSpan, node.range, node.contentRange,
                      node.markers, node.extensionID)
    for child in node.children: appendInlineToken(child, acc)
  of inInlineLatex:
    acc.add initToken(tkInlineLatex, node.range, node.contentRange, node.markers)
  of inEscape:
    acc.add initToken(tkBackslashEscape, node.range, node.contentRange, node.markers)

proc inlineTokens*(nodes: seq[InlineNode]): seq[MarkdownToken] =
  for node in nodes: appendInlineToken(node, result)

# ---------------------------------------------------------------------------
# Per-block memo
# ---------------------------------------------------------------------------

const blockTokenCacheCap = 4096

var
  blockTokenCache = initTable[string, seq[MarkdownToken]]()
  blockTokenOrder: seq[string] = @[]

proc resetBlockTokenCache*() =
  blockTokenCache.clear()
  blockTokenOrder = @[]

proc cachedBlockTokens*(kind: BlockKind, extensionID: string, sub: string,
                        registry = emptyRegistry()): seq[MarkdownToken] =
  ## Cached block-relative tokens for `sub`; a pure memo over the token logic.
  ## The key carries the registry fingerprint — the same text tokenizes
  ## differently under a different extension set.
  let key = if registry.fingerprint.len == 0: sub
            else: registry.fingerprint & "\x1F" & sub
  blockTokenCache.withValue(key, hit):
    return hit[]

  let subText = initText(sub)
  let blockLevel = blockLevelTokens(kind, extensionID, subText, registry)
  # Fenced code is opaque — no inline markup inside it. Extension blocks parse
  # inlines over their CONTENT only (the fence lines are syntax — a `$x$` in
  # the info string must not become a latex token).
  var inline: seq[MarkdownToken] = @[]
  if kind == bkFencedCode:
    discard
  elif kind == bkExt and blockLevel.len > 0:
    let content = blockLevel[0].contentRange
    if content.length > 0:
      inline = inlineTokens(parseInline(subText, content, registry))
  else:
    inline = inlineTokens(parseInline(sub, registry))

  let computed = blockLevel & inline
  if not blockTokenCache.hasKey(key):
    blockTokenCache[key] = computed
    blockTokenOrder.add key
    if blockTokenOrder.len > blockTokenCacheCap:
      let evicted = blockTokenOrder[0]
      blockTokenOrder.delete(0)
      blockTokenCache.del(evicted)
  computed

# ---------------------------------------------------------------------------
# Document-level walk
# ---------------------------------------------------------------------------

proc fullTokens*(blocks: seq[Block], t: Utf16Text,
                 registry = emptyRegistry()): seq[MarkdownToken] =
  for b in blocks:
    let delta = b.range.location
    for tok in cachedBlockTokens(b.kind, b.extensionID, t.substring(b.range), registry):
      result.add tok.shifted(delta)

proc incrementalTokens*(oldChars: seq[uint16], prevTokens: seq[MarkdownToken],
                        newChars: seq[uint16], blocks: seq[Block], t: Utf16Text,
                        diff: BufferDiff,
                        registry = emptyRegistry()): (seq[MarkdownToken], int, bool) =
  ## Reuse prefix/suffix tokens (suffix shifted) and re-tokenize only touched
  ## blocks, against a precomputed change region; `false` to fall back to full.
  let oldLen = oldChars.len
  let newLen = newChars.len
  if oldLen == 0 or newLen == 0 or blocks.len == 0: return (@[], 0, false)

  let delta = diff.delta
  let changeStart = diff.changeStart
  let changeEndNew = diff.changeEndNew
  if changeStart < 0 or diff.changeEndOld > oldLen or changeEndNew > newLen or
     changeStart > diff.changeEndOld or changeStart > changeEndNew:
    return (@[], 0, false)

  # A fence/block-LaTeX/extension delimiter can pair with a distant partner and
  # ripple far → full tokenization.
  let fences = registry.fenceCharsList()
  if hasBlockDelimiter(oldChars, changeStart, diff.changeEndOld, fences) or
     hasBlockDelimiter(newChars, changeStart, changeEndNew, fences):
    return (@[], 0, false)

  # New blocks touching the changed char range [changeStart, changeEndNew].
  # Blocks tile in order → the touching set is one contiguous run; binary
  # search replaces the O(#blocks) full scan per keystroke.
  var lo = 0
  var hi = blocks.len - 1
  while lo < hi:                        # first block ending >= changeStart
    let m = (lo + hi) div 2
    if maxRange(blocks[m].range) >= changeStart: hi = m else: lo = m + 1
  var first = lo
  lo = 0
  hi = blocks.len - 1
  while lo < hi:                        # last block starting <= changeEndNew
    let m = (lo + hi + 1) div 2
    if blocks[m].range.location <= changeEndNew: lo = m else: hi = m - 1
  var last = lo
  # Validate the run actually touches (mirrors the old filter exactly).
  if first > last or blocks[first].range.location > changeEndNew or
     maxRange(blocks[last].range) < changeStart:
    return if delta == 0: (prevTokens, 0, true) else: (@[], 0, false)
  lo = first
  hi = last

  # Widen the window until no previous token straddles either cut (a block's
  # extent can change in place).
  var expanded = true
  while expanded:
    expanded = false
    for tok in prevTokens:
      let cutStart = blocks[lo].range.location
      if tok.range.location < cutStart and maxRange(tok.range) > cutStart:
        while lo > 0 and blocks[lo].range.location > tok.range.location:
          dec lo
          expanded = true
      let cutEndOld = maxRange(blocks[hi].range) - delta
      if tok.range.location < cutEndOld and maxRange(tok.range) > cutEndOld:
        while hi < blocks.len - 1 and
              maxRange(blocks[hi].range) - delta < maxRange(tok.range):
          inc hi
          expanded = true

  let regionStart = blocks[lo].range.location
  let regionEndOld = maxRange(blocks[hi].range) - delta

  var acc: seq[MarkdownToken] = @[]
  for tok in prevTokens:                                   # prefix, unchanged
    if maxRange(tok.range) <= regionStart: acc.add tok
  for i in lo .. hi:                                       # window, retokenized
    let off = blocks[i].range.location
    for tok in cachedBlockTokens(blocks[i].kind, blocks[i].extensionID,
                                 t.substring(blocks[i].range), registry):
      acc.add tok.shifted(off)
  for tok in prevTokens:                                   # suffix, shifted
    if tok.range.location >= regionEndOld: acc.add tok.shifted(delta)
  (acc, hi - lo + 1, true)

var
  cachedTokenChars: seq[uint16] = @[]
  cachedTokens: seq[MarkdownToken] = @[]
  cachedTokenFingerprint = ""
  tokenCacheValid = false

proc seedTokenCache*(chars: seq[uint16], tokens: seq[MarkdownToken],
                     fingerprint = "") =
  ## Adopt an externally computed parse (`DocumentParseState` publishes its
  ## per-keystroke result) so static-path callers hit instead of re-splicing
  ## against a one-keystroke-stale cache.
  cachedTokenChars = chars
  cachedTokens = tokens
  cachedTokenFingerprint = fingerprint
  tokenCacheValid = true

proc resetTokenCache*() =
  cachedTokenChars = @[]
  cachedTokens = @[]
  cachedTokenFingerprint = ""
  tokenCacheValid = false

proc parseTokens*(t: Utf16Text, registry = emptyRegistry()): seq[MarkdownToken] =
  ## The live tokenizer: block-level tokens + inline AST tokens; fenced code
  ## emits only its code-block token.
  let newChars = t.units
  let blocks = parseBlocks(t, registry)

  if tokenCacheValid and cachedTokenFingerprint == registry.fingerprint:
    let (diff, changed) = scanDiff(cachedTokenChars, newChars)
    if not changed:
      return cachedTokens                                  # identical text
    let (incr, _, ok) = incrementalTokens(cachedTokenChars, cachedTokens,
                                          newChars, blocks, t, diff, registry)
    if ok:
      cachedTokenChars = newChars
      cachedTokens = incr
      cachedTokenFingerprint = registry.fingerprint
      tokenCacheValid = true
      return incr

  let full = fullTokens(blocks, t, registry)
  cachedTokenChars = newChars
  cachedTokens = full
  cachedTokenFingerprint = registry.fingerprint
  tokenCacheValid = true
  full

proc parseTokens*(text: string, registry = emptyRegistry()): seq[MarkdownToken] {.inline.} =
  parseTokens(initText(text), registry)
