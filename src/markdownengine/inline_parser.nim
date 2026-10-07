## inline_parser.nim
## MarkdownEngine (Nim port)
##
## The inline-structure pass. Given the text of a single inline-bearing block,
## it produces an inline AST node tree with correct CommonMark precedence.
##
## Ranges in the returned tree are relative to the parsed string; callers
## offset to document coordinates.
##
## Pipeline (each pass claims spans only in regions not already claimed, so
## there are never partial overlaps and `buildTree` is a clean containment
## tree):
##
## 1. `scanCodeSpans`  — highest precedence, opaque interior.
## 2. `scanEscapes`    — `\x` becomes a claimed span, so the escaped char is
##                       automatically inert for every pass below.
## 3. `scanLinkFamily` — `![[…]]`, `[[…]]`, `![…](…)`, `[…](…)`, `$…$` (+
##                       registered extension spans and directives) in
##                       precedence order. URLs allow balanced parens. A
##                       candidate overlapping a claimed span is rejected
##                       (kept literal), except for opaque spans wholly nested
##                       inside a Markdown link's label. This keeps `[x](y)`
##                       inert inside code while allowing valid labels such as
##                       ``[`x`](y)``.
## 4. `resolveEmphasis`— `*`/`_` delimiter runs over text outside every claimed
##                       span; may wrap claimed spans.
## 5. `buildTree`      — containment tree. Emphasis nests already-collected
##                       spans; link/extension-span content is re-parsed
##                       recursively; code/image/wiki/embed/latex/escape are
##                       opaque leaves.
##
## Claimed spans are therefore either disjoint or properly NESTED — a link
## label may hold one, nothing else may. That is load-bearing for cost as well
## as for correctness: the claimed-range probes and the containment tests are
## both linear in span count because of it, and `InlineParseCost` below counts
## them so the span-density tests can assert on a pure function of the input
## instead of on elapsed time.

import std/[algorithm, strutils]
import ./ranges, ./utf16text, ./extension, ./directive_scanner

type
  InlineParseCost* = object
    ## Work the claimed-range and containment scans did. Both quantities were
    ## quadratic in the spans per region before the ordered walk, and both are
    ## a pure function of the input — which is the point: identical on a laptop
    ## and on a loaded CI runner, and quadratic vs. linear differ by orders of
    ## magnitude rather than by 1.4x.
    claimedProbes*: int
    containmentTests*: int

  EmphasisKind* = enum
    ekItalic
    ekBold
    ekBoldItalic

  InlineNodeKind* = enum
    inText          ## `range` only
    inCode          ## `range` covers the backticks, `contentRange` strips single-space padding
    inEmphasis      ## `markers` is `[openMarker, closeMarker]`, `children` parsed
    inLink          ## `markers` is `[ "[", "]", "(", ")" ]`; text recursively parsed
    inImage         ## `markers` is `[ "![", "]", "(", ")" ]`; alt is opaque
    inWikiLink      ## `markers` is `[ "[[", "]]" ]`; `hasID` false when no `|`
    inImageEmbed    ## `markers` is `[ "![[", "]]" ]`
    inInlineLatex   ## `markers` is `[ "$", "$" ]`; opaque
    inEscape        ## `markers[0]` is the `\`, `contentRange` the literal char
    inExt           ## extension- or directive-contributed span

  InlineNode* = object
    ## One node of the inline AST.
    ##
    ## A flat record rather than a case object: most kinds share `range`,
    ## `markers` and `contentRange`, every consumer switches on `kind`, and the
    ## adapter / styler / HTML renderer all want uniform access to the shared
    ## geometry. Per-kind field usage is documented on `InlineNodeKind`.
    kind*: InlineNodeKind
    range*: Range
    contentRange*: Range
    urlRange*: Range
    idRange*: Range
    hasID*: bool
    markers*: seq[Range]
    emphasis*: EmphasisKind
    extensionID*: string
      ## For `inExt`: the extension id, or a `directive.`-prefixed node id.
    children*: seq[InlineNode]

func textNode*(r: Range): InlineNode {.inline.} =
  InlineNode(kind: inText, range: r)

func isDirectiveNode*(n: InlineNode): bool {.inline.} =
  n.kind == inExt and n.extensionID.startsWith(directiveIDPrefix)

# ---------------------------------------------------------------------------
# Span model (internal)
# ---------------------------------------------------------------------------

