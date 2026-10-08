## wikilink.nim
## MarkdownEngine (Nim port)
##
## The generic wiki-link transformer.
##
## Wiki-links live in two forms:
##
## * Storage form — `[[Name|<opaque-id>]]`
## * Display form — `[[Name]]`
##
## This module converts between the two and maintains a metadata map that lets
## callers look up the storage range and identifier for any display occurrence.
## The identifier is opaque to the engine — a UUID, a slug, a database key,
## anything an embedder hands out via `WikiLinkResolver`.
##
## **Invariant:** wiki-link storage and display are DIFFERENT strings. Display
## IDs never leak into the binding.
##
## The Swift original used `NSRegularExpression` for both directions. The port
## uses hand scanners throughout: the engine has no regex engine of its own,
## and the display-form scan was already hand-written upstream (to replace a
## slow lookbehind), so this keeps one implementation for both directions.

import std/[strutils, tables]
import ./ranges, ./utf16text

type
  RangeKey* = object
    ## Hashable wrapper around a range so it can be a table key.
    location*: int
    length*: int

  LinkMetadata* = object
    ## Identifier and storage-side range associated with a display occurrence.
    id*: string
    hasID*: bool
    storageRange*: Range

  LinkMetadataTable* = Table[RangeKey, LinkMetadata]

func rangeKey*(r: Range): RangeKey {.inline.} =
  RangeKey(location: r.location, length: r.length)

func asRange*(k: RangeKey): Range {.inline.} =
  Range(location: k.location, length: k.length)

func hash*(k: RangeKey): int {.inline.} =
  k.location * 1_000_003 + k.length

# ---------------------------------------------------------------------------
# Hand scanners for the two forms
# ---------------------------------------------------------------------------

type
  StorageMatch* = object
    ## One `!?[[Name(|id)?]]` occurrence in storage text.
    range*: Range
    nameRange*: Range
    idRange*: Range
    hasID*: bool
    isImage*: bool

func storageLinkMatches*(t: Utf16Text): seq[StorageMatch] =
  ## Hand scan for `!?\[\[([^|\]\r\n]*)(?:\|([^\]\r\n]+))?\]\]`.
  let length = t.len
  if length < 4: return @[]
  var i = 0
  while i + 1 < length:
    if t.charAt(i) != chLBracket or t.charAt(i + 1) != chLBracket:
      inc i
      continue
    let isImage = i > 0 and t.charAt(i - 1) == chBang
    let start = if isImage: i - 1 else: i
    let contentStart = i + 2
    var k = contentStart
    var pipeIdx = -1
    var matched = false
    while k < length:
      let c = t.charAt(k)
      if c == chLF or c == chCR: break                 # newline → no match
      if c == chPipe and pipeIdx == -1:
        pipeIdx = k
      elif c == chRBracket:
        if k + 1 < length and t.charAt(k + 1) == chRBracket:
          # The name group rejects `|` and `]`; with a pipe present the id
          # group must be non-empty, else the whole candidate fails.
          var m = StorageMatch(range: rng(start, (k + 2) - start), isImage: isImage)
          if pipeIdx >= 0:
            if k - (pipeIdx + 1) <= 0:
              break                                    # `[[a|]]` → no match
            m.nameRange = rng(contentStart, pipeIdx - contentStart)
            m.idRange = rng(pipeIdx + 1, k - (pipeIdx + 1))
            m.hasID = true
          else:
            m.nameRange = rng(contentStart, k - contentStart)
            m.hasID = false
          result.add m
          i = k + 2
          matched = true
        break
      inc k
    if not matched: inc i

func displayLinkRanges*(t: Utf16Text): seq[tuple[range: Range, isImage: bool]] =
  ## Hand scan for display-form wiki links `(?<!!)\[\[...\]\]`.
  let length = t.len
  if length < 4: return @[]
  var i = 0
  while i + 1 < length:
    if t.charAt(i) != chLBracket or t.charAt(i + 1) != chLBracket:
      inc i
      continue
    let isImage = i > 0 and t.charAt(i - 1) == chBang     # preceded by `!`
    let start = if isImage: i - 1 else: i
    var j = i + 2
    var matched = false
    while j < length:
      let c = t.charAt(j)
      if c == chLF or c == chCR: break                    # newline → no match
      if c == chRBracket:
        if j + 1 < length and t.charAt(j + 1) == chRBracket:
          result.add (rng(start, (j + 2) - start), isImage)
          i = j + 2
          matched = true
        break
      inc j
    if not matched: inc i

# ---------------------------------------------------------------------------
# Storage → display
# ---------------------------------------------------------------------------

