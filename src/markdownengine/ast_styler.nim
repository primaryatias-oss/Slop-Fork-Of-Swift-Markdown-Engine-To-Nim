## ast_styler.nim
## MarkdownEngine (Nim port)
##
## The AST-native styler. Walks the document AST and emits `StyledRange`s,
## COMPOSING attributes on descent: a heading sets a large bold font,
## descending into bold adds the bold trait (keeping the size), into italic
## adds italic — so nested/combined inline styles stack instead of overwriting
## each other. Composition is what the old flat pass pipeline got wrong, e.g.
## the shrinking bold in `# **n*o*des**`.
##
## **Invariant:** markers SHRINK, they don't disappear. Inactive markers render
## at `markers.hiddenMarkerFontSize`; they are never removed from the text.
## Every selection / copy / find / undo bug downstream traces back to violating
## this.
##
## **Invariant:** if the caller passes `scopedRanges`, only the intersecting
## blocks are re-styled — the optimization that keeps per-keystroke restyling
## cheap.

import std/[math, strutils, tables]
import ./ranges, ./utf16text, ./color, ./font, ./attributes, ./theme
import ./extension, ./directive, ./directive_scanner, ./services, ./configuration
import ./inline_parser, ./block_parser, ./ast, ./lists

const
  blockquoteIndentPerLevel* = 18.0
    ## Horizontal space each blockquote nesting level occupies — shared so the
    ## styler's text indent and the painted bars line up.
  blockquoteBarWidth* = 3.0
  taskCheckboxGap* = 2.0
    ## Gap between the drawn box's right edge and the task content's left edge.

proc taskCheckboxSize*(tm: TextMetrics, widths: WidthCache, font: FontDesc): float =
  ## Side length of the drawn square for the given (body) font. The hidden
  ## `[ ] ` characters are collapsed to ~zero advance by the styler, so the box
  ## range sits at the task CONTENT's left edge; the square is right-aligned to
  ## that edge with a small gap, occupying the `- ` marker slot.
  let m = tm.metrics(font)
  let fontHeight = max(1.0, ceil(max(0.0, m.ascent) + max(0.0, m.descent)))
  let markerWidth = textWidth(widths, tm, "[ ]", font)
  max(1.0, min(floor(fontHeight * 1.2), floor(markerWidth * 1.2)))

func taskCheckboxBoxX*(contentX, size: float): float {.inline.} =
  contentX - size - taskCheckboxGap

# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------

type
  WikiLinkIDProvider* = proc (r: Range): (string, bool) {.closure, gcsafe.}

  StylerContext* = object
    ## Shared inputs threaded through the walk.
    text*: Utf16Text
    config*: MarkdownEditorConfiguration
    tm*: TextMetrics
    widths*: WidthCache
    appearance*: Appearance
    fontName*: string
    baseFont*: FontDesc
    baseLineHeight*: float
    baseParagraphSpacing*: float
    codeFont*: FontDesc
    codeBackground*: Color
    codeParagraphStyle*: ParagraphStyle
    inlineMarkerFont*: FontDesc
    caret*: int
    selection*: Range
      ## The full selected range (empty when the selection is a bare caret).
      ## Token-based elements already reveal on selection via the active-token
      ## indices; this brings the same signal to non-token elements (task
      ## checkboxes). The caret-only reveal can hit at most ONE selected task
      ## line — every other selected line stayed hidden.
    hasSelection*: bool
    wikiLinkID*: WikiLinkIDProvider
    scopedRanges*: seq[Range]
    hasScope*: bool
    orderedDisplayNumbers*: Table[int, int]

func theme*(ctx: StylerContext): MarkdownEditorTheme {.inline.} = ctx.config.theme

func selectionIntersects*(ctx: StylerContext, r: Range): bool {.inline.} =
  ## True when a non-empty selection overlaps `r` — the selection counterpart
  ## of `isActive` for elements that reveal on select.
  if not ctx.hasSelection or ctx.selection.length <= 0: return false
  intersects(ctx.selection, r)

func isActive*(ctx: StylerContext, r: Range): bool =
  ## Active (syntax revealed) when the caret is inside the range or at its end
  ## (minus a newline).
  if contains(r, ctx.caret): return true
  if r.length <= 0 or ctx.caret != maxRange(r): return false
  not isLineBreakUnit(ctx.text.charAt(ctx.caret - 1))

func inScope*(ctx: StylerContext, r: Range): bool {.inline.} =
  ## Whether a range falls in the styled region (no scope = whole document).
  if not ctx.hasScope: return true
  anyIntersects(ctx.scopedRanges, r)

func scanRanges*(ctx: StylerContext): seq[Range] =
  ## Ranges the text passes scan (edited paragraphs, or the whole document).
  if ctx.hasScope: ctx.scopedRanges else: @[ctx.text.fullRange]

proc hiddenRunKern*(ctx: StylerContext, text: string, font: FontDesc): float =
  ## Per-character negative kern that collapses a hidden run to ~zero advance.
  ##
  ## Divided by the UTF-16 length, NOT applied whole: kern is per character, so
  ## a whole-run value multiplies by the character count and lays the run out
  ## at a huge negative width, which poisons the document's usage bounds.
  let count = max(1, utf16Len(text))
  textWidth(ctx.widths, ctx.tm, text, font) / float(count)

proc shrinkAttrs(ctx: StylerContext): Attrs =
  @[(akFont, av(ctx.inlineMarkerFont)),
    (akKern, av(-ctx.inlineMarkerFont.size))]

# ---------------------------------------------------------------------------
# Ordered-list display numbering
# ---------------------------------------------------------------------------

proc seedOrderedCounters(t: Utf16Text, loc: int): Table[int, int] =
  ## Replays the ordered-list run that continues ABOVE `loc` (scanning backward
  ## in the full source: same-indent items counted, blank lines skipped, real
  ## content stops it) and returns the next number per indent. Lets a scoped
  ## restyle that only sees a local window continue the document's numbering.
  result = initTable[int, int]()
  if loc <= 0 or loc > t.len: return

  var runLines: seq[tuple[indent: int, number: int, hasNumber: bool]] = @[]
  # From the START of loc's line: callers pass a MARKER offset, which for an
  # indented item still sits inside its own line — scanning up from there
  # counted the item itself, so every nested list rendered one too high.
  var scan = t.lineRange(caretAt(min(loc, t.len))).location
  while scan > 0:
    let lineRange = t.lineRange(caretAt(scan - 1))
    if t.isBlankRange(lineRange):
      scan = lineRange.location                    # blank line: loose-list spacing
      continue
    let (m, ok) = matchListLine(t, lineRange)
    if not ok: break
    # Key by the raw leading-whitespace CHARACTER count to match the parser's
    # `item.indent` used by the display-number pass — otherwise a nested item's
    # seed counter wouldn't line up and it'd fall back to the literal digit.
    runLines.add (m.leadingWhitespace.length, m.number, m.hasNumber and m.ordered)
    scan = lineRange.location

  for i in countdown(runLines.len - 1, 0):         # replay top-to-bottom
    let item = runLines[i]
    if item.hasNumber:
      let base = if result.hasKey(item.indent): result[item.indent] else: item.number
      result[item.indent] = base + 1
    else:
      result.del(item.indent)
    var deeper: seq[int] = @[]
    for key in result.keys:
      if key > item.indent: deeper.add key
    for key in deeper: result.del(key)

