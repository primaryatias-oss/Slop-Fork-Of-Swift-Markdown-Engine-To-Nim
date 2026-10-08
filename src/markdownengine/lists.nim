## lists.nim
## MarkdownEngine (Nim port)
##
## Line-shape scanners for list items, blockquotes, bullets and task
## checkboxes, shared by the styler (ordered-number seeding, caret-crossing
## helpers) and the input handlers (continuation, indent/outdent, toggles).
##
## The Swift original expressed these as `NSRegularExpression` patterns. The
## port hand-writes them: there is no regex engine in the Nim standard library,
## and the parser's own scanners were already hand-written for the same reason.
## Each scanner names the pattern it replaces so the two can be compared.

import ./ranges, ./utf16text

type
  ListLineMatch* = object
    ## `^\s*((?:(\d+)[.)]|[-•*+])(?:\s+\[[ xX]\])?\s+)`
    ##
    ## `prefix` is group 1 — the whole marker run including the trailing
    ## whitespace, which is what the continuation and outdent paths measure.
    ## `number` is group 2.
    prefix*: Range
    leadingWhitespace*: Range
    marker*: Range
    ordered*: bool
    number*: int
    hasNumber*: bool
    checkbox*: Range
    hasCheckbox*: bool
    checked*: bool

  BlockquoteLineMatch* = object
    ## `^( {0,3})(>+(?:[ \t]+>+)*)[ \t]*`
    ##
    ## The trailing `[ \t]*` is deliberate: the prefix length must cover the
    ## space(s) the continuation inserts (`markers + " "`), or exiting an empty
    ## quote leaves a stray space.
    range*: Range
    leadingWhitespace*: Range
    markers*: Range

func leadingWhitespaceRange*(t: Utf16Text, line: Range): Range =
  ## `^\s*` over a line range (spaces and tabs only — a line range never
  ## contains an interior newline).
  var i = line.location
  let stop = maxRange(line)
  while i < stop and isWhitespaceUnit(t.charAt(i)): inc i
  rng(line.location, i - line.location)

func indentLevel*(t: Utf16Text, whitespace: Range): int =
  ## One level per tab, one per two spaces — the engine's indent convention.
  var tabs = 0
  var spaces = 0
  for i in whitespace.location ..< maxRange(whitespace):
    if t.charAt(i) == chTab: inc tabs
    elif t.charAt(i) == chSpace: inc spaces
  tabs + (spaces div 2)

func indentLevel*(whitespace: string): int =
  var tabs = 0
  var spaces = 0
  for ch in whitespace:
    if ch == '\t': inc tabs
    elif ch == ' ': inc spaces
  tabs + (spaces div 2)

func matchListLine*(t: Utf16Text, line: Range): (ListLineMatch, bool) =
  ## Markers: `-`/`*`/`+` (raw Markdown) plus the legacy `•` (rendered, never
  ## typed).
  let stop = maxRange(line)
  var i = line.location
  while i < stop and isWhitespaceUnit(t.charAt(i)): inc i
  let wsRange = rng(line.location, i - line.location)
  if i >= stop: return (ListLineMatch(), false)

  let markerStart = i
  var ordered = false
  var number = 0
  var hasNumber = false
  let c = t.charAt(i)
  if c == chDash or c == chAsterisk or c == chPlus or c == 0x2022u16:   # - * + •
    inc i
  elif isAsciiDigit(c):
    var digits = 0
    var value = 0
    while i < stop and isAsciiDigit(t.charAt(i)) and digits < 9:
      value = value * 10 + int(t.charAt(i) - 0x30u16)
      inc i
      inc digits
    if i >= stop: return (ListLineMatch(), false)
    let punct = t.charAt(i)
    if punct != chDot and punct != chRParen: return (ListLineMatch(), false)
    inc i
    ordered = true
    number = value
    hasNumber = true
  else:
    return (ListLineMatch(), false)
  let markerRange = rng(markerStart, i - markerStart)

  # `(?:\s+\[[ xX]\])?` — whitespace then a checkbox.
  var checkbox = notFoundRange()
  var hasCheckbox = false
  var checked = false
  var afterMarker = i
  var probe = i
  while probe < stop and isWhitespaceUnit(t.charAt(probe)): inc probe
  if probe > i and probe + 2 < stop and t.charAt(probe) == chLBracket and
     t.charAt(probe + 2) == chRBracket:
    let mid = t.charAt(probe + 1)
    if mid == chSpace or mid == 0x78u16 or mid == 0x58u16:
      checkbox = rng(probe, 3)
      hasCheckbox = true
      checked = mid == 0x78u16 or mid == 0x58u16
      afterMarker = probe + 3

  # Trailing `\s+` — at least one whitespace unit is required.
  var tail = afterMarker
  while tail < stop and isWhitespaceUnit(t.charAt(tail)): inc tail
  if tail == afterMarker: return (ListLineMatch(), false)

  (ListLineMatch(prefix: rng(wsRange.location, tail - wsRange.location),
                 leadingWhitespace: wsRange, marker: markerRange,
                 ordered: ordered, number: number, hasNumber: hasNumber,
                 checkbox: checkbox, hasCheckbox: hasCheckbox, checked: checked),
   true)

