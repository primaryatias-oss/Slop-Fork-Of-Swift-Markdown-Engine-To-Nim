## utf16text.nim
## MarkdownEngine (Nim port)
##
## The `NSString` stand-in: a UTF-16 code-unit buffer with the handful of
## primitives the engine actually used — `character(at:)`, `substring(with:)`,
## `lineRange(for:)`, `paragraphRange(for:)`, `range(of:)`.
##
## Why UTF-16 and not Nim's native UTF-8 `string`: every range in the parser,
## every marker, every cache key and every styled range in the Swift original
## is an absolute UTF-16 offset. Re-basing the engine on byte offsets would
## change the arithmetic in a few hundred places and silently diverge on
## astral-plane characters (emoji are one UTF-8 `string` slice but two UTF-16
## units). Keeping the native currency keeps the port 1:1 and the ranges
## interchangeable with the Swift test fixtures.

import std/[algorithm, unicode]
import ./ranges

type
  Utf16Text* = object
    ## Immutable-by-convention UTF-16 buffer. `units` is the whole document.
    units*: seq[uint16]

const
  chLF* = 0x0Au16
  chCR* = 0x0Du16
  chTab* = 0x09u16
  chSpace* = 0x20u16
  chHash* = 0x23u16
  chDollar* = 0x24u16
  chBang* = 0x21u16
  chQuote* = 0x22u16
  chPercent* = 0x25u16
  chAmp* = 0x26u16
  chLParen* = 0x28u16
  chRParen* = 0x29u16
  chAsterisk* = 0x2Au16
  chPlus* = 0x2Bu16
  chComma* = 0x2Cu16
  chDash* = 0x2Du16
  chDot* = 0x2Eu16
  chSlash* = 0x2Fu16
  chColon* = 0x3Au16
  chSemicolon* = 0x3Bu16
  chLT* = 0x3Cu16
  chEq* = 0x3Du16
  chGT* = 0x3Eu16
  chAt* = 0x40u16
  chLBracket* = 0x5Bu16
  chBackslash* = 0x5Cu16
  chRBracket* = 0x5Du16
  chCaret* = 0x5Eu16
  chUnderscore* = 0x5Fu16
  chBacktick* = 0x60u16
  chLBrace* = 0x7Bu16
  chPipe* = 0x7Cu16
  chRBrace* = 0x7Du16
  chTilde* = 0x7Eu16
  chNEL* = 0x0085u16        ## U+0085 NEXT LINE
  chLineSep* = 0x2028u16    ## U+2028 LINE SEPARATOR
  chParaSep* = 0x2029u16    ## U+2029 PARAGRAPH SEPARATOR

# ---------------------------------------------------------------------------
# Construction / conversion
# ---------------------------------------------------------------------------

func toUtf16*(s: string): seq[uint16] =
  ## UTF-8 → UTF-16 code units, surrogate-pairing anything above the BMP.
  result = newSeqOfCap[uint16](s.len)
  var i = 0
  while i < s.len:
    var cp = 0'i32
    let b0 = ord(s[i])
    var width = 1
    if b0 < 0x80:
      cp = int32(b0)
    elif (b0 and 0xE0) == 0xC0 and i + 1 < s.len:
      cp = int32(((b0 and 0x1F) shl 6) or (ord(s[i + 1]) and 0x3F)); width = 2
    elif (b0 and 0xF0) == 0xE0 and i + 2 < s.len:
      cp = int32(((b0 and 0x0F) shl 12) or ((ord(s[i + 1]) and 0x3F) shl 6) or
                 (ord(s[i + 2]) and 0x3F)); width = 3
    elif (b0 and 0xF8) == 0xF0 and i + 3 < s.len:
      cp = int32(((b0 and 0x07) shl 18) or ((ord(s[i + 1]) and 0x3F) shl 12) or
                 ((ord(s[i + 2]) and 0x3F) shl 6) or (ord(s[i + 3]) and 0x3F)); width = 4
    else:
      cp = 0xFFFD'i32                      # malformed byte → replacement char
    if cp > 0xFFFF:
      let v = cp - 0x10000
      result.add uint16(0xD800 + (v shr 10))
      result.add uint16(0xDC00 + (v and 0x3FF))
    else:
      result.add uint16(cp)
    i += width

