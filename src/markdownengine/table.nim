## table.nim
## MarkdownEngine (Nim port)
##
## GFM table parsing: source → header / alignments / rows.
##
## The Swift original rasterised the whole table into an `NSImage` and planted
## it on a collapsed source line. This port keeps the parse identical but stops
## there: the styler emits a table HANDLE and the renderer lays the grid out
## with the same text engine it uses for everything else. Nothing about the
## table's content model changes, and the editor gets crisp text at any scale
## instead of a bitmap.

import std/strutils
import ./utf16text

type
  TableAlignment* = enum
    taLeft
    taCenter
    taRight

  ParsedTable* = object
    header*: seq[string]
    alignments*: seq[TableAlignment]
    rows*: seq[seq[string]]

func parseTableRow*(line: string): seq[string] =
  ## Splits on UNESCAPED `|` only. GFM escapes the delimiter as `\|`, and the
  ## escape wins over every inline context (a table row is split before inline
  ## parsing runs) — so a cell holding ``` `a \| b` ``` is one cell, not two.
  ## Splitting on the raw character silently truncated such a row to the
  ## header's column count.
  var s = trimWhitespace(line)
  if s.startsWith("|"): s = s[1 .. ^1]
  if s.endsWith("|") and not (s.len >= 2 and s[s.len - 2] == '\\'):
    s = s[0 ..< s.len - 1]

  var current = ""
  var escaped = false
  for ch in s:
    if escaped:
      # Only the delimiter escape is resolved here; every other `\x` stays
      # intact so inline parsing still owns its own escapes.
      if ch == '|': current.add '|'
      else:
        current.add '\\'
        current.add ch
      escaped = false
    elif ch == '\\':
      escaped = true
    elif ch == '|':
      result.add trimWhitespace(current)
      current = ""
    else:
      current.add ch
  if escaped: current.add '\\'
  result.add trimWhitespace(current)

func parseTableAlignments*(line: string): seq[TableAlignment] =
  for cell in parseTableRow(line):
    let trimmed = trimWhitespace(cell)
    let leading = trimmed.startsWith(":")
    let trailing = trimmed.endsWith(":")
    if leading and trailing: result.add taCenter
    elif trailing: result.add taRight
    else: result.add taLeft

func parseTableSource*(source: string): (ParsedTable, bool) =
  var lines: seq[string] = @[]
  for raw in source.splitLines():
    if trimWhitespace(raw).len > 0: lines.add raw
  if lines.len < 2: return (ParsedTable(), false)

  let header = parseTableRow(lines[0])
  let alignments = parseTableAlignments(lines[1])
  if header.len == 0 or alignments.len == 0: return (ParsedTable(), false)

  let columnCount = max(header.len, alignments.len)

  proc padStrings(xs: seq[string], count: int): seq[string] =
    if xs.len == count: return xs
    if xs.len > count: return xs[0 ..< count]
    result = xs
    for _ in xs.len ..< count: result.add ""

  proc padAlignments(xs: seq[TableAlignment], count: int): seq[TableAlignment] =
    if xs.len == count: return xs
    if xs.len > count: return xs[0 ..< count]
    result = xs
    for _ in xs.len ..< count: result.add taLeft

  var rows: seq[seq[string]] = @[]
  for i in 2 ..< lines.len:
    rows.add padStrings(parseTableRow(lines[i]), columnCount)

  (ParsedTable(header: padStrings(header, columnCount),
               alignments: padAlignments(alignments, columnCount),
               rows: rows), true)

func expandCellLineBreaks*(raw: string): string =
  ## `<br>` → a real newline. A GFM row IS one source line, so `<br>` is the
  ## only in-cell line break the format has; without this it draws literally.
  var i = 0
  while i < raw.len:
    if raw[i] == '<' and i + 2 < raw.len and
       (raw[i + 1] == 'b' or raw[i + 1] == 'B') and
       (raw[i + 2] == 'r' or raw[i + 2] == 'R'):
      var k = i + 3
      while k < raw.len and (raw[k] == ' ' or raw[k] == '\t'): inc k
      if k < raw.len and raw[k] == '/': inc k
      if k < raw.len and raw[k] == '>':
        result.add '\n'
        i = k + 1
        continue
    result.add raw[i]
    inc i

func stableTableContentHash*(source: string): int =
  ## A content fingerprint stable across runs, so duplicate tables keep stable
  ## identities. FNV-1a over the UTF-16 units, which is what the ranges count.
  var h = 0x811C9DC5'u32
  for unit in toUtf16(source):
    h = h xor uint32(unit and 0xFFu16)
    h = h * 16777619'u32
    h = h xor uint32(unit shr 8)
    h = h * 16777619'u32
  int(h and 0x7FFFFFFF'u32)

func stableTableSourceID*(source: string, occurrenceIndex: int): int =
  ## Key for overlay reconcile and horizontal-offset persistence: content plus
  ## which occurrence of that content this is, so two identical tables in one
  ## document scroll independently.
  var h = uint32(stableTableContentHash(source))
  h = h xor uint32(occurrenceIndex * 2654435761'i64 and 0x7FFFFFFF'i64)
  h = h * 16777619'u32
  int(h and 0x7FFFFFFF'u32)