proc computeOrderedDisplayNumbers(blocks: seq[BlockNode], t: Utf16Text): Table[int, int] =
  ## Ordered-list display numbers computed across the WHOLE document, keyed by
  ## each ordered item's marker location. Positional, not the literal digit, so
  ## any edit renumbers correctly; the count carries across a blank line (a
  ## loose-list separator) so `1.`/`2.`⏎blank⏎`2.` shows 1,2,3 — real content
  ## between lists resets it. The first item of a run keeps its own start value.
  result = initTable[int, int]()
  var counters = initTable[int, int]()
  # `blocks` is NOT the document: a scoped restyle keeps only the blocks that
  # intersect the scope, and a multi-region scope drops everything between
  # them — including the prose whose fallthrough below is what ends a run. So
  # treat every discontinuity like a fresh start and re-seed from the SOURCE,
  # the only thing that can still see the skipped text. Lazily, at the first
  # ordered item after the gap, so prose/bullet restyles never pay the scan.
  var needsSeed = true
  var contiguousEnd = -1

  for b in blocks:
    if contiguousEnd >= 0 and b.range.location > contiguousEnd:
      let hole = rng(contiguousEnd, b.range.location - contiguousEnd)
      if t.rangeOfCharacterNotWhitespace(hole).location != NotFound:
        # Only CONTENT in the hole ends the run. A hole of pure blank lines is
        # loose-list spacing — and it is the shape the forward walk hands us
        # (list, list, list, blanks skipped), where re-seeding meant one full
        # backward scan per item.
        counters.clear()
        needsSeed = true
    contiguousEnd = maxRange(b.range)

    case b.kind
    of bnList:
      # A scoped node carries only the items the scope reached, so the hole
      # check has to bound BOTH ends of the item run against the block, not
      # just the space between two materialized items.
      var previousItemEnd = b.range.location
      for item in b.items:
        if item.range.location > previousItemEnd:
          counters.clear()
          needsSeed = true
        if item.ordered and item.hasNumber:
          if needsSeed:
            counters = seedOrderedCounters(t, item.marker.location)
            needsSeed = false
          let n = if counters.hasKey(item.indent): counters[item.indent]
                  else: item.number
          result[item.marker.location] = n
          counters[item.indent] = n + 1
        else:
          counters.del(item.indent)
        var deeper: seq[int] = @[]
        for key in counters.keys:
          if key > item.indent: deeper.add key
        for key in deeper: counters.del(key)
        previousItemEnd = maxRange(item.range)
      # Items the scope dropped from the TAIL are not "already counted".
      # Leaving `contiguousEnd` at the block's end hides them, so the next
      # block sees only the blank separator, reads it as loose-list spacing,
      # and carries a short count into a fresh run. Ending the stretch at the
      # last materialized item turns them back into the content hole they are.
      if previousItemEnd < maxRange(b.range):
        contiguousEnd = previousItemEnd
    of bnBlank:
      discard                       # blank lines keep the count (spacing, not a reset)
    of bnParagraph:
      if b.inlines.len == 0:
        discard                     # an empty paragraph line is spacing too
      else:
        counters.clear()
        needsSeed = false
    else:
      counters.clear()              # real text/content ends the run
      needsSeed = false             # a seed scan would stop on this line anyway

# ---------------------------------------------------------------------------
# Auto-links and incomplete-link brackets (text passes, AST-agnostic)
# ---------------------------------------------------------------------------

const urlSchemes = ["https://", "http://", "ftp://", "ftps://", "mailto:",
                    "file://", "ssh://", "git://"]

func isUrlBodyUnit(c: uint16): bool {.inline.} =
  ## Characters that may continue a bare URL. Deliberately generous in the
  ## middle and trimmed at the end by `trimUrlTail`, which is how
  ## `NSDataDetector` behaves on trailing punctuation.
  if c <= 0x20u16: return false
  c notin [chLT, chGT, chQuote, 0x7Fu16, chPipe, chLBrace, chRBrace,
           chLBracket, chRBracket, chBacktick]

func trimUrlTail(t: Utf16Text, r: Range): Range =
  ## Drop trailing punctuation that is almost always sentence punctuation
  ## rather than part of the URL, and close unbalanced parens.
  result = r
  while result.length > 0:
    let last = t.charAt(maxRange(result) - 1)
    if last in [chDot, chComma, chSemicolon, chColon, chBang, 0x3Fu16,
                0x27u16, chAsterisk, chUnderscore, chTilde]:
      dec result.length
    elif last == chRParen:
      var opens = 0
      var closes = 0
      for i in result.location ..< maxRange(result):
        if t.charAt(i) == chLParen: inc opens
        elif t.charAt(i) == chRParen: inc closes
      if closes > opens: dec result.length else: break
    else:
      break

func looksLikeHostRun(t: Utf16Text, start: int): (int, bool) =
  ## A bare `host.tld[/path]` run starting at `start`: at least two
  ## dot-separated labels with an alphabetic TLD of 2+ characters.
  ##
  ## `lastValidEnd` is what makes a sentence-final domain work: `example.com.`
  ## keeps scanning past the period into a third (empty) label, so the run has
  ## to remember the last position at which it WAS a valid host and stop there
  ## rather than failing on the trailing punctuation.
  var i = start
  let length = t.len
  var labels = 0
  var labelLength = 0
  var tldLength = 0
  var tldAlpha = true
  var lastValidEnd = -1
  while i < length:
    let c = t.charAt(i)
    if isAsciiAlnum(c) or c == chDash:
      inc labelLength
      if isAsciiLetter(c): inc tldLength
      else: tldAlpha = false
      inc i
      if labels >= 1 and labelLength >= 2 and tldAlpha and tldLength >= 2:
        lastValidEnd = i
    elif c == chDot and labelLength > 0:
      inc labels
      labelLength = 0
      tldLength = 0
      tldAlpha = true
      inc i
    else:
      break
  if lastValidEnd < 0: return (start, false)
  # Optional path / query, only when it abuts the host itself.
  var stop = lastValidEnd
  if stop < length and (t.charAt(stop) == chSlash or t.charAt(stop) == 0x3Fu16):
    while stop < length and isUrlBodyUnit(t.charAt(stop)): inc stop
  (stop, true)

proc detectUrls*(t: Utf16Text, within: Range): seq[Range] =
  ## Hand-written stand-in for `NSDataDetector(types: .link)`: explicit
  ## schemes, `www.` prefixes, bare `host.tld` runs, and email addresses.
  ##
  ## There is no data detector and no regex engine here, and the engine already
  ## hand-writes every other scanner, so this one is hand-written too. It is
  ## deliberately conservative: a missed auto-link renders as plain text, while
  ## a false positive would make prose clickable.
  let stop = maxRange(clamped(within, t.len))
  var i = max(0, within.location)
  while i < stop:
    let c = t.charAt(i)
    if not (isAsciiLetter(c) or isAsciiDigit(c)):
      inc i
      continue
    # A URL must start at a word boundary.
    if i > 0 and (isAsciiAlnum(t.charAt(i - 1)) or t.charAt(i - 1) == chDot or
                  t.charAt(i - 1) == chAt or t.charAt(i - 1) == chSlash):
      while i < stop and (isAsciiAlnum(t.charAt(i)) or t.charAt(i) == chDot or
                          t.charAt(i) == chAt): inc i
      continue

    var matched = false
    for scheme in urlSchemes:
      let units = toUtf16(scheme)
      if matchesAt(t, i, units):
        var k = i + units.len
        while k < stop and isUrlBodyUnit(t.charAt(k)): inc k
        let candidate = trimUrlTail(t, rng(i, k - i))
        if candidate.length > units.len:
          result.add candidate
          i = maxRange(candidate)
          matched = true
        break
    if matched: continue

    # `name@host.tld` — scan the local part, then require a host run.
    var atIndex = i
    while atIndex < stop and (isAsciiAlnum(t.charAt(atIndex)) or
          t.charAt(atIndex) in [chDot, chUnderscore, chPlus, chDash]):
      inc atIndex
    if atIndex < stop and t.charAt(atIndex) == chAt and atIndex > i:
      let (hostEnd, isHost) = looksLikeHostRun(t, atIndex + 1)
      if isHost and hostEnd <= stop:
        let candidate = trimUrlTail(t, rng(i, hostEnd - i))
        result.add candidate
        i = maxRange(candidate)
        continue

    let (hostEnd, isHost) = looksLikeHostRun(t, i)
    if isHost and hostEnd <= stop:
      let candidate = trimUrlTail(t, rng(i, hostEnd - i))
      if candidate.length >= 4:
        result.add candidate
        i = maxRange(candidate)
        continue

    # Not a URL: skip the whole word so the next probe starts at a boundary.
    while i < stop and (isAsciiAlnum(t.charAt(i)) or t.charAt(i) == chDot or
                        t.charAt(i) == chAt): inc i