func utf16ToString*(units: openArray[uint16]): string =
  ## UTF-16 code units → UTF-8, recombining surrogate pairs. An unpaired
  ## surrogate becomes U+FFFD rather than invalid UTF-8.
  result = newStringOfCap(units.len + units.len div 2)
  var i = 0
  while i < units.len:
    var cp = int(units[i])
    if cp >= 0xD800 and cp <= 0xDBFF and i + 1 < units.len and
       int(units[i + 1]) >= 0xDC00 and int(units[i + 1]) <= 0xDFFF:
      cp = 0x10000 + ((cp - 0xD800) shl 10) + (int(units[i + 1]) - 0xDC00)
      inc i
    elif cp >= 0xD800 and cp <= 0xDFFF:
      cp = 0xFFFD
    result.add $Rune(cp)
    inc i

func initText*(s: string): Utf16Text {.inline.} =
  Utf16Text(units: toUtf16(s))

func initText*(units: sink seq[uint16]): Utf16Text {.inline.} =
  Utf16Text(units: units)

func len*(t: Utf16Text): int {.inline.} = t.units.len

func charAt*(t: Utf16Text, i: int): uint16 {.inline.} =
  ## Out of bounds reads as 0, so the scanners can probe past the end freely
  ## (the Swift original guarded at every call site instead).
  if i < 0 or i >= t.units.len: 0u16 else: t.units[i]

func fullRange*(t: Utf16Text): Range {.inline.} =
  Range(location: 0, length: t.units.len)

func substring*(t: Utf16Text, r: Range): string =
  let c = clamped(r, t.units.len)
  if c.length <= 0: return ""
  utf16ToString(t.units.toOpenArray(c.location, c.location + c.length - 1))

func units*(t: Utf16Text, r: Range): seq[uint16] =
  let c = clamped(r, t.units.len)
  if c.length <= 0: return @[]
  t.units[c.location ..< c.location + c.length]

func `$`*(t: Utf16Text): string = utf16ToString(t.units)

func utf16Len*(s: string): int =
  ## UTF-16 length of a UTF-8 string without materialising the buffer.
  var i = 0
  while i < s.len:
    let b0 = ord(s[i])
    if b0 < 0x80: inc result; inc i
    elif (b0 and 0xE0) == 0xC0: inc result; i += 2
    elif (b0 and 0xF0) == 0xE0: inc result; i += 3
    elif (b0 and 0xF8) == 0xF0: result += 2; i += 4
    else: inc result; inc i

# ---------------------------------------------------------------------------
# Character classes
# ---------------------------------------------------------------------------

func isLineBreakUnit*(c: uint16): bool {.inline.} =
  c == chLF or c == chCR

func isLineTerminator*(c: uint16): bool {.inline.} =
  ## What `NSString.lineRange` breaks on.
  c == chLF or c == chCR or c == chNEL or c == chLineSep or c == chParaSep

func isParagraphTerminator*(c: uint16): bool {.inline.} =
  ## What `NSString.paragraphRange` breaks on — U+2028 LINE SEPARATOR
  ## deliberately absent: it ends a line, not a paragraph.
  c == chLF or c == chCR or c == chNEL or c == chParaSep

func isWhitespaceUnit*(c: uint16): bool {.inline.} =
  c == chSpace or c == chTab

func isWhitespaceOrNewlineUnit*(c: uint16): bool {.inline.} =
  c == chSpace or c == chTab or c == chLF or c == chCR or c == 0x0Bu16 or
  c == 0x0Cu16 or c == chNEL or c == 0x00A0u16 or c == chLineSep or
  c == chParaSep or (c >= 0x2000u16 and c <= 0x200Au16) or c == 0x3000u16

func isAsciiDigit*(c: uint16): bool {.inline.} =
  c >= 0x30u16 and c <= 0x39u16

