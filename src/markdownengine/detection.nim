## detection.nim
## MarkdownEngine (Nim port)
##
## Helper checks for questions like "is the cursor inside code or LaTeX?" and
## "which Markdown part is currently active?" — the caret-aware signals the
## text view and styler read to decide whether a construct reveals its source.

import std/sets
import ./ranges, ./utf16text, ./extension, ./token, ./tokenizer

proc computeActiveTokenIndices*(selectionRange: Range,
                                tokens: seq[MarkdownToken], t: Utf16Text,
                                suppressed = false): HashSet[int] =
  ## Read-only mode (no caret) hides all tokens regardless of any trailing
  ## selection.
  result = initHashSet[int]()
  if suppressed: return
  let caretLocation = selectionRange.location
  for index, tok in tokens:
    let start = tok.range.location
    let stop = maxRange(tok.range)
    if selectionRange.length > 0 and
       (tok.kind == tkInlineLatex or tok.kind == tkBlockLatex) and
       intersects(selectionRange, tok.range):
      result.incl index
      continue
    if caretLocation >= start and caretLocation < stop:
      result.incl index
      continue
    if caretLocation == stop:
      let lastIndex = stop - 1
      if lastIndex >= start and lastIndex < t.len:
        if not isLineBreakUnit(t.charAt(lastIndex)):
          result.incl index

  # When a container token (e.g. a table) is active, every inline token inside
  # it becomes active too.
  var activeContainers: seq[Range] = @[]
  for idx in result:
    if tokens[idx].kind == tkTable: activeContainers.add tokens[idx].range
  if activeContainers.len > 0:
    for i, tok in tokens:
      if i in result: continue
      for container in activeContainers:
        if tok.range.location >= container.location and
           maxRange(tok.range) <= maxRange(container):
          result.incl i
          break

# ---------------------------------------------------------------------------
# Code-block detection
# ---------------------------------------------------------------------------

func isInsideCodeBlock*(range: Range, codeTokens: seq[MarkdownToken]): bool =
  ## Fast: uses pre-parsed tokens.
  if codeTokens.len == 0: return false
  for tok in codeTokens:
    let start = tok.range.location
    let stop = start + tok.range.length
    if range.length == 0:
      if range.location >= start and range.location <= stop: return true
    else:
      if range.location < stop and range.location + range.length > start: return true
  false

func isInsideCodeBlock*(location: int, codeTokens: seq[MarkdownToken]): bool {.inline.} =
  isInsideCodeBlock(caretAt(location), codeTokens)

proc codeTokensOf*(tokens: seq[MarkdownToken]): seq[MarkdownToken] =
  for tok in tokens:
    if tok.kind == tkCodeBlock or tok.kind == tkInlineCode: result.add tok

proc latexTokensOf*(tokens: seq[MarkdownToken]): seq[MarkdownToken] =
  for tok in tokens:
    if tok.kind == tkInlineLatex or tok.kind == tkBlockLatex: result.add tok

proc isInsideCodeBlock*(range: Range, t: Utf16Text,
                        registry = emptyRegistry()): bool =
  ## Slow: parses tokens each call. Pass the editor's registry so the parse
  ## matches the styled document's grammar (an extension span can pre-claim
  ## text a built-in would otherwise recognize).
  isInsideCodeBlock(range, codeTokensOf(parseTokens(t, registry)))

proc isInsideCodeBlock*(location: int, t: Utf16Text,
                        registry = emptyRegistry()): bool {.inline.} =
  isInsideCodeBlock(caretAt(location), t, registry)

# ---------------------------------------------------------------------------
# Backtick census
# ---------------------------------------------------------------------------

func tripleBacktickCount*(t: Utf16Text): int =
  ## Count of non-overlapping ``` occurrences, scanning left to right.
  let length = t.len
  if length < 3: return 0
  var i = 0
  while i + 2 < length:                       # i can reach length - 3
    if t.charAt(i) == chBacktick and t.charAt(i + 1) == chBacktick and
       t.charAt(i + 2) == chBacktick:
      inc result
      i += 3
    else:
      inc i

func backtickWindowCount*(t: Utf16Text, range: Range): int =
  ## The ``` count contributed by the backtick runs that intersect `range`.
  ##
  ## The window expands through adjacent backticks on both sides, so every run
  ## inside it is a MAXIMAL run of the whole text — and the greedy global count
  ## is exactly Σ floor(runLen/3) over maximal runs, which makes these window
  ## counts composable: full = fullBefore − windowBefore + windowAfter.
  let length = t.len
  if range.location < 0 or maxRange(range) > length: return 0
  var lo = range.location
  while lo > 0 and t.charAt(lo - 1) == chBacktick: dec lo
  var hi = maxRange(range)
  while hi < length and t.charAt(hi) == chBacktick: inc hi
  var count = 0
  var run = 0
  var i = lo
  while i < hi:
    if t.charAt(i) == chBacktick:
      inc run
    else:
      count += run div 3
      run = 0
    inc i
  count + run div 3

# ---------------------------------------------------------------------------
# LaTeX detection
# ---------------------------------------------------------------------------

func isInsideLatex*(location: int, latexTokens: seq[MarkdownToken]): bool =
  if latexTokens.len == 0: return false
  for tok in latexTokens:
    let start = tok.range.location
    let stop = start + tok.range.length
    if location >= start and location <= stop: return true
  false

proc isInsideLatex*(location: int, t: Utf16Text,
                    registry = emptyRegistry()): bool =
  ## Slow: parses tokens each call. The registry matters here: a registered
  ## extension (e.g. `==$==$`) can claim characters that would otherwise pair
  ## into a phantom `$…$`, so parsing with an empty registry diverges from the
  ## styled document.
  isInsideLatex(location, latexTokensOf(parseTokens(t, registry)))