func urlFromDetected*(t: Utf16Text, r: Range): string =
  ## The href an auto-linked run navigates to; a bare host gets a scheme.
  ##
  ## That scheme is `https`, where `NSDataDetector` supplied `http` for a
  ## scheme-less `www.` host. The detector's choice dates from when a plain
  ## redirect was the norm; today an `http` href on a host that only serves
  ## TLS is a dead link in a pasted document, and the one that does serve
  ## plaintext will redirect. A deliberate divergence, and the only one in
  ## this function.
  let raw = t.substring(r)
  for scheme in urlSchemes:
    if raw.startsWith(scheme): return raw
  if raw.contains('@') and not raw.contains('/'): "mailto:" & raw
  else: "https://" & raw

proc incompleteLinkMatches*(t: Utf16Text, within: Range): seq[Range] =
  ## Hand-written equivalent of the six incomplete-link patterns:
  ##
  ## * `\[\]`
  ## * `\[\[\]\]`
  ## * `\[[^\]\r\n]*$`
  ## * `\[[^\]\r\n]+\](?!\()`
  ## * `\[[^\]\r\n]+\]\([^)\r\n]*$`
  ## * `\[[^\]\r\n]+\]\(\)`
  ##
  ## The two `$`-anchored patterns were compiled WITHOUT `anchorsMatchLines`,
  ## so `$` means the end of the document (or just before a final line
  ## terminator) — not the end of each line. `documentEnd` below reproduces
  ## that exactly; an unclosed `[` only fades when it reaches the end.
  let length = t.len
  var documentEnd = length
  if documentEnd > 0 and isLineBreakUnit(t.charAt(documentEnd - 1)):
    dec documentEnd
    if documentEnd > 0 and t.charAt(documentEnd) == chLF and
       t.charAt(documentEnd - 1) == chCR:
      dec documentEnd

  let stop = maxRange(clamped(within, length))
  var i = max(0, within.location)
  while i < stop:
    if t.charAt(i) != chLBracket:
      inc i
      continue

    # `\[\[\]\]` before `\[\]`, longest first.
    if matchesAt(t, i, toUtf16("[[]]")):
      result.add rng(i, 4)
      i += 4
      continue
    if matchesAt(t, i, toUtf16("[]")):
      result.add rng(i, 2)
      i += 2
      continue

    # Scan the label: `[^\]\r\n]*`
    var k = i + 1
    while k < length and t.charAt(k) != chRBracket and
          not isLineBreakUnit(t.charAt(k)): inc k

    if k >= documentEnd and (k >= length or t.charAt(k) != chRBracket):
      # `\[[^\]\r\n]*$`
      result.add rng(i, documentEnd - i)
      i = max(i + 1, documentEnd)
      continue

    if k >= length or t.charAt(k) != chRBracket:
      inc i
      continue
    if k == i + 1:
      inc i                                     # `[]` already handled above
      continue

    let afterBracket = k + 1
    if afterBracket >= length or t.charAt(afterBracket) != chLParen:
      # `\[[^\]\r\n]+\](?!\()`
      result.add rng(i, afterBracket - i)
      i = afterBracket
      continue

    if afterBracket + 1 < length and t.charAt(afterBracket + 1) == chRParen:
      # `\[[^\]\r\n]+\]\(\)`
      result.add rng(i, (afterBracket + 2) - i)
      i = afterBracket + 2
      continue

    # `\[[^\]\r\n]+\]\([^)\r\n]*$`
    var p = afterBracket + 1
    while p < length and t.charAt(p) != chRParen and
          not isLineBreakUnit(t.charAt(p)): inc p
    if p >= documentEnd and (p >= length or t.charAt(p) != chRParen):
      result.add rng(i, documentEnd - i)
      i = max(i + 1, documentEnd)
      continue
    inc i

proc styleAutoLinks(ctx: StylerContext, codeRanges, linkRanges: seq[Range],
                    attrs: var seq[StyledRange]) =
  for scan in ctx.scanRanges:
    for match in detectUrls(ctx.text, scan):
      # Skip URLs inside code and inside a markdown/wiki link's own range — a
      # link's `(url)` must not become a second link region competing with the
      # link itself.
      if isInRanges(match, codeRanges): continue
      if isInRanges(match, linkRanges): continue
      # Colour and underline are explicit here for the same reason as in the
      # wiki-link pass: AppKit drew a `.link` run in the system link colour
      # with an underline off the attribute alone, and nothing below this
      # layer does that, so a bare `example.com` would read as body text.
      attrs.add (match, @[(akLink, av(urlFromDetected(ctx.text, match))),
                          (akUnderlineStyle, av(ulSingle)),
                          (akForegroundColor, av(ctx.theme.link))])

proc styleIncompleteLinkBrackets(ctx: StylerContext,
                                 codeRanges, checkboxRanges,
                                 linkRanges: seq[Range],
                                 attrs: var seq[StyledRange]) =
  # Every pattern starts with `[`, so no `[` in the text ⇒ no match: skip the
  # whole sweep.
  if rangeOf(ctx.text, "[").location == NotFound: return
  let muted = ctx.theme.mutedText
  let faded = withAlpha(ctx.theme.incompleteLink, ctx.config.link.incompleteLinkAlpha)
  for scan in ctx.scanRanges:
    for m in incompleteLinkMatches(ctx.text, scan):
      if isInRanges(m, codeRanges) or isInRanges(m, checkboxRanges): continue
      # Also skip what the AST already recognised as a COMPLETE link or
      # wiki-link. `[[Name]]` satisfies `\[[^\]\r\n]+\](?!\()` — the inner
      # `[` is not excluded by the character class and the following `]` is not
      # a `(` — so without this the pass repaints every wiki link as an
      # incomplete one.
      #
      # This is a deliberate, narrow divergence from the Swift original, which
      # leaned on AppKit rendering a `.link` run in the link colour regardless
      # of the foreground painted into the storage. There is no text system
      # here to do that, so the exclusion has to be explicit — otherwise a
      # resolving wiki-link loses its link colour and a broken one stops
      # looking broken. It is the same exclusion the auto-link pass already
      # makes, for the same reason.
      if isInRanges(m, linkRanges): continue
      # One range per RUN of same-coloured characters, not per character: a
      # single `[Design System]` would otherwise emit 15 ranges, and every one
      # of them is a separate storage mutation downstream.
      var runStart = m.location
      var runLength = 0
      var runIsBracket = false
      for i in m.location ..< maxRange(m):
        let c = ctx.text.charAt(i)
        let isBracket = c == chLBracket or c == chRBracket or
                        c == chLParen or c == chRParen
        if runLength > 0 and isBracket != runIsBracket:
          attrs.add (rng(runStart, runLength),
                     @[(akForegroundColor, av(if runIsBracket: muted else: faded))])
          runStart += runLength
          runLength = 0
        runIsBracket = isBracket
        inc runLength
      if runLength > 0:
        attrs.add (rng(runStart, runLength),
                   @[(akForegroundColor, av(if runIsBracket: muted else: faded))])

# ---------------------------------------------------------------------------
# Thematic breaks
# ---------------------------------------------------------------------------

func thematicBreakMarker(ctx: StylerContext, hr: Range): uint16 =
  ## The marker character of a thematic-break line: its first non-whitespace
  ## character. Sound by construction — the block parser accepts the line only
  ## when every non-whitespace character is the same one of `-`/`*`/`_`. Only
  ## trailing newlines are trimmed from the block range, so leading indent has
  ## to be skipped here.
  for offset in 0 ..< hr.length:
    let c = ctx.text.charAt(hr.location + offset)
    if c != chSpace and c != chTab: return c
  0u16