type
  SpanKind = enum
    spCode
    spEmphasis
    spLink
    spImage
    spWikiLink
    spImageEmbed
    spInlineLatex
    spEscape
    spExt

  Span = object
    kind: SpanKind
    fullRange: Range
    contentRange: Range
    urlRange: Range
    idRange: Range
    hasID: bool
    markers: seq[Range]
    emphasis: EmphasisKind
    extensionID: string
    parsesContent: bool

  ClaimedIndex = object
    ## The already-claimed ranges, in a form the later passes can consult in
    ## amortised constant time.
    ##
    ## Every pass that asks "is this claimed?" walks the string left to right
    ## and never looks back, and claimed ranges never PARTIALLY overlap (each
    ## pass only claims inside regions no earlier pass took). So a cursor over
    ## the sorted ranges answers without rescanning: the answer for index `i`
    ## only ever involves the first range that ends after `i`.
    ##
    ## A nested range (a code span inside a link label) sorts after its
    ## container, which already covers it, so `contains` stays correct without
    ## looking past the cursor. `overlapping` is the one query that must, and
    ## it peeks rather than advances.
    ranges: seq[Range]
    cursor: int
    probes: int

proc initClaimedIndex(spans: seq[Span]): ClaimedIndex =
  ## Sortedness is established here rather than assumed of callers, so no call
  ## site carries an ordering obligation.
  var rs = newSeqOfCap[Range](spans.len)
  for s in spans: rs.add s.fullRange
  rs.sort(proc (a, b: Range): int = cmp(a.location, b.location))
  ClaimedIndex(ranges: rs, cursor: 0, probes: 0)

proc advance(idx: var ClaimedIndex, i: int) =
  ## Discard ranges that end at or before `i`. `i` must not move backwards.
  while idx.cursor < idx.ranges.len and maxRange(idx.ranges[idx.cursor]) <= i:
    inc idx.cursor
    inc idx.probes

proc containsIndex(idx: var ClaimedIndex, i: int): bool =
  idx.advance(i)
  if idx.cursor >= idx.ranges.len: return false
  inc idx.probes
  contains(idx.ranges[idx.cursor], i)

proc overlaps(idx: var ClaimedIndex, r: Range): bool =
  idx.advance(r.location)
  if idx.cursor >= idx.ranges.len: return false
  inc idx.probes
  idx.ranges[idx.cursor].location < maxRange(r)

proc overlapping(idx: var ClaimedIndex, r: Range): seq[Range] =
  ## Every claimed range overlapping `r`. Peeks forward from the cursor without
  ## consuming, so the caller's left-to-right walk is unaffected.
  idx.advance(r.location)
  var k = idx.cursor
  while k < idx.ranges.len and idx.ranges[k].location < maxRange(r):
    if intersects(idx.ranges[k], r): result.add idx.ranges[k]
    inc k
    inc idx.probes

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func peek(t: Utf16Text, idx, length: int): (uint16, bool) {.inline.} =
  if idx >= 0 and idx < length: (t.charAt(idx), true) else: (0u16, false)

func isEscapedAt(t: Utf16Text, idx: int): bool =
  ## A character is backslash-escaped when preceded by an odd run of `\`.
  var count = 0
  var k = idx - 1
  while k >= 0 and t.charAt(k) == chBackslash:
    inc count
    dec k
  (count mod 2) == 1

func isWhitespaceOrBoundary(t: Utf16Text, idx, length: int): bool {.inline.} =
  if idx < 0 or idx >= length: return true
  let c = t.charAt(idx)
  c == chSpace or c == chTab or c == chLF or c == chCR

func isAsciiPunctuationAt(t: Utf16Text, idx, length: int): bool {.inline.} =
  if idx < 0 or idx >= length: return false
  isAsciiPunctuationUnit(t.charAt(idx))

# ---------------------------------------------------------------------------
# 1. Code spans
# ---------------------------------------------------------------------------

func strippedCodeContent(t: Utf16Text, raw: Range): Range =
  if raw.length < 2 or t.charAt(raw.location) != chSpace or
     t.charAt(maxRange(raw) - 1) != chSpace:
    return raw
  var allSpaces = true
  for k in raw.location ..< maxRange(raw):
    if t.charAt(k) != chSpace:
      allSpaces = false
      break
  if allSpaces: return raw
  rng(raw.location + 1, raw.length - 2)