func bareID(linkID: string): string =
  ## The uuid part of an opaque suffix, which for an image embed is
  ## `uuid|width`.
  let cut = linkID.find('|')
  if cut < 0: linkID else: linkID[0 ..< cut]

func isUnsafeLiveName(name: string): bool =
  for ch in name:
    if ch == '|' or ch == ']' or ch == '\n' or ch == '\r': return true
  false

proc makeDisplayState*(storage: Utf16Text,
                       nameForID: proc (id: string): (string, bool) {.closure, gcsafe.} = nil):
                      (string, LinkMetadataTable) =
  ## Convert storage form `[[Name|<id>]]` to display `[[Name]]`, returning a
  ## display-range metadata map.
  ##
  ## When `nameForID` is supplied, each matched link's stored label is replaced
  ## in the DISPLAY text by the target's current name looked up via the opaque
  ## suffix's uuid (the suffix itself — uuid for links, `uuid|width` for images
  ## — is preserved unchanged in the metadata). Unknown, empty or unsafe live
  ## names fall back to the stored label.
  var display = ""
  var metadata = initTable[RangeKey, LinkMetadata]()
  var cursor = 0
  var displayLength = 0

  for m in storageLinkMatches(storage):
    let prefixLength = m.range.location - cursor
    if prefixLength > 0:
      let prefix = storage.substring(rng(cursor, prefixLength))
      display.add prefix
      displayLength += utf16Len(prefix)
      cursor += prefixLength

    let name = storage.substring(m.nameRange)
    let linkID = if m.hasID: storage.substring(m.idRange) else: ""

    # Auto-sync the DISPLAY label to the target's current name (looked up by
    # the uuid carried in the suffix). The suffix in the metadata stays
    # untouched.
    var displayName = name
    if m.hasID and nameForID != nil:
      let (live, ok) = nameForID(bareID(linkID))
      if ok and live.len > 0 and not isUnsafeLiveName(live):
        displayName = live

    let fragment = (if m.isImage: "![[" else: "[[") & displayName & "]]"
    let fragmentLength = utf16Len(fragment)
    let displayRange = rng(displayLength, fragmentLength)
    display.add fragment
    displayLength += fragmentLength

    metadata[rangeKey(displayRange)] = LinkMetadata(
      id: linkID, hasID: m.hasID, storageRange: m.range)
    cursor = maxRange(m.range)

  if cursor < storage.len:
    display.add storage.substring(rng(cursor, storage.len - cursor))
  (display, metadata)

proc makeDisplayState*(storageText: string,
                       nameForID: proc (id: string): (string, bool) {.closure, gcsafe.} = nil):
                      (string, LinkMetadataTable) {.inline.} =
  makeDisplayState(initText(storageText), nameForID)

# ---------------------------------------------------------------------------
# Display → storage
# ---------------------------------------------------------------------------

proc makeStorageState*(display: Utf16Text, existingMetadata: LinkMetadataTable,
                       idAt: proc (location: int): (string, bool) {.closure, gcsafe.} = nil):
                      (string, LinkMetadataTable) =
  ## Convert display `[[Name]]` back to storage `[[Name|<id>]]`, preferring the
  ## id carried by the text storage's own attribute (`idAt`) over the previous
  ## metadata map.
  # No `[[` anywhere → storage == display; skip the O(document) rebuild.
  if rangeOf(display, "[[").location == NotFound:
    return ($display, initTable[RangeKey, LinkMetadata]())

  var storage = ""
  var metadata = initTable[RangeKey, LinkMetadata]()
  var cursor = 0
  var storageLength = 0

  for (matchRange, isImage) in displayLinkRanges(display):
    let prefixLength = matchRange.location - cursor
    if prefixLength > 0:
      storage.add display.substring(rng(cursor, prefixLength))
      storageLength += prefixLength
      cursor += prefixLength

    let openMarker = if isImage: 3 else: 2
    let contentLength = max(0, matchRange.length - (openMarker + 2))
    let contentRange = rng(matchRange.location + openMarker, contentLength)
    let name = display.substring(contentRange)

    var linkID = ""
    var hasID = false
    if contentRange.length > 0 and idAt != nil:
      let (attr, ok) = idAt(contentRange.location)
      if ok and attr.len > 0:
        linkID = attr
        hasID = true
    if not hasID:
      let key = rangeKey(matchRange)
      if existingMetadata.hasKey(key):
        let meta = existingMetadata[key]
        if meta.hasID and meta.id.len > 0:
          linkID = meta.id
          hasID = true

    let marker = if isImage: "![[" else: "[["
    let fragment = if hasID: marker & name & "|" & linkID & "]]"
                   else: marker & name & "]]"
    let fragmentLength = utf16Len(fragment)
    let storageRange = rng(storageLength, fragmentLength)
    storage.add fragment
    storageLength += fragmentLength

    metadata[rangeKey(matchRange)] = LinkMetadata(id: linkID, hasID: hasID,
                                                  storageRange: storageRange)
    cursor = maxRange(matchRange)

  if cursor < display.len:
    storage.add display.substring(rng(cursor, display.len - cursor))
  (storage, metadata)