proc styleThematicBreak(ctx: StylerContext, r: Range, attrs: var seq[StyledRange]) =
  ## Tag a thematic-break line for a full-width rule; suppressed while the
  ## caret edits it.
  ##
  ## When the configuration maps this line's marker to a mark, the mark rides
  ## along and the renderer draws that string centered instead of the rule.
  ## Resolving here rather than at draw time keeps the presentation decision
  ## next to the configuration and leaves the renderer with nothing to look up.
  let hr = ctx.text.trimmedTrailingNewlines(r)
  if hr.length <= 0: return
  if contains(hr, ctx.caret) or ctx.caret == maxRange(hr): return

  var tags: Attrs = @[(akForegroundColor, av(clearColor)),
                      (akThematicBreak, av(true))]
  let (mark, hasMark) = ctx.config.thematicBreak.markForMarker(thematicBreakMarker(ctx, hr))
  if hasMark:
    tags.add (akThematicBreakMark, av(mark.text))
    tags.add (akThematicBreakMarkScale, av(mark.scale))
  attrs.add (hr, tags)

  # A mark bigger than body size needs the line to grow with it, or it would be
  # drawn over the paragraphs above and below (the renderer paints outside the
  # line box; it does not reserve space).
  let para = newParagraphStyle()
  if hasMark and mark.scale > 1:
    let height = ceil(ctx.baseLineHeight * mark.scale)
    para.minimumLineHeight = height
    para.maximumLineHeight = height
  attrs.add (hr, @[(akParagraphStyle, av(para))])

# ---------------------------------------------------------------------------
# Code blocks
# ---------------------------------------------------------------------------

type CodeBlockParts = object
  codeRange: Range
  openFence: Range
  content: Range
  closeFence: Range
  language: string
  hasLanguage: bool

func codeBlockParts(ctx: StylerContext, r: Range): CodeBlockParts =
  ## Split a fenced-code range into open fence (+language), content, close
  ## fence, and language.
  let start = r.location
  let stop = maxRange(r)
  var openEnd = start
  while openEnd < stop and ctx.text.charAt(openEnd) != chLF: inc openEnd
  if openEnd < stop: inc openEnd
  let openFence = rng(start, openEnd - start)

  let lastLine = ctx.text.lineRange(caretAt(max(start, stop - 1)))
  var bt = lastLine.location
  while bt < maxRange(lastLine) and ctx.text.charAt(bt) == chBacktick: inc bt
  let closeFence = rng(lastLine.location, bt - lastLine.location)
  let codeRange = rng(start, maxRange(closeFence) - start)
  let content = rng(openEnd, max(0, lastLine.location - openEnd))

  var language = ""
  var hasLanguage = false
  if openFence.length > 3:
    let raw = trimWhitespaceAndNewlines(
      ctx.text.substring(rng(start + 3, openFence.length - 3)))
    if raw.len > 0:
      language = raw
      hasLanguage = true
  CodeBlockParts(codeRange: codeRange, openFence: openFence, content: content,
                 closeFence: closeFence, language: language,
                 hasLanguage: hasLanguage)

proc styleCodeBlock(ctx: StylerContext, r: Range, attrs: var seq[StyledRange]) =
  let parts = codeBlockParts(ctx, r)
  attrs.add (parts.codeRange, @[(akFont, av(ctx.codeFont)),
                                (akBackgroundColor, av(ctx.codeBackground)),
                                (akParagraphStyle, av(ctx.codeParagraphStyle))])
  # Suppress spell-check underlines on the whole fenced block — code is not
  # prose.
  attrs.add (parts.codeRange, @[(akSpellingState, av(0))])

  let codeContent = ctx.text.substring(parts.content)
  if codeContent.len > 0:
    let (runs, ok) = ctx.config.services.syntaxHighlighter.highlight(
      codeContent, parts.language, parts.hasLanguage)
    if ok:
      for run in runs:
        attrs.add (rng(parts.content.location + run.range.location, run.range.length),
                   @[(akForegroundColor, av(run.color))])

  # Use the whole block range (not `codeRange`): an incomplete fence collapses
  # `codeRange` to the ```.
  let markerAttrs: Attrs =
    if ctx.isActive(r):
      @[(akForegroundColor, av(ctx.theme.mutedText)), (akFont, av(ctx.codeFont))]
    else:
      # The hidden marker font IS the code font here, so the fence keeps the
      # block's line height across the active flip.
      @[(akForegroundColor, av(clearColor)), (akFont, av(ctx.codeFont))]
  attrs.add (parts.openFence, markerAttrs)
  attrs.add (parts.closeFence, markerAttrs)

# ---------------------------------------------------------------------------
# Blockquote
# ---------------------------------------------------------------------------

proc styleBlockquote(ctx: StylerContext, r: Range, attrs: var seq[StyledRange]) =
  ## Per-line blockquote: indent, mute content, hide/show `>` markers, tag the
  ## whole line with the bar level.
  var lineStart = r.location
  let stop = maxRange(r)
  while lineStart < stop:
    let line = ctx.text.lineRange(caretAt(lineStart))
    let lineEnd = maxRange(line)
    var i = line.location
    var indent = 0
    while i < lineEnd and indent < 3 and isWhitespaceUnit(ctx.text.charAt(i)):
      inc i
      inc indent
    let markerStart = i
    var level = 0
    var j = i
    while j < lineEnd and ctx.text.charAt(j) == chGT:
      inc level
      inc j
      if j < lineEnd and isWhitespaceUnit(ctx.text.charAt(j)): inc j
    if level == 0:
      lineStart = lineEnd
      continue

    var contentEnd = lineEnd
    if contentEnd > j and isLineBreakUnit(ctx.text.charAt(contentEnd - 1)):
      dec contentEnd
    let markerRange = rng(markerStart, j - markerStart)
    let contentRange = rng(j, max(0, contentEnd - j))
    let tokenRange = rng(line.location, contentEnd - line.location)

    let textIndent = float(level) * blockquoteIndentPerLevel +
                     blockquoteIndentPerLevel * 0.5
    let para = newParagraphStyle()
    para.firstLineHeadIndent = textIndent
    para.headIndent = textIndent
    let lineHeight = ctx.baseLineHeight + ctx.config.blockquote.extraLineHeight
    para.minimumLineHeight = lineHeight
    para.maximumLineHeight = lineHeight
    # Inner quote lines stay tight (0); the LAST line gets the normal spacing.
    para.paragraphSpacing = if lineEnd >= stop: ctx.baseParagraphSpacing else: 0.0
    para.paragraphSpacingBefore = 0
    attrs.add (ctx.text.paragraphRange(tokenRange),
               @[(akParagraphStyle, av(para))])

    if contentRange.length > 0:
      attrs.add (contentRange, @[(akForegroundColor, av(ctx.theme.mutedText))])
    if ctx.isActive(tokenRange):
      attrs.add (markerRange, @[(akForegroundColor, av(ctx.theme.mutedText))])
    else:
      attrs.add (markerRange, @[(akForegroundColor, av(clearColor)),
                                (akFont, av(ctx.inlineMarkerFont))])
    # Whole line, not just the first char, so each soft-wrapped visual line
    # paints its bars.
    attrs.add (tokenRange, @[(akBlockquoteLevel, av(level))])
    lineStart = lineEnd

# ---------------------------------------------------------------------------
# List items
# ---------------------------------------------------------------------------

