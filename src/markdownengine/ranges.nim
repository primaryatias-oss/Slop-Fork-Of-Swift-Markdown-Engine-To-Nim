## ranges.nim
## MarkdownEngine (Nim port)
##
## `NSRange` and the handful of range primitives the whole engine is built on.
##
## **Invariant (inherited verbatim from the Swift engine):** ranges everywhere
## are absolute UTF-16 offsets into the source. The Swift original was
## TextKit-2 / `NSTextView` based, so UTF-16 was the native currency there; this
## port keeps it because every scanner, every marker range and every cache key
## in the parser is expressed in those units. See `utf16text.nim`.

type
  Range* = object
    ## UTF-16 offset + length, exactly `NSRange`'s shape.
    location*: int
    length*: int

const
  NotFound* = high(int)
    ## `NSNotFound`. A range carrying it is "absent", never a real span.

func initRange*(location, length: int): Range {.inline.} =
  Range(location: location, length: length)

func rng*(location, length: int): Range {.inline.} =
  ## Terse constructor for the scanners, which build thousands of these.
  Range(location: location, length: length)

func caretAt*(location: int): Range {.inline.} =
  Range(location: location, length: 0)

func notFoundRange*(): Range {.inline.} =
  Range(location: NotFound, length: 0)

func maxRange*(r: Range): int {.inline.} =
  ## `NSMaxRange`.
  r.location + r.length

func isEmpty*(r: Range): bool {.inline.} =
  r.length <= 0

func isValid*(r: Range): bool {.inline.} =
  r.location != NotFound and r.location >= 0 and r.length >= 0

func contains*(r: Range, location: int): bool {.inline.} =
  ## `NSLocationInRange` — the END is excluded, as in Foundation.
  location >= r.location and location < r.location + r.length

func containsRange*(outer, inner: Range): bool {.inline.} =
  inner.location >= outer.location and maxRange(inner) <= maxRange(outer)

func intersection*(a, b: Range): Range {.inline.} =
  ## `NSIntersectionRange`: a zero-length range when they don't overlap.
  let lo = max(a.location, b.location)
  let hi = min(maxRange(a), maxRange(b))
  if hi <= lo: Range(location: 0, length: 0) else: Range(location: lo, length: hi - lo)

func intersects*(a, b: Range): bool {.inline.} =
  intersection(a, b).length > 0

func union*(a, b: Range): Range {.inline.} =
  let lo = min(a.location, b.location)
  let hi = max(maxRange(a), maxRange(b))
  Range(location: lo, length: hi - lo)

func shifted*(r: Range, delta: int): Range {.inline.} =
  Range(location: r.location + delta, length: r.length)

func clamped*(r: Range, limit: int): Range =
  ## Clip to `[0, limit)`, so a stale range can never index out of the buffer.
  if r.location == NotFound: return Range(location: 0, length: 0)
  let lo = max(0, min(r.location, limit))
  let hi = max(lo, min(maxRange(r), limit))
  Range(location: lo, length: hi - lo)

func `$`*(r: Range): string =
  if r.location == NotFound: "{NotFound, " & $r.length & "}"
  else: "{" & $r.location & ", " & $r.length & "}"

func sortRanges*(ranges: seq[Range]): seq[Range] =
  ## Ascending by location, then by length — the order every containment walk
  ## in the inline parser assumes.
  result = ranges
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i - 1
    while j >= 0 and (result[j].location > cur.location or
                      (result[j].location == cur.location and result[j].length > cur.length)):
      result[j + 1] = result[j]
      dec j
    result[j + 1] = cur

func normalizeScopes*(ranges: seq[Range], documentLength: int): seq[Range] =
  ## Reject malformed ranges, then merge once, so every scoped consumer shares
  ## one monotonic view of the edit region (`DocumentAST.normalizeScopes`).
  var kept: seq[Range] = @[]
  for r in ranges:
    if r.location == NotFound or r.location < 0 or r.length <= 0: continue
    let endOffset = r.location + r.length
    if endOffset < r.location: continue            # overflow
    if endOffset > documentLength: continue
    kept.add r
  let sorted = sortRanges(kept)
  result = @[]
  for r in sorted:
    if result.len == 0:
      result.add r
      continue
    let previousEnd = maxRange(result[^1])
    if r.location > previousEnd:
      result.add r
    else:
      let newEnd = max(previousEnd, maxRange(r))
      result[^1].length = newEnd - result[^1].location

func anyIntersects*(scopes: seq[Range], r: Range): bool =
  for s in scopes:
    if intersects(s, r): return true
  false
