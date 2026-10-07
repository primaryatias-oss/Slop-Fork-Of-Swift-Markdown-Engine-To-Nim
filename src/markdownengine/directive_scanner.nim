## directive_scanner.nim
## MarkdownEngine (Nim port)
##
## The parser side of the directive seam. Called from
## `InlineParser.matchClaimedSpan` AFTER every built-in, so a directive can
## never take text away from core markdown — the same precedence rule extension
## spans follow.
##
## Self-contained by design: the scanner re-implements the two helpers it needs
## (`isEscaped`, balanced-delimiter scanning) rather than reaching into the
## inline parser's, so the whole seam is one module plus a four-line hook.
##
## Rejection is always silent and always means "stays literal text": an
## unregistered name, a malformed call, a wrong-form call, a run crossing a
## line break. Nothing here can produce a partial construct.
##
## Because the scanner runs inside `scanLinkFamily` (pass 3), a directive
## inside a code span is already claimed and never fires.
##
## KNOWN LIMITATION — a directive whose BODY holds a pre-claimed span is
## rejected whole, so ``@font(size: 18){a `b` c}`` produces no directive node
## at all rather than a directive containing a code span. The same applies to a
## backslash escape (`{a \* c}`), since escapes are claimed in pass 2. It is
## exactly the pre-claimed passes that bite; constructs claimed in this pass or
## later (`$…$`, links, emphasis, nesting) all work inside a body.
##
## Also holds the schema-driven argument coercion, which runs at STYLING time,
## not parse time: the parser stays geometry-only, and a document with no
## directives pays nothing.

import std/[strutils, tables]
import ./ranges, ./utf16text, ./directive, ./extension

type
  DirectiveMatch* = object
    ## A matched directive, in absolute UTF-16 coordinates. Neutral value type:
    ## the inline parser converts it into its own `Span` at the call site.
    nodeID*: string
      ## AST node id — already namespaced via `directiveNodeID`.
    range*: Range
    nameRange*: Range
      ## The name run, without the marker (`font` in `@font(…)`).
    argumentsRange*: Range
      ## Inside the parens; `NotFound` location when the call has no list.
    hasArguments*: bool
    bodyRange*: Range
      ## Inside the braces; absent for a self-contained call.
    hasBody*: bool
    markers*: seq[Range]
      ## Ranges that shrink when the caret leaves: `[prefix, closingBrace]` for
      ## a container, EMPTY for a self-contained call — there the whole call is
      ## the content, and the glyph pass collapses it at styling time.
    contentRange*: Range
      ## The body for a container, the whole call for a self-contained one.
    parsesContent*: bool

# ---------------------------------------------------------------------------
# Character classes
# ---------------------------------------------------------------------------

func isIdentStart(c: uint16): bool {.inline.} =
  ## `[A-Za-z_]`
  (c >= 0x41u16 and c <= 0x5Au16) or (c >= 0x61u16 and c <= 0x7Au16) or c == chUnderscore

func isIdentChar(c: uint16): bool {.inline.} =
  ## `[A-Za-z0-9_-]`
  isIdentStart(c) or isAsciiDigit(c) or c == chDash

func isBoundary(c: uint16): bool {.inline.} =
  ## Whether a directive may open after `c`.
  ##
  ## Stated as a DENY list — only letters and digits reject — rather than an
  ## allow list of punctuation. An allow list looks safer and is wrong: it
  ## silently breaks every markup context that abuts a directive
  ## (`*@font(size: 18){x}*`, `**…**`, `~~…~~`, `- @pagebreak`), because the
  ## preceding character is a markup delimiter nobody remembered to list.
  ##
  ## Rejecting word characters is all the email rule needs:
  ## `name@example.com` is preceded by `e`. Underscore is deliberately a
  ## boundary so `_@font(size: 18){x}_` works.
  not isAlphanumericUnit(c)

func isEscaped(t: Utf16Text, index: int): bool =
  ## Whether the character at `index` is preceded by an odd number of
  ## backslashes.
  var count = 0
  var k = index - 1
  while k >= 0 and t.charAt(k) == chBackslash:
    inc count
    dec k
  (count mod 2) == 1

