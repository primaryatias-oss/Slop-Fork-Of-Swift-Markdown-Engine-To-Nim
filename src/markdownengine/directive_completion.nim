## directive_completion.nim
## MarkdownEngine (Nim port)
##
## What is the caret trying to complete?
##
## Autocomplete cannot read the AST: while you are typing, `@ico` and
## `@icon(sta` are not directives yet — the parser REJECTS them (no body, no
## closing paren), which is exactly right for STYLING and useless for
## COMPLETION. So this is a separate, deliberately forgiving scan backwards
## from the caret over the current line, bounded to 256 characters per caret
## move.
##
## It answers one question — "is the caret in a directive NAME, or in one of
## its ARGUMENTS?" — and hands back the range a pick should replace. The engine
## then asks the registry (for names) or the directive itself (for values) what
## the candidates are, so a newly registered directive appears in the picker
## with no embedder change. It reuses the parser's boundary rule, so it can
## never offer a directive the parser would refuse.

import std/[algorithm, strutils, tables]
import ./ranges, ./utf16text, ./directive, ./extension

type
  DirectiveCompletionKindKind* = enum
    dckName       ## typing the directive name: `@fo|`
    dckArgument   ## typing an argument value: `@icon(sta|`

  DirectiveCompletionKind* = object
    kind*: DirectiveCompletionKindKind
    label*: string   ## empty for a positional argument
    hasLabel*: bool
    index*: int      ## position among the arguments of the call

  CompletionCandidate* = object
    ## A single row in the embedder's picker. Uniform across name and value
    ## completion, so one list UI serves both.
    title*: string
      ## Primary text, e.g. `font` or `JP`.
    subtitle*: string
    detail*: string
      ## Optional preview of the RESULT — the flag for a country code, the
      ## glyph for a symbol. Shown by the picker; never inserted.
    insertion*: string
      ## Text that replaces `DirectiveCompletionContext.replacementRange`.
    caretOffset*: int
      ## Caret position within `insertion` after the pick, in UTF-16 units.
    hasCaretOffset*: bool
    symbolName*: string

  DirectiveCompletionContext* = object
    ## Everything the embedder needs to show a picker. `hasContext` false means
    ## "no picker".
    kind*: DirectiveCompletionKind
    marker*: uint16
    prefix*: string
      ## Text typed so far for the thing being completed (may be empty).
    replacementRange*: Range
      ## Document range a pick replaces.
    directiveID*: string
      ## The directive being called; empty while its name is still incomplete.
    candidates*: seq[CompletionCandidate]

  DirectiveCompletionRequest* = object
    ## Commit a picked candidate: the engine replaces the range, places the
    ## caret, and clears the request.
    documentID*: string
    replacementRange*: Range
    insertion*: string
    caretOffset*: int
    hasCaretOffset*: bool
    applied*: bool

proc completionRequest*(documentID: string,
                        context: DirectiveCompletionContext,
                        item: CompletionCandidate): DirectiveCompletionRequest =
  ## Commit object for a picked candidate: where to write, what to write, and
  ## where the caret lands. The embedder's picker builds one of these and
  ## hands it to the editor, so the UI never has to know how a snippet's
  ## caret marker was resolved.
  DirectiveCompletionRequest(documentID: documentID,
                             replacementRange: context.replacementRange,
                             insertion: item.insertion,
                             caretOffset: item.caretOffset,
                             hasCaretOffset: item.hasCaretOffset,
                             applied: false)

const maxScanback = 256
  ## Longest name we will scan backwards over before giving up. Bounds the work
  ## per caret move to a constant, independent of line length.

func nameKind*(): DirectiveCompletionKind {.inline.} =
  DirectiveCompletionKind(kind: dckName)

func argumentKind*(label: string, hasLabel: bool, index: int): DirectiveCompletionKind {.inline.} =
  DirectiveCompletionKind(kind: dckArgument, label: label, hasLabel: hasLabel,
                          index: index)