func closingBacktickRun(t: Utf16Text, start, length, runLen: int): int =
  var k = start
  while k < length:
    if t.charAt(k) != chBacktick or isEscapedAt(t, k):
      inc k
      continue
    let runStart = k
    while k < length and t.charAt(k) == chBacktick: inc k
    if k - runStart == runLen: return runStart
  -1

func scanCodeSpans(t: Utf16Text, length: int): seq[Span] =
  var i = 0
  while i < length:
    if t.charAt(i) != chBacktick or isEscapedAt(t, i):
      inc i
      continue
    let runStart = i
    var j = i
    while j < length and t.charAt(j) == chBacktick: inc j
    let runLen = j - runStart
    let close = closingBacktickRun(t, j, length, runLen)
    if close < 0:
      i = j
      continue
    let codeRange = rng(runStart, (close + runLen) - runStart)
    let rawContent = rng(j, close - j)
    result.add Span(kind: spCode, fullRange: codeRange,
                    contentRange: strippedCodeContent(t, rawContent))
    i = close + runLen

# ---------------------------------------------------------------------------
# 2. Backslash escapes (claimed → escaped chars are inert everywhere)
# ---------------------------------------------------------------------------

proc scanEscapes(t: Utf16Text, length: int, claimed: var ClaimedIndex): seq[Span] =
  var i = 0
  while i < length - 1:
    if t.charAt(i) == chBackslash and not claimed.containsIndex(i) and
       isAsciiPunctuationUnit(t.charAt(i + 1)):
      result.add Span(kind: spEscape, fullRange: rng(i, 2),
                      contentRange: rng(i + 1, 1), markers: @[rng(i, 1)])
      i += 2   # the escaped char can't itself start a new escape (even/odd `\\`)
    else:
      inc i

# ---------------------------------------------------------------------------
# 3. Link family / inline LaTeX / extension spans / directives
# ---------------------------------------------------------------------------

func findChar(t: Utf16Text, length, start: int, ch: uint16): int =
  var k = start
  while k < length:
    let c = t.charAt(k)
    if c == ch: return k
    if c == chLF: return -1
    inc k
  -1

func balancedParen(t: Utf16Text, length, start: int): int =
  var depth = 1
  var k = start
  while k < length:
    let c = t.charAt(k)
    if c == chLF: return -1
    if c == chLParen: inc depth
    elif c == chRParen:
      dec depth
      if depth == 0: return k
    inc k
  -1

func closeDoubleBracket(t: Utf16Text, length, start: int): int =
  var k = start
  while k < length:
    let c = t.charAt(k)
    if c == chLF: return -1
    if c == chRBracket:
      let (nxt, ok) = peek(t, k + 1, length)
      return if ok and nxt == chRBracket: k else: -1
    inc k
  -1

func isCurrencyLike(s: string): bool =
  ## A plain signed/thousands-grouped/decimal number (`50`, `1,000.50`, `-5`),
  ## regex-free, so currency isn't math.
  let u = toUtf16(s)
  let n = u.len
  template digit(x: int): bool = x >= 0 and x < n and u[x] >= 0x30u16 and u[x] <= 0x39u16
  var i = 0
  if i < n and (u[i] == chPlus or u[i] == chDash): inc i
  if not digit(i): return false
  var sawDigit = false
  while i < n:
    if digit(i):
      sawDigit = true
      inc i
    elif u[i] == chComma and digit(i + 1) and digit(i + 2) and digit(i + 3) and
         not digit(i + 4):
      i += 4   # a strict `,DDD` thousands group
    else:
      break
  if not sawDigit: return false
  if i < n and u[i] == chDot:          # optional `.DDD+`
    inc i
    if not digit(i): return false
    while digit(i): inc i
  i == n

func mathyCharCount(s: string): int =
  ## Count of "mathy" characters `\ ^ _ { } = + - * / < >`.
  const mathy = [chBackslash, chCaret, chUnderscore, chLBrace, chRBrace, chEq,
                 chPlus, chDash, chAsterisk, chSlash, chLT, chGT]
  for u in toUtf16(s):
    if u in mathy: inc result

func isAllAsciiLetters(s: string): bool =
  let u = toUtf16(s)
  if u.len == 0: return false
  for x in u:
    if not isAsciiLetter(x): return false
  true