func balanced(t: Utf16Text, length: int, start: int, open, close: uint16): int =
  ## Index of the delimiter balancing the run starting at `start`, or -1 when
  ## the run is unbalanced or crosses a line break. Escaped delimiters and
  ## delimiters inside a quoted string don't count.
  var depth = 1
  var inQuote = false
  var k = start
  while k < length:
    let c = t.charAt(k)
    if c == chLF or c == chCR: return -1
    if not isEscaped(t, k):
      if c == chQuote:
        inQuote = not inQuote
      elif not inQuote:
        if c == open: inc depth
        if c == close:
          dec depth
          if depth == 0: return k
    inc k
  -1

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

proc matchDirective*(t: Utf16Text, length: int, i: int,
                     registry: DirectiveRegistry): (DirectiveMatch, bool) =
  ## Try to match a directive starting at `i`. Returns `false` for every
  ## rejection — the candidate then stays literal text.
  if registry.isEmpty or i < 0 or i >= length:
    return (DirectiveMatch(), false)
  let marker = t.charAt(i)
  if not registry.byMarker.hasKey(marker):
    return (DirectiveMatch(), false)
  let table = registry.byMarker[marker]
  if table.len == 0:
    return (DirectiveMatch(), false)

  # Left boundary: anything that isn't a word character. Markup delimiters
  # therefore open directives, while `name@example.com` never does, and a `@@`
  # run stays literal (mirrors `InlineSyntax.rejectsOpenerRun`).
  if i > 0:
    let previous = t.charAt(i - 1)
    if previous == marker or not isBoundary(previous):
      return (DirectiveMatch(), false)
  if isEscaped(t, i):
    return (DirectiveMatch(), false)

  # Name: ident ('.' ident)*
  var cursor = i + 1
  let nameStart = cursor
  if cursor >= length or not isIdentStart(t.charAt(cursor)):
    return (DirectiveMatch(), false)
  while cursor < length:
    let c = t.charAt(cursor)
    if isIdentChar(c):
      inc cursor
    elif c == chDot and cursor + 1 < length and isIdentStart(t.charAt(cursor + 1)):
      inc cursor
    else:
      break
  let nameRange = rng(nameStart, cursor - nameStart)

  # REGISTERED NAMES ONLY — the property that makes this safe to enable over an
  # existing document corpus.
  let name = t.substring(nameRange)
  if not table.hasKey(name):
    return (DirectiveMatch(), false)
  let entry = table[name]

  # Optional argument list `( … )`: balanced, single line.
  var argumentsRange = notFoundRange()
  var hasArguments = false
  if cursor < length and t.charAt(cursor) == chLParen:
    let close = balanced(t, length, cursor + 1, chLParen, chRParen)
    if close < 0: return (DirectiveMatch(), false)
    argumentsRange = rng(cursor + 1, close - (cursor + 1))
    hasArguments = true
    cursor = close + 1

  # Optional body `{ … }`: balanced, single line, escape-aware.
  var bodyRange = notFoundRange()
  var hasBody = false
  if cursor < length and t.charAt(cursor) == chLBrace:
    let close = balanced(t, length, cursor + 1, chLBrace, chRBrace)
    if close < 0: return (DirectiveMatch(), false)
    bodyRange = rng(cursor + 1, close - (cursor + 1))
    hasBody = true
    cursor = close + 1

  # Form check — a mismatched call stays literal rather than rendering
  # half-configured.
  case entry.form
  of dfSelfContained:
    if hasBody: return (DirectiveMatch(), false)
  of dfContainer:
    if not hasBody: return (DirectiveMatch(), false)
  of dfEither: discard

  let fullRange = rng(i, cursor - i)

  if hasBody:
    # Markers are what shrinks when the caret leaves: the whole
    # `@font(size: 18){` prefix and the closing `}`, leaving only the styled
    # body visible.
    let prefix = rng(i, bodyRange.location - i)
    let closingBrace = rng(maxRange(bodyRange), 1)
    return (DirectiveMatch(
      nodeID: directiveNodeID(entry.id), range: fullRange, nameRange: nameRange,
      argumentsRange: argumentsRange, hasArguments: hasArguments,
      bodyRange: bodyRange, hasBody: true,
      markers: @[prefix, closingBrace], contentRange: bodyRange,
      parsesContent: entry.parsesBody), true)

  # Self-contained: no markers, so the whole call is the content. It is
  # CLAIMED, so emphasis and autolinking can't fire inside it, and it projects
  # a token like any other node — the glyph pass at styling time only has to
  # add presentation.
  (DirectiveMatch(
    nodeID: directiveNodeID(entry.id), range: fullRange, nameRange: nameRange,
    argumentsRange: argumentsRange, hasArguments: hasArguments,
    bodyRange: notFoundRange(), hasBody: false,
    markers: @[], contentRange: fullRange, parsesContent: false), true)