func candidateFrom*(completion: DirectiveCompletion): CompletionCandidate =
  ## Build from a directive's declared name-completion metadata, splitting the
  ## `|` caret marker out of the snippet.
  ##
  ## The offset is in UTF-16 units, not characters: it is added onto a range
  ## location, which counts UTF-16 code units. A character count lands the
  ## caret wrong — possibly mid-surrogate — for a snippet carrying any
  ## character outside the BMP before the `|` marker.
  let snippet = completion.snippet
  let caret = snippet.find('|')
  CompletionCandidate(
    title: completion.title, subtitle: completion.subtitle, detail: "",
    insertion: snippet.replace("|", ""),
    caretOffset: if caret >= 0: utf16Len(snippet[0 ..< caret]) else: 0,
    hasCaretOffset: caret >= 0,
    symbolName: completion.symbolName)

# ---------------------------------------------------------------------------
# Character classes
# ---------------------------------------------------------------------------

func isNameChar(c: uint16): bool {.inline.} =
  isAsciiLetter(c) or isAsciiDigit(c) or c == chUnderscore or c == chDash or c == chDot

func isIdentStartChar(c: uint16): bool {.inline.} =
  ## Mirrors the parser's `isIdentStart`, used to decide whether a `.`
  ## continues a namespaced name or ends it.
  isAsciiLetter(c) or c == chUnderscore

func isBoundaryChar(c: uint16): bool {.inline.} =
  not isAlphanumericUnit(c)

func isEscapedAt(t: Utf16Text, index: int): bool =
  var count = 0
  var k = index - 1
  while k >= 0 and t.charAt(k) == chBackslash:
    inc count
    dec k
  (count mod 2) == 1

# ---------------------------------------------------------------------------
# Marker
# ---------------------------------------------------------------------------

proc findMarker(t: Utf16Text, caret: int, registry: DirectiveRegistry): int =
  ## Nearest marker before `caret` that could open a directive, or -1. Stops at
  ## the line start, inside a body, and after `maxScanback` characters.
  var index = caret - 1
  let limit = max(0, caret - maxScanback)
  while index >= limit:
    let c = t.charAt(index)
    if c == chLF or c == chCR: return -1            # line start
    if c == chLBrace: return -1                      # inside a body, not a call
    if registry.byMarker.hasKey(c) and not isEscapedAt(t, index):
      # Same boundary rule the parser uses, so completion can't offer a
      # directive the parser would refuse to recognise.
      if index == 0: return index
      let previous = t.charAt(index - 1)
      if previous != c and isBoundaryChar(previous): return index
    dec index
  -1

# ---------------------------------------------------------------------------
# Name candidates
# ---------------------------------------------------------------------------

proc nameCandidates(prefix: string, table: Table[string, DirectiveEntry],
                    directives: seq[MarkdownDirective], marker: uint16,
                    nameOnly: bool): seq[CompletionCandidate] =
  ## Registry-filtered directive names. The engine owns this ranking, so a
  ## newly registered directive shows up with no embedder change.
  ##
  ## Candidates come from `table` — the registry's WINNING entries for this
  ## marker — not the raw configured list. The registry drops a directive with
  ## an empty name and resolves a duplicate name by "first registration wins";
  ## sourcing candidates from the unfiltered list could offer a name the parser
  ## will never actually recognize.
  let needle = prefix.toLowerAscii
  var registered: seq[MarkdownDirective] = @[]
  for entry in table.values:
    for d in directives:
      if d.id == entry.id:
        registered.add d
        break

  var matched: seq[MarkdownDirective] = @[]
  for d in registered:
    if needle.len == 0:
      matched.add d
      continue
    if d.syntax.name.toLowerAscii.startsWith(needle):
      matched.add d
      continue
    var keywordHit = false
    for kw in d.completion.keywords:
      if kw.toLowerAscii.startsWith(needle):
        keywordHit = true
        break
    if keywordHit: matched.add d

  # Name-prefix matches rank above keyword-only matches, then alphabetically —
  # stable and predictable while typing.
  matched.sort(proc (a, b: MarkdownDirective): int =
    let aName = a.syntax.name.toLowerAscii.startsWith(needle)
    let bName = b.syntax.name.toLowerAscii.startsWith(needle)
    if aName != bName:
      return if aName: -1 else: 1
    cmp(a.syntax.name, b.syntax.name))

  for d in matched:
    let item = candidateFrom(d.completion)
    if not nameOnly:
      result.add item
    else:
      # No snippet — a call already follows the name, so only the marker and
      # name are inserted; the caret lands at the end (right before the
      # existing `(` or `{`).
      result.add CompletionCandidate(
        title: item.title, subtitle: item.subtitle, detail: item.detail,
        insertion: utf16ToString([marker]) & d.syntax.name,
        caretOffset: 0, hasCaretOffset: false, symbolName: item.symbolName)

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