func isInlineMathContent(content: string): bool =
  ## Rejects currency-looking and trivially short non-mathy `$…$` so prose
  ## isn't misread as math.
  let trimmed = trimWhitespaceAndNewlines(content)
  if trimmed.len == 0: return false
  if isCurrencyLike(trimmed): return false
  let mathyMatches = mathyCharCount(trimmed)
  if mathyMatches == 0:
    return utf16Len(trimmed) <= 3 and isAllAsciiLetters(trimmed)
  var tokenCount = 0
  for token in trimmed.splitWhitespace():
    if token.len > 0: inc tokenCount
  if mathyMatches >= 3: return tokenCount <= 120
  if mathyMatches == 2: return tokenCount <= 40
  tokenCount <= 6

func matchImageEmbed(t: Utf16Text, length, i: int): (Span, bool) =
  ## `![[ target ]]`
  let contentStart = i + 3
  let close = closeDoubleBracket(t, length, contentStart)
  if close < 0: return (Span(), false)
  (Span(kind: spImageEmbed, fullRange: rng(i, (close + 2) - i),
        contentRange: rng(contentStart, close - contentStart),
        markers: @[rng(i, 3), rng(close, 2)]), true)

func matchWikiLink(t: Utf16Text, length, i: int): (Span, bool) =
  ## `[[ name (| id)? ]]`
  let contentStart = i + 2
  var k = contentStart
  var pipeIdx = -1
  while k < length:
    let c = t.charAt(k)
    if c == chLF: return (Span(), false)
    if c == chPipe and pipeIdx == -1: pipeIdx = k
    if c == chRBracket:
      let (nxt, ok) = peek(t, k + 1, length)
      if not ok or nxt != chRBracket: return (Span(), false)
      let full = rng(i, (k + 2) - i)
      let markers = @[rng(i, 2), rng(k, 2)]
      if pipeIdx >= 0:
        return (Span(kind: spWikiLink, fullRange: full,
                     contentRange: rng(contentStart, pipeIdx - contentStart),
                     idRange: rng(pipeIdx + 1, k - (pipeIdx + 1)), hasID: true,
                     markers: markers), true)
      return (Span(kind: spWikiLink, fullRange: full,
                   contentRange: rng(contentStart, k - contentStart),
                   hasID: false, markers: markers), true)
    inc k
  (Span(), false)

func matchImage(t: Utf16Text, length, i: int): (Span, bool) =
  ## `![ alt ]( url )`
  let altStart = i + 2
  let closeBracket = findChar(t, length, altStart, chRBracket)
  if closeBracket < 0: return (Span(), false)
  let (afterBracket, ok) = peek(t, closeBracket + 1, length)
  if not ok or afterBracket != chLParen: return (Span(), false)
  let closeParen = balancedParen(t, length, closeBracket + 2)
  if closeParen < 0: return (Span(), false)
  let urlStart = closeBracket + 2
  if closeParen <= urlStart: return (Span(), false)
  (Span(kind: spImage, fullRange: rng(i, (closeParen + 1) - i),
        contentRange: rng(altStart, closeBracket - altStart),
        urlRange: rng(urlStart, closeParen - urlStart),
        markers: @[rng(i, 2), rng(closeBracket, 1), rng(closeBracket + 1, 1),
                   rng(closeParen, 1)]), true)

func matchLink(t: Utf16Text, length, i: int): (Span, bool) =
  ## `[ text ]( url )`
  let textStart = i + 1
  let closeBracket = findChar(t, length, textStart, chRBracket)
  if closeBracket < 0 or closeBracket <= textStart: return (Span(), false)
  let (afterBracket, ok) = peek(t, closeBracket + 1, length)
  if not ok or afterBracket != chLParen: return (Span(), false)
  let closeParen = balancedParen(t, length, closeBracket + 2)
  if closeParen < 0: return (Span(), false)
  let urlStart = closeBracket + 2
  if closeParen <= urlStart: return (Span(), false)
  (Span(kind: spLink, fullRange: rng(i, (closeParen + 1) - i),
        contentRange: rng(textStart, closeBracket - textStart),
        urlRange: rng(urlStart, closeParen - urlStart),
        markers: @[rng(i, 1), rng(closeBracket, 1), rng(closeBracket + 1, 1),
                   rng(closeParen, 1)]), true)