proc styleTaskMarker(ctx: StylerContext, item: ListItem, box: Range,
                     attrs: var seq[StyledRange]) =
  ## A task item's own decoration, shared by both geometries: hide `- [ ] `,
  ## hang the drawn box on the `[ ]` range, strike a checked item through.
  let spacer = rng(maxRange(item.marker), box.location - maxRange(item.marker))
  # `- ` keeps full advance (the box's slot, like the bullet `•`); `[ ]` plus
  # the trailing space collapse to the hidden-marker font so the content starts
  # at the bullet-content x.
  attrs.add (item.marker, @[(akForegroundColor, av(clearColor))])
  if spacer.length > 0:
    attrs.add (spacer, @[(akForegroundColor, av(clearColor))])
  attrs.add (box, @[(akTaskCheckbox, av(item.checked)),
                    (akForegroundColor, av(clearColor)),
                    (akFont, av(ctx.inlineMarkerFont))])
  let postGap = rng(maxRange(box), item.contentRange.location - maxRange(box))
  if postGap.length > 0:
    attrs.add (postGap, @[(akForegroundColor, av(clearColor)),
                          (akFont, av(ctx.inlineMarkerFont))])
  if item.checked and maxRange(item.range) > maxRange(box):
    attrs.add (rng(maxRange(box), maxRange(item.range) - maxRange(box)),
               @[(akStrikethroughStyle, av(ulSingle)),
                 (akStrikethroughColor, av(ctx.theme.strikethroughColor))])

proc styleListItem(ctx: StylerContext, item: ListItem, displayNumber: int,
                   hasDisplayNumber: bool, attrs: var seq[StyledRange]) =
  ## AST list-item decoration: indent paragraph, `•` bullet, checkbox +
  ## strikethrough, all caret-aware.
  ##
  ## `helpersEnabled` switches EDITING conveniences (auto-continue,
  ## auto-indent, `- ` → `•`) — lists still render. Returning early for every
  ## item also dropped the checkbox attribute, and drawing, the hit test and
  ## the toggle all read that one attribute, so switching the helpers off
  ## removed task lists from the app altogether. A task item keeps its box; the
  ## bullet and number overlays stay with the helpers.
  let helpers = ctx.config.lists.helpersEnabled
  if not helpers and not item.hasCheckbox: return

  # Line content (item line minus its trailing newline).
  let line = ctx.text.trimmedTrailingNewlines(item.range)

  # 1. Indent paragraph style (hanging indent so wrapped lines align).
  let wsRange = rng(item.range.location, item.marker.location - item.range.location)
  # Revealed while the caret edits the syntax: the raw `- [ ]` stays at full
  # advance. A selection sweeping the syntax reveals it too — matching how
  # token-based elements reveal on selection.
  var taskRevealed = false
  if item.hasCheckbox:
    let syntax = rng(item.marker.location,
                     maxRange(item.checkbox) - item.marker.location)
    taskRevealed = contains(syntax, ctx.caret) or
                   ctx.caret == maxRange(item.checkbox) or
                   ctx.selectionIntersects(syntax)

  # A hidden task item shares the bullet geometry: `[ ] ` collapses to ~zero
  # advance below, so the hanging indent measures only `- ` and task content
  # aligns with bullet content (the box replaces the bullet slot).
  let markerGroup =
    if item.hasCheckbox and not taskRevealed:
      rng(item.marker.location, item.checkbox.location - item.marker.location)
    else:
      rng(item.marker.location, item.contentRange.location - item.marker.location)

  # An ordered item whose displayed number differs from its source digit gets
  # its WHOLE marker overlaid (below); the hanging indent must then measure the
  # DISPLAY marker so wrapped lines align at any digit count. Off for tasks
  # (the checkbox branch owns those).
  #
  # Neither the caret nor a selection takes the overlay down. Every other
  # markdown construct reveals its source under one, but an ordered marker's
  # source digit is the one thing the reader never authored: it is positional,
  # and a run written `1./1./1.` would flip a number back to `1.` on a plain
  # click or a select-all. The digits stay hidden and the renderer keeps
  # drawing the display number under the selection highlight, which is sized to
  # the same kerned slot.
  let orderedOverlayActive = item.ordered and not item.hasCheckbox and
    item.hasNumber and hasDisplayNumber and displayNumber != item.number
  # Keep the source punctuation (`.` or `)`) when overlaying, so a paren list
  # stays a paren list.
  let orderedPunct =
    if orderedOverlayActive and item.marker.length > 0:
      ctx.text.substring(rng(maxRange(item.marker) - 1, 1))
    else: "."

  # Via the memoized measure — list markers are a tiny repeated set.
  let markerWidth =
    if orderedOverlayActive:
      let gap = ctx.text.substring(rng(maxRange(item.marker),
                                       item.contentRange.location - maxRange(item.marker)))
      textWidth(ctx.widths, ctx.tm, $displayNumber & orderedPunct & gap, ctx.baseFont)
    else:
      textWidth(ctx.widths, ctx.tm, ctx.text.substring(markerGroup), ctx.baseFont)

  let depthIndent = float(indentLevel(ctx.text, wsRange)) * ctx.config.lists.indentPerLevel
  let ps = newParagraphStyle()

  if not helpers:
    # Helpers off means NO list indent — but the box is drawn to the LEFT of
    # the content, so a task line gets exactly that much room and not a point
    # more. Without it the box lands off the edge.
    #
    # Everything else here mirrors the BASE paragraph style rather than being
    # left at its defaults. A paragraph style replaces the base one wholesale,
    # so an unpinned line height lets the line fall back to the font's natural
    # height: the content height flips as the line crosses in and out of being
    # a task item, and the text below jumps with it.
    let room = max(0.0, taskCheckboxSize(ctx.tm, ctx.widths, ctx.baseFont) +
                        taskCheckboxGap - markerWidth)
    ps.minimumLineHeight = ctx.baseLineHeight + ctx.config.paragraph.lineHeightExtraSpacing
    ps.lineSpacing = 0
    ps.paragraphSpacing = ctx.baseParagraphSpacing
    ps.paragraphSpacingBefore = 0
    ps.lineBreakMode = lbWordWrapping
    ps.tabStops = evenTabStops(ctx.config.lists.indentPerLevel)
    ps.defaultTabInterval = 0
    ps.firstLineHeadIndent = room
    ps.headIndent = room + markerWidth
    attrs.add (line, @[(akParagraphStyle, av(ps))])
    if item.hasCheckbox and not taskRevealed:
      styleTaskMarker(ctx, item, item.checkbox, attrs)
    return

  let lineHeight = ctx.baseLineHeight + ctx.config.lists.extraLineHeight
  ps.minimumLineHeight = lineHeight
  ps.maximumLineHeight = lineHeight
  ps.lineSpacing = 0
  ps.paragraphSpacing = ctx.baseParagraphSpacing
  ps.paragraphSpacingBefore = 0
  ps.tabStops = @[]
  ps.defaultTabInterval = ctx.config.lists.indentPerLevel
  ps.firstLineHeadIndent = ctx.config.lists.indentPerLevel
  # Wrapped lines hang under the first line's content (indent + marker width).
  # No checkbox-specific extra: the box is a drawn overlay that doesn't change
  # text advance, so adding it here (and only here, not to
  # `firstLineHeadIndent`) shifted an unchecked task's wrapped lines right of
  # its first line.
  ps.headIndent = ctx.config.lists.indentPerLevel + depthIndent + markerWidth
  attrs.add (line, @[(akParagraphStyle, av(ps))])

  # 2. Marker decoration (suppressed while the caret edits the syntax).
  if item.hasCheckbox:
    if taskRevealed: return
    styleTaskMarker(ctx, item, item.checkbox, attrs)
  elif not item.ordered:
    let syntax = rng(item.marker.location,
                     item.contentRange.location - item.marker.location)
    if contains(syntax, ctx.caret): return
    attrs.add (item.marker, @[(akBulletMarker, av(true)),
                              (akForegroundColor, av(clearColor))])
  elif orderedOverlayActive:
    # Hide the ENTIRE source marker (digits + dot) as one unit and paint the
    # whole display marker "N." over it, so the dot travels with the digits.
    #
    # Hidden by SIZE, like every other marker this engine hides, not by a clear
    # colour: a selection repaints every selected glyph opaque, so a
    # colour-hidden marker comes back under the highlight and collides with the
    # number painted over it. A shrunken run cannot be repainted into
    # visibility. The colour stays as a second line of defence against
    # sub-pixel residue at extreme zoom.
    #
    # Kern that near-zero run back out to the display marker's width so the
    # slot, the hanging indent and the selection highlight all measure the same
    # thing. Horizontal only — a scaled-UP font would inflate the marker ascent
    # and push the content baseline down under the pinned line height.
    let hiddenW = textWidth(ctx.widths, ctx.tm, ctx.text.substring(item.marker),
                            ctx.inlineMarkerFont)
    let displayText = $displayNumber & orderedPunct
    let displayW = textWidth(ctx.widths, ctx.tm, displayText, ctx.baseFont)
    var markerAttrs: Attrs = @[(akOrderedMarker, av(displayText)),
                               (akForegroundColor, av(clearColor)),
                               (akFont, av(ctx.inlineMarkerFont))]
    if abs(displayW - hiddenW) > 0.01:
      markerAttrs.add (akKern, av((displayW - hiddenW) / float(max(1, item.marker.length))))
    attrs.add (item.marker, markerAttrs)