proc argumentsRangeInPrefix*(t: Utf16Text, prefix: Range): (Range, bool) =
  ## Recover the argument range from a directive node's PREFIX marker
  ## (`@font(size: 18){`, or the whole call when self-contained).
  ##
  ## The AST carries directives as extension-shaped nodes, which have no slot
  ## for an argument range, so styling recovers it from the geometry the parser
  ## already emitted. The prefix is well-formed by construction — this scanner
  ## produced it — so the walk is a short, total re-derivation rather than a
  ## second parse of the document.
  let stop = min(maxRange(prefix), t.len)
  var k = prefix.location + 1                      # past the marker
  while k < stop and (isIdentChar(t.charAt(k)) or t.charAt(k) == chDot): inc k
  if k >= stop or t.charAt(k) != chLParen: return (notFoundRange(), false)
  let close = balanced(t, stop, k + 1, chLParen, chRParen)
  if close < 0: return (notFoundRange(), false)
  (rng(k + 1, close - (k + 1)), true)

# ---------------------------------------------------------------------------
# Argument coercion
# ---------------------------------------------------------------------------

func splitArguments(t: Utf16Text, r: Range): seq[Range] =
  ## Split on commas at depth 0, respecting quotes and nested brackets, so
  ## `@x(a: "one, two", b: f(1, 2))` is two arguments.
  var depth = 0
  var inQuote = false
  var start = r.location
  for k in r.location ..< maxRange(r):
    let c = t.charAt(k)
    if c == chQuote:
      inQuote = not inQuote
      continue
    if inQuote: continue
    case c
    of chLParen, chLBracket, chLBrace: inc depth
    of chRParen, chRBracket, chRBrace: dec depth
    of chComma:
      if depth == 0:
        result.add rng(start, k - start)
        start = k + 1
    else: discard
  if start < maxRange(r):
    result.add rng(start, maxRange(r) - start)

func splitLabel(t: Utf16Text, r: Range): (Range, bool, Range) =
  ## Split `label: value` at the first depth-0, unquoted colon. A value
  ## containing a colon (`"12:30"`) is safe because quotes suppress the split.
  var inQuote = false
  for k in r.location ..< maxRange(r):
    let c = t.charAt(k)
    if c == chQuote:
      inQuote = not inQuote
      continue
    if c == chColon and not inQuote:
      let label = rng(r.location, k - r.location)
      let value = rng(k + 1, maxRange(r) - (k + 1))
      # A leading colon (`:value`) is not a label.
      if label.length > 0: return (label, true, value)
      return (notFoundRange(), false, r)
  (notFoundRange(), false, r)

func parseLength(raw: string): (DirectiveValue, bool) =
  ## `18`, `18pt`, `1.5em`, `50%`
  for unit in [duPercent, duEm, duPoint]:
    let suffix = $unit
    if suffix.len > 0 and raw.endsWith(suffix):
      let head = raw[0 ..< raw.len - suffix.len]
      try:
        return (dvLen(parseFloat(head), unit), true)
      except ValueError:
        return (dvStr(""), false)
  try:
    (dvLen(parseFloat(raw), duNone), true)
  except ValueError:
    (dvStr(""), false)

func coerce(raw: string, p: DirectiveParameter): (DirectiveValue, bool) =
  if raw.len >= 2 and raw.startsWith("\"") and raw.endsWith("\""):
    let inner = raw[1 ..< raw.len - 1]
    # A quoted literal is a string; it satisfies `string` and `keyword`, and
    # nothing else.
    case p.kind
    of dpString: return (dvStr(inner), true)
    of dpKeyword:
      if p.allowed.len == 0 or inner in p.allowed: return (dvKeyword(inner), true)
      return (dvStr(""), false)
    else: return (dvStr(""), false)
  case p.kind
  of dpString:
    (dvStr(raw), true)
  of dpBoolean:
    if raw == "true": (dvBool(true), true)
    elif raw == "false": (dvBool(false), true)
    else: (dvStr(""), false)
  of dpNumber:
    try: (dvNum(parseFloat(raw)), true)
    except ValueError: (dvStr(""), false)
  of dpLength:
    parseLength(raw)
  of dpKeyword:
    if p.allowed.len == 0 or raw in p.allowed: (dvKeyword(raw), true)
    else: (dvStr(""), false)