func isAsciiLetter*(c: uint16): bool {.inline.} =
  (c >= 0x41u16 and c <= 0x5Au16) or (c >= 0x61u16 and c <= 0x7Au16)

func isAsciiAlnum*(c: uint16): bool {.inline.} =
  isAsciiLetter(c) or isAsciiDigit(c)

func isAsciiPunctuationUnit*(c: uint16): bool {.inline.} =
  ## CommonMark's ASCII punctuation set, used by escapes and emphasis flanking.
  (c >= 0x21u16 and c <= 0x2Fu16) or (c >= 0x3Au16 and c <= 0x40u16) or
  (c >= 0x5Bu16 and c <= 0x60u16) or (c >= 0x7Bu16 and c <= 0x7Eu16)

func isAlphanumericUnit*(c: uint16): bool =
  ## Unicode-aware enough for the directive boundary rule: ASCII alphanumerics
  ## plus the Latin-1/general letter and digit blocks. A surrogate half is NOT
  ## alphanumeric (the Swift original treated it as a boundary too).
  if isAsciiAlnum(c): return true
  if c >= 0xD800u16 and c <= 0xDFFFu16: return false
  if c < 0x00AAu16: return false
  let r = Rune(int(c))
  isAlpha(r) or (c >= 0x0660u16 and c <= 0x0669u16) or
    (c >= 0x06F0u16 and c <= 0x06F9u16) or (c >= 0x0966u16 and c <= 0x096Fu16) or
    (c >= 0xFF10u16 and c <= 0xFF19u16)

# ---------------------------------------------------------------------------
# Line / paragraph ranges
# ---------------------------------------------------------------------------

func lineRange*(t: Utf16Text, r: Range): Range =
  ## `NSString.lineRange(for:)`: expands to whole lines, trailing terminator
  ## INCLUDED. A zero-length range at a line start stays on that line.
  let len = t.units.len
  if len == 0: return Range(location: 0, length: 0)
  var start = max(0, min(r.location, len))
  var stop = max(start, min(maxRange(r), len))

  # Walk back to just after the previous terminator.
  while start > 0 and not isLineTerminator(t.units[start - 1]):
    dec start
  # A caret sitting right after a CRLF pair must not split the pair.
  if start > 0 and t.units[start - 1] == chLF and start >= 2 and
     t.units[start - 2] == chCR and start == stop and r.length == 0:
    discard

  # Walk forward past the terminator that ends this line.
  if stop == start and r.length == 0:
    stop = start
  while stop < len and not isLineTerminator(t.units[stop]):
    inc stop
  if stop < len:
    if t.units[stop] == chCR and stop + 1 < len and t.units[stop + 1] == chLF:
      stop += 2
    else:
      inc stop
  Range(location: start, length: stop - start)

func paragraphRange*(t: Utf16Text, r: Range): Range =
  ## `NSString.paragraphRange(for:)` — same walk, paragraph terminators only.
  let len = t.units.len
  if len == 0: return Range(location: 0, length: 0)
  var start = max(0, min(r.location, len))
  var stop = max(start, min(maxRange(r), len))
  while start > 0 and not isParagraphTerminator(t.units[start - 1]):
    dec start
  while stop < len and not isParagraphTerminator(t.units[stop]):
    inc stop
  if stop < len:
    if t.units[stop] == chCR and stop + 1 < len and t.units[stop + 1] == chLF:
      stop += 2
    else:
      inc stop
  Range(location: start, length: stop - start)

iterator lineRanges*(t: Utf16Text, within: Range): Range =
  ## Every physical line intersecting `within`, each including its terminator.
  var cursor = within.location
  let stop = maxRange(within)
  while cursor < stop:
    let line = lineRange(t, Range(location: cursor, length: 0))
    if line.length <= 0: break
    yield line
    cursor = maxRange(line)

func lineRangesIn*(t: Utf16Text, within: Range): seq[Range] =
  for line in lineRanges(t, within): result.add line

func trimmedTrailingNewlines*(t: Utf16Text, r: Range): Range =
  ## `r` minus its trailing CR/LF run — the shape the styler needs whenever a
  ## block range must not bleed a full-width background onto the next line.
  result = r
  while result.length > 0 and isLineBreakUnit(t.charAt(maxRange(result) - 1)):
    dec result.length