# ---------------------------------------------------------------------------
# Directives (the styling half of the seam)
# ---------------------------------------------------------------------------

proc presentSelfContained(ctx: StylerContext, node: InlineNode,
                          presentation: DirectivePresentation, font: FontDesc,
                          isActive: bool, attrs: var seq[StyledRange]) =
  ## Draw a self-contained directive's glyph in place of its source.
  ##
  ## Mechanically identical to inline LaTeX: the source text is never removed —
  ## it collapses to zero width via clear colour, the shrunk marker font, and
  ## negative kern, while the FIRST character carries the glyph plus enough
  ## positive kern to occupy the glyph's width. Selection, find, copy and undo
  ## all still see the real characters, which is what the "markers shrink, they
  ## don't disappear" invariant is protecting.
  ##
  ## With the caret inside, the source is revealed muted instead — the same flip
  ## every other construct performs.
  attrs.add (node.range, @[(akSpellingState, av(0))])

  if isActive:
    attrs.add (node.range, @[(akForegroundColor, av(ctx.theme.mutedText))])
    return

  # The glyph travels as DATA, not as a raster: the renderer owns the drawing,
  # so the engine stays free of any image pipeline. A `dprLiteral`, or a symbol
  # the renderer doesn't know, leaves the source visible rather than collapsing
  # it to a gap the user can't see or fix.
  var glyph: Attrs = @[]
  var glyphWidth = 0.0
  case presentation.kind
  of dprLiteral:
    return
  of dprSymbol:
    glyph.add (akDirectiveGlyph, av("symbol:" & presentation.symbolName))
    if presentation.hasTint:
      glyph.add (akDirectiveGlyphTint, av(presentation.tint))
    # A symbol is drawn to a square the size of the font's line box.
    glyphWidth = ceil(lineHeight(ctx.tm, font))
  of dprText:
    if presentation.text.len == 0: return
    glyph.add (akDirectiveGlyph, av("text:" & presentation.text))
    glyphWidth = textWidth(ctx.widths, ctx.tm, presentation.text, font)
  of dprImage:
    glyph.add (akImageEmbed, av(presentation.image))
    glyph.add (akBaselineOffset, av(presentation.baselineOffset))
    glyphWidth = presentation.image.width
  if node.range.length <= 0 or glyphWidth <= 0: return

  let markerFont = ctx.inlineMarkerFont
  let firstCharRange = rng(node.range.location, 1)
  let firstChar = ctx.text.substring(firstCharRange)
  var firstAttrs = glyph
  firstAttrs.add (akForegroundColor, av(clearColor))
  firstAttrs.add (akFont, av(markerFont))
  firstAttrs.add (akKern, av(glyphWidth - textWidth(ctx.widths, ctx.tm, firstChar, markerFont)))
  attrs.add (firstCharRange, firstAttrs)

  if node.range.length > 1:
    let restRange = rng(node.range.location + 1, node.range.length - 1)
    let restText = ctx.text.substring(restRange)
    attrs.add (restRange, @[(akForegroundColor, av(clearColor)),
                            (akFont, av(markerFont)),
                            (akKern, av(-hiddenRunKern(ctx, restText, markerFont)))])

proc directiveBodyFont(ctx: StylerContext, node: InlineNode, font: FontDesc,
                       attrs: var seq[StyledRange]): (FontDesc, bool) =
  ## Style a directive node and return the font its body's children must
  ## inherit — or `false` when `node` isn't a registered directive, in which
  ## case the caller falls through to ordinary extension-span handling.
  ##
  ## Self-contained calls return their inherited font unchanged: they have no
  ## body, and are handed to the glyph pass instead.
  let (directiveID, isDirective) = directiveIDForNodeID(node.extensionID)
  if not isDirective: return (font, false)
  # Linear scan, not a table build: registries hold a handful of directives and
  # this runs per directive NODE per restyle, so the allocation would cost more
  # than the scan. A directive unregistered since the parse degrades to plain
  # text rather than styling wrongly.
  let (directive, found) = ctx.config.directiveByID(directiveID)
  if not found: return (font, false)

  let marker = if directive.syntax.marker != 0: directive.syntax.marker
               else: ctx.config.directiveSettings.defaultMarker
  let context = DirectiveContext(theme: ctx.theme, inheritedFont: font,
                                 isActive: ctx.isActive(node.range),
                                 marker: marker, appearance: ctx.appearance)

  # A self-contained call is the whole node — no body to style, but it may draw
  # a glyph in place of its collapsed source.
  if node.markers.len == 0 or node.contentRange.length <= 0:
    let (argRange, hasArgs) = argumentsRangeInPrefix(ctx.text, node.range)
    let arguments = parseArguments(ctx.text, argRange, hasArgs,
                                   directive.syntax.parameters)
    presentSelfContained(ctx, node,
                         directive.presentation(arguments, context), font,
                         context.isActive, attrs)
    return (font, true)

  let (argRange, hasArgs) = argumentsRangeInPrefix(ctx.text, node.markers[0])
  let arguments = parseArguments(ctx.text, argRange, hasArgs,
                                 directive.syntax.parameters)
  let style = directive.style(arguments, context)
  let bodyFont = style.font.apply(font)

  if style.attributes.len > 0:
    attrs.add (node.contentRange, style.attributes)
  # Emit the font even when the transform is a no-op: the body inherits it
  # explicitly, so a later pass can't leave part of the span on a stale font.
  attrs.add (node.contentRange, @[(akFont, av(bodyFont))])
  # Directive syntax is not prose — no spell-check underlines on it.
  for marker in node.markers:
    attrs.add (marker, @[(akSpellingState, av(0))])
  (bodyFont, true)

# ---------------------------------------------------------------------------
# Inlines (composing)
# ---------------------------------------------------------------------------

func traitsFor(kind: EmphasisKind): FontTraits {.inline.} =
  case kind
  of ekItalic: {ftItalic}
  of ekBold: {ftBold}
  of ekBoldItalic: {ftBold, ftItalic}

func contentOf(markers: seq[Range]): Range {.inline.} =
  let start = maxRange(markers[0])
  rng(start, markers[1].location - start)

func codeMarkersOf(r, content: Range): seq[Range] {.inline.} =
  ## The two backtick marker ranges of an inline code span (range minus
  ## content).
  @[rng(r.location, content.location - r.location),
    rng(maxRange(content), maxRange(r) - maxRange(content))]