func matchBlockquoteLine*(t: Utf16Text, line: Range): (BlockquoteLineMatch, bool) =
  let stop = maxRange(line)
  var i = line.location
  var indent = 0
  while indent < 3 and i < stop and isWhitespaceUnit(t.charAt(i)):
    inc i
    inc indent
  let wsRange = rng(line.location, i - line.location)
  if i >= stop or t.charAt(i) != chGT: return (BlockquoteLineMatch(), false)

  # `>+(?:[ \t]+>+)*`
  let markerStart = i
  var markerEnd = i
  while i < stop:
    if t.charAt(i) == chGT:
      inc i
      markerEnd = i
    elif isWhitespaceUnit(t.charAt(i)):
      var probe = i
      while probe < stop and isWhitespaceUnit(t.charAt(probe)): inc probe
      if probe < stop and t.charAt(probe) == chGT:
        i = probe
      else:
        break
    else:
      break
  # Trailing `[ \t]*`
  var tail = markerEnd
  while tail < stop and isWhitespaceUnit(t.charAt(tail)): inc tail
  (BlockquoteLineMatch(range: rng(line.location, tail - line.location),
                       leadingWhitespace: wsRange,
                       markers: rng(markerStart, markerEnd - markerStart)), true)

func matchDashNoSpace*(t: Utf16Text, line: Range): bool =
  ## `^\s*-(?!\s)` — a dash with no following whitespace.
  let stop = maxRange(line)
  var i = line.location
  while i < stop and isWhitespaceUnit(t.charAt(i)): inc i
  if i >= stop or t.charAt(i) != chDash: return false
  let next = i + 1
  next >= stop or not isWhitespaceOrNewlineUnit(t.charAt(next))

# ---------------------------------------------------------------------------
# Caret-crossing helpers the text view reads
# ---------------------------------------------------------------------------

func bulletSyntaxRange*(t: Utf16Text, location: int): (Range, bool) =
  ## `^([ \t]*)([-*+])([ \t]+)(?!\[[ xX]\])` — the `<marker><spaces>` range on
  ## `location`'s line, or `false` if the caret isn't strictly inside it.
  ##
  ## Bullet RENDERING (the `•` overlay) lives in the styler; this only reports
  ## caret membership so the editor can restyle on crossings.
  let safeLoc = max(0, min(location, t.len))
  let line = t.lineRange(caretAt(safeLoc))
  let stop = maxRange(line)
  var i = line.location
  while i < stop and isWhitespaceUnit(t.charAt(i)): inc i
  if i >= stop: return (notFoundRange(), false)
  let c = t.charAt(i)
  if c != chDash and c != chAsterisk and c != chPlus: return (notFoundRange(), false)
  let markerStart = i
  inc i
  let spacerStart = i
  while i < stop and isWhitespaceUnit(t.charAt(i)): inc i
  if i == spacerStart: return (notFoundRange(), false)   # `[ \t]+` required
  # `(?!\[[ xX]\])` — a checkbox means this is a task item, not a bullet.
  if i + 2 < stop and t.charAt(i) == chLBracket and t.charAt(i + 2) == chRBracket:
    let mid = t.charAt(i + 1)
    if mid == chSpace or mid == 0x78u16 or mid == 0x58u16:
      return (notFoundRange(), false)
  let syntax = rng(markerStart, i - markerStart)
  if contains(syntax, location): (syntax, true) else: (notFoundRange(), false)

func taskSyntaxRange*(t: Utf16Text, location: int): (Range, bool) =
  ## `^([ \t]*)([-*+])([ \t]+)(\[[ xX]\])` — the `- [ ]` syntax range on
  ## `location`'s line, or `false` if the caret isn't inside it (its end
  ## counts, so a caret right after `]` still reveals the source).
  let safeLoc = max(0, min(location, t.len))
  let line = t.lineRange(caretAt(safeLoc))
  let (m, ok) = matchListLine(t, line)
  if not ok or not m.hasCheckbox: return (notFoundRange(), false)
  let syntax = rng(m.marker.location, maxRange(m.checkbox) - m.marker.location)
  if contains(syntax, location) or location == maxRange(syntax):
    (syntax, true)
  else:
    (notFoundRange(), false)

func hrLineRange*(t: Utf16Text, location: int): (Range, bool) =
  ## The thematic-break line (minus its terminator) containing `location`, or
  ## `false` when that line isn't one.
  let safeLoc = max(0, min(location, t.len))
  let line = t.lineRange(caretAt(safeLoc))
  var content = t.trimmedTrailingNewlines(line)
  if content.length < 3: return (notFoundRange(), false)
  var i = content.location
  let stop = maxRange(content)
  while i < stop and isWhitespaceUnit(t.charAt(i)): inc i
  if i >= stop: return (notFoundRange(), false)
  let first = t.charAt(i)
  if first != chDash and first != chAsterisk and first != chUnderscore:
    return (notFoundRange(), false)
  var runLength = 0
  var k = i
  while k < stop:
    let c = t.charAt(k)
    if c == first: inc runLength
    elif not isWhitespaceUnit(c): return (notFoundRange(), false)
    inc k
  if runLength < 3: return (notFoundRange(), false)
  (content, true)