func matchInlineLatex(t: Utf16Text, length, i: int): (Span, bool) =
  ## `$ math $` — single dollars, content has no `$`, passes the math heuristic.
  if i > 0 and t.charAt(i - 1) == chDollar: return (Span(), false)
  let contentStart = i + 1
  var k = contentStart
  while k < length:
    let c = t.charAt(k)
    if c == chLF: return (Span(), false)
    if c == chDollar:
      let (nxt, hasNext) = peek(t, k + 1, length)
      if k <= contentStart or (hasNext and nxt == chDollar): return (Span(), false)
      let content = rng(contentStart, k - contentStart)
      if not isInlineMathContent(t.substring(content)): return (Span(), false)
      return (Span(kind: spInlineLatex, fullRange: rng(i, (k + 1) - i),
                   contentRange: content,
                   markers: @[rng(i, 1), rng(k, 1)]), true)
    inc k
  (Span(), false)

func matchBuiltIn(t: Utf16Text, length, i: int): (Span, bool) =
  ## The built-in constructs, tried exclusively in fixed precedence order — the
  ## first branch whose trigger matches decides (no match = stays literal for
  ## built-ins).
  let c = t.charAt(i)
  let (c1, _) = peek(t, i + 1, length)
  let (c2, _) = peek(t, i + 2, length)
  if c == chBang and c1 == chLBracket and c2 == chLBracket:
    return matchImageEmbed(t, length, i)
  if c == chLBracket and c1 == chLBracket:
    return matchWikiLink(t, length, i)
  if c == chBang and c1 == chLBracket:
    return matchImage(t, length, i)
  if c == chLBracket:
    return matchLink(t, length, i)
  if c == chDollar and c1 != chDollar:
    return matchInlineLatex(t, length, i)
  (Span(), false)

func matchExtensionSpan(t: Utf16Text, length, i: int,
                        entry: ExtensionEntry): (Span, bool) =
  ## Generic scanner for extension-contributed delimited spans. Mirrors the
  ## built-in `~~`/`==` semantics: the span opens at an exact `open` match,
  ## closes at the FIRST exact `close` match on the same line, and a lone
  ## occurrence of `close`'s first character inside the content aborts the
  ## candidate (it stays literal).
  let open = entry.open
  let close = entry.close
  if open.len == 0 or close.len == 0: return (Span(), false)
  if not matchesAt(t, i, open): return (Span(), false)
  if entry.syntax.rejectsOpenerRun and i > 0 and t.charAt(i - 1) == open[0]:
    return (Span(), false)

  let contentStart = i + open.len
  let closeFirst = close[0]
  var k = contentStart
  while k < length:
    let ch = t.charAt(k)
    if ch == chLF: return (Span(), false)
    if ch == closeFirst:
      if not matchesAt(t, k, close): return (Span(), false)
      if entry.syntax.requiresNonEmptyContent and k == contentStart:
        return (Span(), false)
      if entry.syntax.rejectsCloserRun:
        let (after, ok) = peek(t, k + close.len, length)
        if ok and after == close[close.len - 1]: return (Span(), false)
      return (Span(kind: spExt, fullRange: rng(i, (k + close.len) - i),
                   contentRange: rng(contentStart, k - contentStart),
                   markers: @[rng(i, open.len), rng(k, close.len)],
                   extensionID: entry.id,
                   parsesContent: entry.syntax.parsesContent), true)
    inc k
  (Span(), false)

proc matchClaimedSpan(t: Utf16Text, length, i: int,
                      registry: ExtensionRegistry): (Span, bool) =
  let (builtIn, ok) = matchBuiltIn(t, length, i)
  if ok: return (builtIn, true)

  # Directives match after every built-in and BEFORE the extension loop, on
  # the same terms as extension spans: registered names only, and a rejection
  # leaves the candidate literal. The ordering is deliberate — a directive is a
  # named construct with a boundary rule, so it can't be ambiguous with an
  # extension's delimiters unless an extension opens with the directive
  # marker, in which case the directive wins. They project into the AST as
  # extension-shaped nodes under a reserved id namespace, so marker shrink,
  # caret reveal, token projection, and rich copy all apply unchanged.
  #
  # The emptiness test is HOISTED here rather than left to the identical guard
  # inside `matchDirective`: this runs per unclaimed character, and a document
  # registering NO directives must not pay for a feature it never turned on.
  if not registry.directives.isEmpty:
    let (m, matched) = matchDirective(t, length, i, registry.directives)
    if matched:
      return (Span(kind: spExt, fullRange: m.range, contentRange: m.contentRange,
                   markers: m.markers, extensionID: m.nodeID,
                   parsesContent: m.parsesContent), true)

  # Extensions match after every built-in, in registration order. A built-in
  # trigger that matched-and-FAILED (e.g. `$50$` rejected by the math
  # heuristic) falls through here, so an extension sharing a built-in's first
  # character is still reachable.
  let c = t.charAt(i)
  for entry in registry.entries:
    if entry.open.len > 0 and entry.open[0] == c:
      let (span, matched) = matchExtensionSpan(t, length, i, entry)
      if matched: return (span, true)
  (Span(), false)