proc styleWikiLink(ctx: StylerContext, r, name: Range, markers: seq[Range],
                   attrs: var seq[StyledRange]) =
  attrs.add (r, @[(akSpellingState, av(0))])
  let nodeName = ctx.text.substring(name)
  var linkID = ""
  var hasLinkID = false
  if ctx.wikiLinkID != nil:
    (linkID, hasLinkID) = ctx.wikiLinkID(r)
  var contentAttrs: Attrs = @[]
  if hasLinkID:
    contentAttrs.add (akWikiLinkID, av(linkID))
  if not ctx.isActive(r):
    # Resolve by the stable id when present.
    let (resolution, resolved) = ctx.config.services.wikiLinks.resolve(
      if hasLinkID: linkID else: nodeName, name)
    if resolved and resolution.exists:
      contentAttrs.add (akLink, av(if hasLinkID: linkID else: nodeName))
      # AppKit painted a `.link` run in the system link colour by itself; with
      # no text system underneath to do that, the colour has to be stated, or a
      # resolving wiki-link renders as plain body text and reads as broken.
      contentAttrs.add (akForegroundColor, av(ctx.theme.link))
    else:
      contentAttrs.add (akForegroundColor, av(ctx.theme.disabledText))
  if contentAttrs.len > 0:
    attrs.add (name, contentAttrs)
  for marker in markers:
    attrs.add (marker, @[(akForegroundColor, av(ctx.theme.mutedText))])

proc styleInlines(ctx: StylerContext, nodes: seq[InlineNode], font: FontDesc,
                  attrs: var seq[StyledRange])

proc styleLink(ctx: StylerContext, node: InlineNode, font: FontDesc,
               attrs: var seq[StyledRange]) =
  attrs.add (node.range, @[(akSpellingState, av(0))])
  var urlString = ctx.text.substring(node.urlRange)
  if not urlString.contains("://"):
    urlString = "https://" & urlString
  let active = ctx.isActive(node.range)
  if urlString.len > 0:
    if active:
      attrs.add (node.contentRange,
                 @[(akForegroundColor,
                    av(withAlpha(ctx.theme.link, ctx.config.link.activeLinkAlpha)))])
    else:
      attrs.add (node.contentRange, @[(akLink, av(urlString)),
                                      (akUnderlineStyle, av(ulSingle)),
                                      (akForegroundColor, av(ctx.theme.link))])
  for marker in node.markers:
    attrs.add (marker, @[(akForegroundColor, av(ctx.theme.mutedText))])
  # The target is syntax, revealed with its brackets and muted like them — at
  # body colour it is louder than the label it belongs to.
  if active:
    attrs.add (node.urlRange, @[(akForegroundColor, av(ctx.theme.mutedText))])
  styleInlines(ctx, node.children, font, attrs)

proc styleInlines(ctx: StylerContext, nodes: seq[InlineNode], font: FontDesc,
                  attrs: var seq[StyledRange]) =
  for node in nodes:
    case node.kind
    of inText:
      discard

    of inEmphasis:
      let composed = font.adding(traitsFor(node.emphasis))
      attrs.add (contentOf(node.markers), @[(akFont, av(composed))])
      if ctx.isActive(node.range):
        for marker in node.markers:
          attrs.add (marker, @[(akForegroundColor, av(ctx.theme.mutedText))])
      styleInlines(ctx, node.children, composed, attrs)

    of inExt:
      # Directives come through the same node shape under a reserved id
      # namespace. They compose a font TRANSFORM over the inherited font and
      # hand it down, so emphasis nested in the body keeps both
      # (`@font(size: 18){**bold**}` is bold AND 18pt). Non-directive nodes
      # fall through unchanged.
      let (bodyFont, isDirective) = directiveBodyFont(ctx, node, font, attrs)
      if isDirective:
        if ctx.isActive(node.range):
          for marker in node.markers:
            attrs.add (marker, @[(akForegroundColor, av(ctx.theme.mutedText))])
        styleInlines(ctx, node.children, bodyFont, attrs)
      else:
        # Extension-contributed span: the extension supplies content ATTRIBUTES
        # only; every range comes from the parser, so a misbehaving extension
        # can restyle its own span at worst.
        let (ext, found) = ctx.config.extensionByID(node.extensionID)
        if found:
          attrs.add (node.contentRange, ext.contentAttributes(ctx.theme))
        if ctx.isActive(node.range):
          for marker in node.markers:
            attrs.add (marker, @[(akForegroundColor, av(ctx.theme.mutedText))])
        styleInlines(ctx, node.children, font, attrs)

    of inCode:
      attrs.add (node.contentRange, @[(akFont, av(ctx.codeFont)),
                                      (akBackgroundColor, av(ctx.codeBackground))])
      # Suppress spell-check underlines on inline code spans (markers +
      # content).
      attrs.add (node.range, @[(akSpellingState, av(0))])
      let markerAttrs: Attrs =
        if ctx.isActive(node.range):
          @[(akForegroundColor, av(ctx.theme.mutedText)), (akFont, av(ctx.codeFont))]
        else:
          @[(akForegroundColor,
             av(withAlpha(ctx.theme.mutedText, ctx.config.markers.inlineCodeMarkerAlpha))),
            (akFont, av(ctx.inlineMarkerFont))]
      for marker in codeMarkersOf(node.range, node.contentRange):
        attrs.add (marker, markerAttrs)

    of inLink:
      styleLink(ctx, node, font, attrs)

    of inWikiLink:
      styleWikiLink(ctx, node.range, node.contentRange, node.markers, attrs)

    of inImage, inImageEmbed, inInlineLatex, inEscape:
      discard   # handled by the facade's image / LaTeX passes

# ---------------------------------------------------------------------------
# Marker shrinking (hide syntax of inactive nodes)
# ---------------------------------------------------------------------------

proc shrink(ctx: StylerContext, markers: seq[Range], attrs: var seq[StyledRange]) =
  for marker in markers:
    attrs.add (marker, ctx.shrinkAttrs())

proc shrinkInlineMarkers(ctx: StylerContext, nodes: seq[InlineNode],
                         forceReveal: bool, attrs: var seq[StyledRange]) =
  ## Shrink inactive markers; an active ancestor reveals its whole subtree via
  ## `forceReveal`.
  for node in nodes:
    case node.kind
    of inEmphasis:
      let active = forceReveal or ctx.isActive(node.range)
      if not active: shrink(ctx, node.markers, attrs)
      shrinkInlineMarkers(ctx, node.children, active, attrs)
    of inExt:
      let active = forceReveal or ctx.isActive(node.range)
      if not active: shrink(ctx, node.markers, attrs)
      shrinkInlineMarkers(ctx, node.children, active, attrs)
    of inLink:
      let active = forceReveal or ctx.isActive(node.range)
      if not active:
        shrink(ctx, node.markers, attrs)
        if node.markers.len >= 4:   # also hide the "(url)" run
          let hide = rng(node.markers[2].location,
                         maxRange(node.markers[3]) - node.markers[2].location)
          attrs.add (hide, @[(akFont, av(ctx.inlineMarkerFont)),
                             (akForegroundColor, av(clearColor))])
      shrinkInlineMarkers(ctx, node.children, active, attrs)
    of inWikiLink, inImage:
      if not (forceReveal or ctx.isActive(node.range)):
        shrink(ctx, node.markers, attrs)
    of inEscape:
      if not (forceReveal or ctx.isActive(node.range)):
        shrink(ctx, @[node.markers[0]], attrs)
    of inText, inCode, inImageEmbed, inInlineLatex:
      discard   # own marker handling / not shrunk

proc shrinkInactiveMarkers(ctx: StylerContext, blocks: seq[BlockNode],
                           attrs: var seq[StyledRange]) =
  ## Collapse inactive nodes' markers to a tiny kerned font so syntax
  ## vanishes; code/LaTeX skip themselves.
  for b in blocks:
    if not ctx.inScope(b.range): continue
    case b.kind
    of bnHeading:
      if not ctx.isActive(b.range): shrink(ctx, b.markers, attrs)
      shrinkInlineMarkers(ctx, b.inlines, false, attrs)
    of bnParagraph, bnBlockquote:
      shrinkInlineMarkers(ctx, b.inlines, false, attrs)
    of bnList:
      # Shrink only inline markers; the list marker is hidden by the
      # bullet/task pass.
      for item in b.items:
        shrinkInlineMarkers(ctx, item.inlines, false, attrs)
    of bnExt:
      shrinkInlineMarkers(ctx, b.ext.inlines, false, attrs)
    of bnCodeBlock, bnBlockLatex, bnTable, bnThematicBreak, bnBlank:
      discard