proc updatedStorageState*(display: Utf16Text, editedRange: Range,
                          changeInLength: int, previousStorage: Utf16Text,
                          previousMetadata: LinkMetadataTable):
                         (string, LinkMetadataTable, bool) =
  ## Incremental counterpart to `makeStorageState`: splice a single contiguous
  ## edit into the previous storage form in O(edit + #links).
  ##
  ## Outside link syntax, display and storage text are identical, so an edit
  ## that provably cannot create, destroy, or touch a link maps 1:1 into the
  ## storage string; links after the edit just shift by the length delta.
  ## Returns `false` whenever that proof fails — callers fall back to the full
  ## rebuild.
  let delta = changeInLength

  # `changeInLength` comes from the caller, and a caller with no trustworthy
  # delta passes a sentinel. Bound it before any arithmetic: the guard below
  # would reject it on its merits, but `editedRange.length - delta` overflows
  # first and takes the process with it.
  let bound = display.len + previousStorage.len + 4096
  if delta < -bound or delta > bound:
    return ("", initTable[RangeKey, LinkMetadata](), false)

  # Only contiguous, small, well-formed edits take the fast path.
  if editedRange.location == NotFound or editedRange.length < 0 or
     editedRange.length > 4096 or maxRange(editedRange) > display.len or
     editedRange.length - delta < 0:
    return ("", initTable[RangeKey, LinkMetadata](), false)

  let oldEditLength = editedRange.length - delta
  let oldEditRange = rng(editedRange.location, oldEditLength)

  # The edit must not create or complete link syntax: no `[[` or `]]` near it
  # in the NEW text (±3 covers a bracket typed against an existing one)…
  let probeStart = max(0, editedRange.location - 3)
  let probeEnd = min(display.len, maxRange(editedRange) + 3)
  let probe = display.substring(rng(probeStart, probeEnd - probeStart))
  if probe.contains("[[") or probe.contains("]]"):
    return ("", initTable[RangeKey, LinkMetadata](), false)

  # …and no existing link may overlap the edit (old display coordinates; ±3
  # also rejects edits adjacent to a link's markers).
  let guardRange = rng(max(0, oldEditRange.location - 3), oldEditLength + 6)
  for key in previousMetadata.keys:
    if intersects(key.asRange, guardRange):
      return ("", initTable[RangeKey, LinkMetadata](), false)

  # Map the display edit offset into storage coordinates: every link before the
  # edit is longer in storage by (storage length − display length).
  var storageOffsetDelta = 0
  for key, meta in previousMetadata:
    if key.location < editedRange.location:
      storageOffsetDelta += meta.storageRange.length - key.length
  let storageEditStart = editedRange.location + storageOffsetDelta
  if storageEditStart < 0 or storageEditStart + oldEditLength > previousStorage.len:
    return ("", initTable[RangeKey, LinkMetadata](), false)

  # Splice — outside links the replaced/inserted characters are identical in
  # both forms.
  let replacement = display.units(editedRange)
  let spliced = previousStorage.replacingCharacters(
    rng(storageEditStart, oldEditLength), replacement)

  # Shift every link after the edit by the delta; links before it are
  # untouched.
  var metadata = initTable[RangeKey, LinkMetadata]()
  for key, meta in previousMetadata:
    if key.location >= maxRange(oldEditRange):
      metadata[rangeKey(rng(key.location + delta, key.length))] = LinkMetadata(
        id: meta.id, hasID: meta.hasID,
        storageRange: rng(meta.storageRange.location + delta,
                          meta.storageRange.length))
    else:
      metadata[key] = meta
  (utf16ToString(spliced), metadata, true)

# ---------------------------------------------------------------------------
# Small helpers the text view uses
# ---------------------------------------------------------------------------

proc displayFragmentAndID*(storageFragment: string): (string, string, bool) =
  ## Split a storage fragment `[[Name|<id>]]` into its display form and the
  ## opaque id.
  let (display, metadata) = makeDisplayState(storageFragment)
  for _, meta in metadata:
    return (display, meta.id, meta.hasID)
  (display, "", false)

proc caretRangeAfterReplacing*(displayRange: Range,
                               storageFragment: string): Range =
  ## Zero-length caret range following replacement of `displayRange` with
  ## `storageFragment`.
  let (displayFragment, _) = makeDisplayState(storageFragment)
  caretAt(displayRange.location + utf16Len(displayFragment))