proc scanLinkFamily(t: Utf16Text, length: int, claimed: var ClaimedIndex,
                    registry: ExtensionRegistry): seq[Span] =
  # A candidate overlapping a claimed span is rejected, except for spans wholly
  # nested inside a Markdown link's label. Only that case needs the full
  # overlap list; everything else short-circuits on the first one.
  proc hasDisallowedClaimedOverlap(claimed: var ClaimedIndex, span: Span): bool =
    if span.kind != spLink:
      return claimed.overlaps(span.fullRange)
    for r in claimed.overlapping(span.fullRange):
      if not containsRange(span.contentRange, r): return true
    false

  var i = 0
  while i < length:
    if claimed.containsIndex(i):
      inc i
      continue
    let (span, matched) = matchClaimedSpan(t, length, i, registry)
    if matched and not hasDisallowedClaimedOverlap(claimed, span):
      result.add span
      i = maxRange(span.fullRange)
    else:
      inc i

# ---------------------------------------------------------------------------
# 4. Emphasis (delimiter runs)
# ---------------------------------------------------------------------------

type
  DelimRun = object
    ch: uint16
    originalLength: int
    leftEdge: int
    rightEdge: int
    canOpen: bool
    canClose: bool
    lineIdx: int

func remaining(r: DelimRun): int {.inline.} = r.rightEdge - r.leftEdge

proc collectDelimiterRuns(t: Utf16Text, length: int,
                          claimed: var ClaimedIndex): seq[DelimRun] =
  var lineIdx = 0
  var i = 0
  while i < length:
    let c = t.charAt(i)
    if c == chLF:
      inc lineIdx
      inc i
      continue
    if (c != chAsterisk and c != chUnderscore) or claimed.containsIndex(i):
      inc i
      continue
    var j = i
    while j < length and t.charAt(j) == c: inc j

    let before = i - 1
    let after = j
    let beforeWs = isWhitespaceOrBoundary(t, before, length)
    let beforePunct = isAsciiPunctuationAt(t, before, length)
    let afterWs = isWhitespaceOrBoundary(t, after, length)
    let afterPunct = isAsciiPunctuationAt(t, after, length)
    let leftFlanking = (not afterWs) and ((not afterPunct) or beforeWs or beforePunct)
    let rightFlanking = (not beforeWs) and ((not beforePunct) or afterWs or afterPunct)

    var canOpen, canClose: bool
    if c == chUnderscore:
      canOpen = leftFlanking and ((not rightFlanking) or beforePunct)
      canClose = rightFlanking and ((not leftFlanking) or afterPunct)
    else:
      canOpen = leftFlanking
      canClose = rightFlanking
    result.add DelimRun(ch: c, originalLength: j - i, leftEdge: i, rightEdge: j,
                        canOpen: canOpen, canClose: canClose, lineIdx: lineIdx)
    i = j