# ---------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------

proc styleExtensionBlock(ctx: StylerContext, node: ExtensionBlockNode,
                         font: FontDesc, attrs: var seq[StyledRange]) =
  ## Extension fenced block: the extension supplies content ATTRIBUTES only;
  ## they cover the WHOLE block (fence lines included) so the block reads as
  ## one cohesive band — the hidden fences would otherwise sit as uncoloured
  ## blank rows above and below the body. Fence lines then mute while the caret
  ## is inside the block and hide otherwise (mirroring code fences — clear
  ## colour, unchanged font, so the line keeps its height and layout stays
  ## stable across the active flip).
  let (ext, found) = ctx.config.extensionByID(node.extensionID)
  if found:
    # Keep the block's trailing newline out, so the band doesn't bleed a
    # full-width background onto the following line.
    let band = ctx.text.trimmedTrailingNewlines(node.range)
    if band.length > 0:
      attrs.add (band, ext.contentAttributes(ctx.theme))
  let markerAttrs: Attrs =
    if ctx.isActive(node.range): @[(akForegroundColor, av(ctx.theme.mutedText))]
    else: @[(akForegroundColor, av(clearColor))]
  attrs.add (node.openFence, markerAttrs)
  if node.hasCloseFence:
    attrs.add (node.closeFence, markerAttrs)
  styleInlines(ctx, node.inlines, font, attrs)

proc styleBlock(ctx: StylerContext, b: BlockNode, font: FontDesc,
                attrs: var seq[StyledRange]) =
  case b.kind
  of bnParagraph:
    styleInlines(ctx, b.inlines, font, attrs)

  of bnHeading:
    let multiplier = ctx.config.headings.fontMultiplier(b.level)
    let headingBase = initFont(ctx.fontName, ctx.baseFont.size * multiplier)
    let headingFont = headingBase.adding({ftBold})
    let headingLineHeight = lineHeight(ctx.tm, headingFont) + 1
    let headingPara = newParagraphStyle()
    headingPara.minimumLineHeight = headingLineHeight
    headingPara.maximumLineHeight = headingLineHeight
    headingPara.paragraphSpacingBefore =
      headingFont.size * ctx.config.headings.topSpacing(b.level)
    headingPara.paragraphSpacing = ctx.baseParagraphSpacing
    attrs.add (ctx.text.paragraphRange(b.range),
               @[(akParagraphStyle, av(headingPara))])
    attrs.add (b.range, @[(akFont, av(headingFont))])
    for marker in b.markers:
      attrs.add (marker, @[(akForegroundColor, av(ctx.theme.headingMarker))])
    styleInlines(ctx, b.inlines, headingFont, attrs)

  of bnBlockquote:
    styleBlockquote(ctx, b.range, attrs)
    styleInlines(ctx, b.inlines, font, attrs)

  of bnList:
    for item in b.items:
      let hasNumber = ctx.orderedDisplayNumbers.hasKey(item.marker.location)
      let number = if hasNumber: ctx.orderedDisplayNumbers[item.marker.location] else: 0
      styleListItem(ctx, item, number, hasNumber, attrs)
      styleInlines(ctx, item.inlines, font, attrs)

  of bnCodeBlock:
    styleCodeBlock(ctx, b.range, attrs)
  of bnThematicBreak:
    styleThematicBreak(ctx, b.range, attrs)
  of bnExt:
    styleExtensionBlock(ctx, b.ext, font, attrs)
  of bnBlockLatex, bnTable, bnBlank:
    discard   # the facade's image / table passes own these

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc makeStylerContext*(t: Utf16Text, config: MarkdownEditorConfiguration,
                        tm: TextMetrics, widths: WidthCache,
                        appearance: Appearance, caretLocation: int,
                        selection: Range, hasSelection: bool,
                        wikiLinkID: WikiLinkIDProvider,
                        scopedRanges: seq[Range], hasScope: bool,
                        blocks: seq[BlockNode]): StylerContext =
  let fontName = config.fontName
  let fontSize = config.fontSize
  let baseFont = initFont(fontName, fontSize)
  let baseLineHeight = lineHeight(tm, baseFont)
  let baseParagraphSpacing = ceil(baseLineHeight * config.paragraph.spacingFactor)
  let codeFontSize = round(fontSize * config.codeBlock.fontSizeScale)
  let hiddenSize = config.markers.hiddenMarkerFontSize
  let codeFont = config.services.syntaxHighlighter.codeFont(codeFontSize)
  let codeLineHeight = lineHeight(tm, codeFont)

  let codePara = newParagraphStyle()
  codePara.lineBreakMode = lbCharWrapping
  codePara.lineSpacing = 0
  codePara.paragraphSpacingBefore = config.codeBlock.paragraphSpacing
  codePara.paragraphSpacing = config.codeBlock.paragraphSpacing
  codePara.headIndent = config.codeBlock.horizontalIndent
  codePara.firstLineHeadIndent = config.codeBlock.horizontalIndent
  codePara.tailIndent = -config.codeBlock.horizontalIndent
  codePara.minimumLineHeight = codeLineHeight
  codePara.maximumLineHeight = codeLineHeight

  StylerContext(
    text: t, config: config, tm: tm, widths: widths, appearance: appearance,
    fontName: fontName, baseFont: baseFont, baseLineHeight: baseLineHeight,
    baseParagraphSpacing: baseParagraphSpacing, codeFont: codeFont,
    codeBackground: config.services.syntaxHighlighter.backgroundColor(),
    codeParagraphStyle: codePara,
    inlineMarkerFont: initFont(fontName, hiddenSize),
    caret: caretLocation, selection: selection, hasSelection: hasSelection,
    wikiLinkID: wikiLinkID, scopedRanges: scopedRanges, hasScope: hasScope,
    orderedDisplayNumbers: computeOrderedDisplayNumbers(blocks, t))

proc styleAST*(t: Utf16Text, config: MarkdownEditorConfiguration,
               tm = defaultTextMetrics, widths: WidthCache = nil,
               appearance = apLight, caretLocation = -1,
               selection = Range(), hasSelection = false,
               wikiLinkID: WikiLinkIDProvider = nil,
               scopedRanges: seq[Range] = @[], hasScope = false,
               precomputedBlocks: seq[Block] = @[],
               hasPrecomputed = false): seq[StyledRange] =
  ## Walk the AST and emit the document's styled ranges.
  ##
  ## `precomputedBlocks` is the keystroke's own parse state: without it the
  ## document is parsed a SECOND time here (the rebuild already parsed it).
  ## It is resolved ahead of the context because the ordered-list display
  ## numbers are derived from these blocks.
  let registry = config.extensionRegistry()
  let blocks = parseDocument(t, scopedRanges, hasScope, precomputedBlocks,
                             hasPrecomputed, registry)
  let ctx = makeStylerContext(t, config, tm, widths, appearance, caretLocation,
                              selection, hasSelection, wikiLinkID, scopedRanges,
                              hasScope, blocks)
  var attrs: seq[StyledRange] = @[]
  for b in blocks:
    if ctx.inScope(b.range):
      styleBlock(ctx, b, ctx.baseFont, attrs)
  shrinkInactiveMarkers(ctx, blocks, attrs)

  # Text passes (AST-agnostic); AST code ranges drive the "skip inside code"
  # checks.
  let codeRanges = collectCodeRanges(blocks)
  let checkboxRanges = collectCheckboxRanges(blocks)
  let linkRanges = collectLinkRanges(blocks)
  styleAutoLinks(ctx, codeRanges, linkRanges, attrs)
  styleIncompleteLinkBrackets(ctx, codeRanges, checkboxRanges, linkRanges, attrs)
  attrs