proc applyingDefaults(labeled: var OrderedTable[string, DirectiveValue],
                      positional: var seq[DirectiveValue],
                      diagnostics: var seq[DirectiveDiagnostic],
                      schema: seq[DirectiveParameter], anchor: Range) =
  ## Fill unsupplied parameters — labelled and positional alike — from their
  ## defaults, then report whatever required parameter is still missing.
  ##
  ## Positional defaults fill by POSITION, so they only apply to a tail the
  ## call didn't reach: given `(a, b = 2, c)`, `@x(1)` yields `1, 2` and still
  ## reports `#2` missing. A default can't be skipped over, because there is no
  ## syntax for "use the default here but supply the next one" — so the first
  ## positional without a default ends the filling.
  for p in schema:
    if not p.hasLabel: continue
    if labeled.hasKey(p.label): continue
    if p.hasDefault:
      labeled[p.label] = p.defaultValue
    elif p.isRequired:
      diagnostics.add DirectiveDiagnostic(kind: ddMissingRequired, label: p.label,
                                          range: anchor)

  var positionalSchema: seq[DirectiveParameter] = @[]
  for p in schema:
    if not p.hasLabel: positionalSchema.add p

  var index = positional.len
  while index < positionalSchema.len:
    if not positionalSchema[index].hasDefault: break
    positional.add positionalSchema[index].defaultValue
    inc index
  for k in positional.len ..< positionalSchema.len:
    if positionalSchema[k].isRequired:
      diagnostics.add DirectiveDiagnostic(kind: ddMissingRequired,
                                          label: "#" & $k, range: anchor)

proc parseArguments*(t: Utf16Text, r: Range, hasRange: bool,
                     schema: seq[DirectiveParameter]): DirectiveArguments =
  ## Parse and coerce the argument list at `r` against `schema`. An absent or
  ## empty range still applies defaults and reports missing required
  ## parameters, so `@font` and `@font()` behave identically.
  ##
  ## Coercion never throws and never partially applies: an argument that fails
  ## its schema is dropped and recorded as a diagnostic, so a directive always
  ## receives a well-formed `DirectiveArguments` and can decide for itself
  ## whether to render as invalid.
  var labeled = initOrderedTable[string, DirectiveValue]()
  var positional: seq[DirectiveValue] = @[]
  var diagnostics: seq[DirectiveDiagnostic] = @[]
  let anchor = if hasRange: r else: rng(0, 0)

  if not hasRange or r.length <= 0:
    applyingDefaults(labeled, positional, diagnostics, schema, anchor)
    return DirectiveArguments(labeled: labeled, positional: positional,
                              diagnostics: diagnostics)

  var positionalSchema: seq[DirectiveParameter] = @[]
  for p in schema:
    if not p.hasLabel: positionalSchema.add p

  for argument in splitArguments(t, r):
    let (labelRange, hasLabel, valueRange) = splitLabel(t, argument)
    let raw = trimWhitespace(t.substring(valueRange))
    if raw.len == 0: continue

    if not hasLabel:
      let index = positional.len
      if index >= positionalSchema.len:
        diagnostics.add DirectiveDiagnostic(kind: ddTooManyPositional, range: argument)
        continue
      let p = positionalSchema[index]
      let (value, ok) = coerce(raw, p)
      if not ok:
        diagnostics.add DirectiveDiagnostic(kind: ddTypeMismatch,
                                            label: "#" & $index,
                                            expected: describeKind(p),
                                            range: valueRange)
        continue
      positional.add value
      continue

    let label = trimWhitespace(t.substring(labelRange))
    var found = false
    var p: DirectiveParameter
    for candidate in schema:
      if candidate.hasLabel and candidate.label == label:
        p = candidate
        found = true
        break
    if not found:
      diagnostics.add DirectiveDiagnostic(kind: ddUnknownLabel, label: label,
                                          range: argument)
      continue
    let (value, ok) = coerce(raw, p)
    if not ok:
      diagnostics.add DirectiveDiagnostic(kind: ddTypeMismatch, label: label,
                                          expected: describeKind(p),
                                          range: valueRange)
      continue
    labeled[label] = value

  applyingDefaults(labeled, positional, diagnostics, schema, anchor)
  DirectiveArguments(labeled: labeled, positional: positional,
                     diagnostics: diagnostics)