proc valueTokenEnd(t: Utf16Text, start: int): int =
  ## Scan forward from `start` to find the end of the current argument value —
  ## the first unescaped, unquoted `,` or `)` at depth 0, a line break, or the
  ## end of the string.
  var index = start
  var depth = 0
  var inQuote = false
  while index < t.len:
    let c = t.charAt(index)
    if c == chLF or c == chCR: return index
    if c == chQuote and not isEscapedAt(t, index):
      inQuote = not inQuote
      inc index
      continue
    if not inQuote and not isEscapedAt(t, index):
      if c == chLParen: inc depth
      if c == chRParen:
        if depth == 0: return index
        dec depth
      if c == chComma and depth == 0: return index
    inc index
  t.len

proc argumentContext(t: Utf16Text, caret, openParen: int, marker: uint16,
                     d: MarkdownDirective): (DirectiveCompletionContext, bool) =
  # The caret must be INSIDE the parens: no unescaped `)` between the opening
  # paren and the caret at depth 0, and no line break.
  var depth = 0
  var inQuote = false
  var segmentStart = openParen + 1
  var index = openParen + 1
  var argumentIndex = 0
  while index < caret:
    let c = t.charAt(index)
    if c == chLF or c == chCR: return (DirectiveCompletionContext(), false)
    if c == chQuote and not isEscapedAt(t, index): inQuote = not inQuote
    if not inQuote and not isEscapedAt(t, index):
      if c == chLParen: inc depth
      if c == chRParen:
        if depth == 0: return (DirectiveCompletionContext(), false)  # already closed
        dec depth
      if c == chComma and depth == 0:
        inc argumentIndex
        segmentStart = index + 1
    inc index

  # Split the current segment into an optional `label:` and the value typed so
  # far.
  var label = ""
  var hasLabel = false
  var valueStart = segmentStart
  var scan = segmentStart
  var quoted = false
  while scan < caret:
    let c = t.charAt(scan)
    if c == chQuote: quoted = not quoted
    if c == chColon and not quoted:
      label = trimWhitespace(t.substring(rng(segmentStart, scan - segmentStart)))
      hasLabel = true
      valueStart = scan + 1
      break
    inc scan
  # Leading whitespace belongs to the separator, not the value.
  while valueStart < caret and isWhitespaceUnit(t.charAt(valueStart)): inc valueStart
  # The value may continue past the caret (`@glyph(sta|r)`); a pick there must
  # replace the whole token or it leaves the tail dangling behind the inserted
  # candidate.
  let valueEnd = max(caret, valueTokenEnd(t, valueStart))

  # A quoted value (`@glyph("sta|r")`) wraps the content a candidate should
  # filter on and replace, not the quotes themselves.
  var contentStart = valueStart
  var contentEnd = valueEnd
  if contentStart < t.len and t.charAt(contentStart) == chQuote and
     not isEscapedAt(t, contentStart):
    inc contentStart
    if contentEnd > contentStart and t.charAt(contentEnd - 1) == chQuote and
       not isEscapedAt(t, contentEnd - 1):
      dec contentEnd
  let prefix = t.substring(rng(contentStart, max(0, caret - contentStart)))

  # Resolve which parameter this is.
  let schema = d.syntax.parameters
  var parameter: DirectiveParameter
  var found = false
  if hasLabel:
    for p in schema:
      if p.hasLabel and p.label == label:
        parameter = p
        found = true
        break
  else:
    var positional: seq[DirectiveParameter] = @[]
    for p in schema:
      if not p.hasLabel: positional.add p
    if argumentIndex < positional.len:
      parameter = positional[argumentIndex]
      found = true
  if not found: return (DirectiveCompletionContext(), false)

  var candidates: seq[CompletionCandidate] = @[]
  for item in d.valueCompletions(parameter, prefix):
    candidates.add CompletionCandidate(
      title: item.title, subtitle: item.subtitle, detail: item.detail,
      insertion: item.insertion, caretOffset: item.caretOffset,
      hasCaretOffset: item.hasCaretOffset, symbolName: item.symbolName)
  if candidates.len == 0: return (DirectiveCompletionContext(), false)

  (DirectiveCompletionContext(
    kind: argumentKind(label, hasLabel, argumentIndex), marker: marker,
    prefix: prefix, replacementRange: rng(contentStart, contentEnd - contentStart),
    directiveID: d.id, candidates: candidates), true)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc completionContext*(t: Utf16Text, caret: int, registry: DirectiveRegistry,
                        directives: seq[MarkdownDirective],
                        settings = defaultDirectiveSettings):
                       (DirectiveCompletionContext, bool) =
  ## Classify the caret, or `false` when it isn't completing a directive.
  if registry.isEmpty or caret < 0 or caret > t.len:
    return (DirectiveCompletionContext(), false)

  let markerIndex = findMarker(t, caret, registry)
  if markerIndex < 0: return (DirectiveCompletionContext(), false)
  let marker = t.charAt(markerIndex)
  if not registry.byMarker.hasKey(marker):
    return (DirectiveCompletionContext(), false)
  let table = registry.byMarker[marker]

  # Name run.
  var cursor = markerIndex + 1
  while cursor < caret and isNameChar(t.charAt(cursor)): inc cursor
  let nameRange = rng(markerIndex + 1, cursor - (markerIndex + 1))
  let name = t.substring(nameRange)

  if cursor == caret:
    # Still inside the name: complete the directive name itself.
    #
    # A bare marker (`Ping @|`) offers no context: every registered directive
    # would otherwise match, which captures Enter for "confirm" in ordinary
    # prose whenever a marker precedes it — the boundary rule keeps an email
    # address safe, but a marker after a plain space is not. Wait for at least
    # one typed character before showing anything.
    if name.len == 0: return (DirectiveCompletionContext(), false)

    # The name run above only looked at characters BEFORE the caret, so a pick
    # made with the caret in the middle of an existing name (`@fo|nt`) would
    # otherwise replace only the typed prefix and leave the rest of the
    # identifier dangling after the inserted snippet. Extend the replacement to
    # the end of the name token too.
    var nameEnd = caret
    while nameEnd < t.len:
      let c = t.charAt(nameEnd)
      if c == chDot:
        # Mirrors the parser: a `.` only continues the name when an
        # identifier-start character follows it, so `@gl.` at the end of a
        # sentence stops before the period instead of swallowing it.
        if nameEnd + 1 >= t.len or not isIdentStartChar(t.charAt(nameEnd + 1)): break
      elif not isNameChar(c):
        break
      inc nameEnd

    # An exact, finished match — the typed name matches a directive that needs
    # nothing more (no required parameters) — is a completed call, not
    # something still being typed. Keeping the context open here captures
    # Enter as "confirm" instead of a newline for `@pagebreak`.
    if nameEnd == caret and table.hasKey(name):
      let entry = table[name]
      for d in directives:
        if d.id != entry.id: continue
        if d.syntax.form == dfContainer: break
        var anyRequired = false
        for p in d.syntax.parameters:
          if p.isRequired:
            anyRequired = true
            break
        if not anyRequired: return (DirectiveCompletionContext(), false)
        break

    # A call already follows the name (`@fo|nt(size: 18){x}`): the full snippet
    # brings its own argument list and body, which would duplicate the existing
    # ones. Insert just the marker and name, caret landing right before what's
    # already there.
    let hasExistingCall = nameEnd < t.len and
      (t.charAt(nameEnd) == chLParen or t.charAt(nameEnd) == chLBrace)
    let candidates = nameCandidates(name, table, directives, marker, hasExistingCall)
    if candidates.len == 0: return (DirectiveCompletionContext(), false)
    return (DirectiveCompletionContext(
      kind: nameKind(), marker: marker, prefix: name,
      replacementRange: rng(markerIndex, nameEnd - markerIndex),
      directiveID: "", candidates: candidates), true)

  # Past the name — the only other completable position is inside the argument
  # list of a REGISTERED directive.
  if t.charAt(cursor) != chLParen or not table.hasKey(name):
    return (DirectiveCompletionContext(), false)
  let entry = table[name]
  for d in directives:
    if d.id == entry.id:
      return argumentContext(t, caret, cursor, marker, d)
  (DirectiveCompletionContext(), false)