# ---------------------------------------------------------------------------
# Searching
# ---------------------------------------------------------------------------

func rangeOf*(t: Utf16Text, needle: seq[uint16], within: Range): Range =
  ## First occurrence of `needle` inside `within`; `NotFound` location if none.
  if needle.len == 0: return notFoundRange()
  let c = clamped(within, t.units.len)
  if c.length < needle.len: return notFoundRange()
  let last = maxRange(c) - needle.len
  var i = c.location
  while i <= last:
    var k = 0
    while k < needle.len and t.units[i + k] == needle[k]: inc k
    if k == needle.len: return Range(location: i, length: needle.len)
    inc i
  notFoundRange()

func rangeOf*(t: Utf16Text, needle: string, within: Range): Range {.inline.} =
  rangeOf(t, toUtf16(needle), within)

func rangeOf*(t: Utf16Text, needle: string): Range {.inline.} =
  rangeOf(t, needle, t.fullRange)

func contains*(t: Utf16Text, needle: string): bool {.inline.} =
  rangeOf(t, needle).location != NotFound

func matchesAt*(t: Utf16Text, i: int, chars: openArray[uint16]): bool =
  ## Exact UTF-16 sequence match at `i` (`InlineParser.matches`).
  if i < 0 or i + chars.len > t.units.len: return false
  for k in 0 ..< chars.len:
    if t.units[i + k] != chars[k]: return false
  true

func hasPrefixAt*(t: Utf16Text, r: Range, prefix: openArray[uint16]): bool {.inline.} =
  r.length >= prefix.len and matchesAt(t, r.location, prefix)

func rangeOfCharacterNotWhitespace*(t: Utf16Text, within: Range): Range =
  ## `rangeOfCharacter(from: .whitespacesAndNewlines.inverted)`: answers "was
  ## there content in the hole between two scoped blocks".
  let c = clamped(within, t.units.len)
  for i in c.location ..< maxRange(c):
    if not isWhitespaceOrNewlineUnit(t.units[i]):
      return Range(location: i, length: 1)
  notFoundRange()

func isBlankRange*(t: Utf16Text, r: Range): bool {.inline.} =
  rangeOfCharacterNotWhitespace(t, r).location == NotFound

# ---------------------------------------------------------------------------
# String-level helpers mirroring the Foundation calls the engine leaned on
# ---------------------------------------------------------------------------

func trimWhitespaceAndNewlines*(s: string): string =
  ## `trimmingCharacters(in: .whitespacesAndNewlines)`.
  var lo = 0
  var hi = s.len
  template isWs(ch: char): bool =
    ch in {' ', '\t', '\n', '\r', '\v', '\f'}
  while lo < hi and isWs(s[lo]): inc lo
  while hi > lo and isWs(s[hi - 1]): dec hi
  s[lo ..< hi]

func trimWhitespace*(s: string): string =
  var lo = 0
  var hi = s.len
  while lo < hi and (s[lo] == ' ' or s[lo] == '\t'): inc lo
  while hi > lo and (s[hi - 1] == ' ' or s[hi - 1] == '\t'): dec hi
  s[lo ..< hi]

func equalUnits*(a, b: openArray[uint16]): bool =
  ## The `memcmp` fast path the block/token caches hit on identical text.
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

func replacingCharacters*(t: Utf16Text, r: Range, replacement: seq[uint16]): seq[uint16] =
  let c = clamped(r, t.units.len)
  result = newSeqOfCap[uint16](t.units.len - c.length + replacement.len)
  for i in 0 ..< c.location: result.add t.units[i]
  for u in replacement: result.add u
  for i in maxRange(c) ..< t.units.len: result.add t.units[i]

func sortedUnique*(xs: seq[int]): seq[int] =
  result = xs
  result.sort()
  var w = 0
  for i in 0 ..< result.len:
    if i == 0 or result[i] != result[i - 1]:
      result[w] = result[i]
      inc w
  result.setLen(w)