proc closeAgainstStack(closerIdx: int, runs: var seq[DelimRun],
                       stack: var seq[int], spans: var seq[Span]) =
  var sp = stack.len - 1
  while sp >= 0 and runs[closerIdx].remaining > 0:
    let openerIdx = stack[sp]
    if runs[openerIdx].ch != runs[closerIdx].ch:
      dec sp
      continue
    if runs[openerIdx].lineIdx != runs[closerIdx].lineIdx:
      stack.delete(sp)
      dec sp
      continue
    let avail = min(runs[openerIdx].remaining, runs[closerIdx].remaining)
    if avail == 0:
      stack.delete(sp)
      dec sp
      continue

    let openerBoth = runs[openerIdx].canOpen and runs[openerIdx].canClose
    let closerBoth = runs[closerIdx].canOpen and runs[closerIdx].canClose
    if openerBoth or closerBoth:
      let sum = runs[openerIdx].originalLength + runs[closerIdx].originalLength
      let bothMod3 = (runs[openerIdx].originalLength mod 3) == 0 and
                     (runs[closerIdx].originalLength mod 3) == 0
      if (sum mod 3) == 0 and not bothMod3:
        dec sp
        continue

    let matchLen = if avail >= 3: 3 elif avail >= 2: 2 else: 1
    let openerMarkerStart = runs[openerIdx].rightEdge - matchLen
    let closerMarkerStart = runs[closerIdx].leftEdge
    let kind = if matchLen == 3: ekBoldItalic
               elif matchLen == 2: ekBold
               else: ekItalic

    spans.add Span(kind: spEmphasis, emphasis: kind,
                   fullRange: rng(openerMarkerStart,
                                  (closerMarkerStart + matchLen) - openerMarkerStart),
                   markers: @[rng(openerMarkerStart, matchLen),
                              rng(closerMarkerStart, matchLen)])

    runs[openerIdx].rightEdge -= matchLen
    runs[closerIdx].leftEdge += matchLen
    if runs[openerIdx].remaining == 0: stack.delete(sp)
    dec sp

proc resolveEmphasis(t: Utf16Text, length: int,
                     claimed: var ClaimedIndex): seq[Span] =
  var runs = collectDelimiterRuns(t, length, claimed)
  if runs.len == 0: return @[]
  var stack: seq[int] = @[]
  var spans: seq[Span] = @[]
  for idx in 0 ..< runs.len:
    if runs[idx].canClose:
      closeAgainstStack(idx, runs, stack, spans)
    if runs[idx].canOpen and runs[idx].remaining > 0:
      stack.add idx
  spans

# ---------------------------------------------------------------------------
# 5. Containment tree
# ---------------------------------------------------------------------------

proc parseInlineImpl(t: Utf16Text, registry: ExtensionRegistry,
                     cost: var InlineParseCost): seq[InlineNode]

proc offsetNode(node: InlineNode, d: int): InlineNode

proc offsetNodes*(nodes: seq[InlineNode], delta: int): seq[InlineNode] =
  for n in nodes: result.add offsetNode(n, delta)

proc offsetNode(node: InlineNode, d: int): InlineNode =
  result = node
  result.range = node.range.shifted(d)
  result.contentRange = node.contentRange.shifted(d)
  result.urlRange = node.urlRange.shifted(d)
  if node.hasID: result.idRange = node.idRange.shifted(d)
  result.markers = @[]
  for m in node.markers: result.markers.add m.shifted(d)
  result.children = offsetNodes(node.children, d)

proc reparseSub(t: Utf16Text, r: Range, registry: ExtensionRegistry,
                cost: var InlineParseCost): seq[InlineNode] =
  ## Recursively parse a sub-range's content, offset back to absolute
  ## coordinates.
  let sub = initText(t.substring(r))
  offsetNodes(parseInlineImpl(sub, registry, cost), r.location)

proc buildTreeOrdered(region: Range, ordered: seq[Span], cursor: var int,
                      t: Utf16Text, registry: ExtensionRegistry,
                      cost: var InlineParseCost): seq[InlineNode] =
  ## Consumes spans from `cursor` for as long as they fall inside `region`,
  ## leaving `cursor` on the first span that doesn't.
  var textStart = region.location

  while cursor < ordered.len:
    let span = ordered[cursor]
    let fr = span.fullRange
    inc cost.containmentTests
    if not containsRange(region, fr): break
    inc cursor

    if fr.location > textStart:
      result.add textNode(rng(textStart, fr.location - textStart))

    case span.kind
    of spCode:
      result.add InlineNode(kind: inCode, range: fr, contentRange: span.contentRange)
    of spEmphasis:
      let content = rng(maxRange(span.markers[0]),
                        span.markers[1].location - maxRange(span.markers[0]))
      result.add InlineNode(kind: inEmphasis, range: fr, contentRange: content,
                            emphasis: span.emphasis, markers: span.markers,
                            children: buildTreeOrdered(content, ordered, cursor,
                                                       t, registry, cost))
    of spLink:
      result.add InlineNode(kind: inLink, range: fr, contentRange: span.contentRange,
                            urlRange: span.urlRange, markers: span.markers,
                            children: reparseSub(t, span.contentRange, registry, cost))
    of spImage:
      result.add InlineNode(kind: inImage, range: fr, contentRange: span.contentRange,
                            urlRange: span.urlRange, markers: span.markers)
    of spWikiLink:
      result.add InlineNode(kind: inWikiLink, range: fr, contentRange: span.contentRange,
                            idRange: span.idRange, hasID: span.hasID,
                            markers: span.markers)
    of spImageEmbed:
      result.add InlineNode(kind: inImageEmbed, range: fr,
                            contentRange: span.contentRange, markers: span.markers)
    of spInlineLatex:
      result.add InlineNode(kind: inInlineLatex, range: fr,
                            contentRange: span.contentRange, markers: span.markers)
    of spEscape:
      result.add InlineNode(kind: inEscape, range: fr, contentRange: span.contentRange,
                            markers: span.markers)
    of spExt:
      result.add InlineNode(kind: inExt, range: fr, contentRange: span.contentRange,
                            markers: span.markers, extensionID: span.extensionID,
                            children: if span.parsesContent:
                                        reparseSub(t, span.contentRange, registry, cost)
                                      else: @[])

    # Every span but emphasis is opaque, so nothing should remain inside one.
    # Skipping keeps the walk well-formed if that ever changes, rather than
    # emitting a node past the cursor.
    while cursor < ordered.len and containsRange(fr, ordered[cursor].fullRange):
      inc cursor
      inc cost.containmentTests
    inc cost.containmentTests
    textStart = maxRange(fr)

  if textStart < maxRange(region):
    result.add textNode(rng(textStart, maxRange(region) - textStart))

proc buildTree(region: Range, spans: seq[Span], t: Utf16Text,
               registry: ExtensionRegistry,
               cost: var InlineParseCost): seq[InlineNode] =
  # Spans are non-overlapping or properly nested (each pass claims only inside
  # regions no earlier pass took), so ordering by start ascending and length
  # descending puts every span immediately after the one that contains it.
  # Containment then falls out of a single ordered walk, instead of testing
  # each span against every other span.
  cost.containmentTests += spans.len
  var ordered: seq[Span] = @[]
  for s in spans:
    if containsRange(region, s.fullRange): ordered.add s
  ordered.sort(proc (a, b: Span): int =
    if a.fullRange.location == b.fullRange.location:
      cmp(b.fullRange.length, a.fullRange.length)
    else:
      cmp(a.fullRange.location, b.fullRange.location))
  var cursor = 0
  buildTreeOrdered(region, ordered, cursor, t, registry, cost)

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

proc parseInlineImpl(t: Utf16Text, registry: ExtensionRegistry,
                     cost: var InlineParseCost): seq[InlineNode] =
  let length = t.len
  if length == 0: return @[]

  var claimed = scanCodeSpans(t, length)

  var escapeIndex = initClaimedIndex(claimed)
  claimed.add scanEscapes(t, length, escapeIndex)

  var linkIndex = initClaimedIndex(claimed)
  claimed.add scanLinkFamily(t, length, linkIndex, registry)

  var emphasisIndex = initClaimedIndex(claimed)
  let emphasis = resolveEmphasis(t, length, emphasisIndex)

  cost.claimedProbes += escapeIndex.probes + linkIndex.probes + emphasisIndex.probes
  buildTree(rng(0, length), claimed & emphasis, t, registry, cost)

proc parseInline*(text: string, registry = emptyRegistry(),
                  cost: var InlineParseCost): seq[InlineNode] =
  ## Parse, reporting the work the claimed-range and containment scans did.
  parseInlineImpl(initText(text), registry, cost)

proc parseInline*(text: string, registry = emptyRegistry()): seq[InlineNode] =
  var cost = InlineParseCost()
  parseInlineImpl(initText(text), registry, cost)

proc parseInline*(t: Utf16Text, range: Range,
                  registry = emptyRegistry()): seq[InlineNode] =
  ## Parse the inline content of `range` within `t`, returning nodes in
  ## absolute document coordinates.
  var cost = InlineParseCost()
  offsetNodes(parseInlineImpl(initText(t.substring(range)), registry, cost),
              range.location)

proc parseInline*(t: Utf16Text, range: Range, registry: ExtensionRegistry,
                  cost: var InlineParseCost): seq[InlineNode] =
  offsetNodes(parseInlineImpl(initText(t.substring(range)), registry, cost),
              range.location)
