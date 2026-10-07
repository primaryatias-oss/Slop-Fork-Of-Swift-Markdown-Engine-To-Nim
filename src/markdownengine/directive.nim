## directive.nim
## MarkdownEngine (Nim port)
##
## The directive seam: a NAMED, ARGUMENT-CARRYING inline command —
## `@pagebreak`, `@font(size: 18){styled text}` — contributed by the embedder
## instead of hard-coded into the parser. Sibling of `MarkdownExtension`, which
## covers delimiter-shaped constructs (`==x==`, `::: … :::`) and cannot express
## a name plus a typed argument list.
##
## Two forms, both TREE-SHAPED — a directive's effect never escapes its own
## node:
##
## * self-contained — `@pagebreak`, `@date(format: iso)`. A leaf, drawn as a
##   glyph in place of its own source.
## * container — `@font(size: 18){text}`. The body is re-parsed as markdown and
##   styled with the directive's font transform COMPOSED over the inherited
##   font, so `@font(size: 18){**bold**}` is bold AND 18pt.
##
## There is deliberately no "applies to everything after me" form. That would
## make styling depend on document position rather than tree position, which
## breaks both the styler's compose-on-descent model and the block-scoped
## incremental restyle.
##
## Isolation contract, inherited verbatim from `MarkdownExtension`: a directive
## supplies SYNTAX (name + parameter schema) and PRESENTATION (font transform,
## attributes, glyph). It never emits ranges — the parser derives all geometry.
##
## Where Swift used a protocol with defaulted requirements, this port uses a
## ref object carrying proc fields. Embedders construct a value and override
## only what they need, and `newDirective` supplies the same defaults the
## Swift protocol extension did.

import std/[strutils, tables]
import ./ranges, ./utf16text, ./color, ./font, ./attributes, ./theme

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

type
  DirectiveUnit* = enum
    ## Unit suffix on a numeric argument: `18`, `18pt`, `1.5em`, `50%`.
    duNone = ""
    duPoint = "pt"
    duEm = "em"
    duPercent = "%"

  DirectiveValueKind* = enum
    dvString
    dvNumber
    dvLength
    dvBoolean
    dvKeyword

  DirectiveValue* = object
    ## One parsed argument value. Deliberately small and closed — directives
    ## get typed accessors rather than raw text, so an embedder never
    ## re-parses.
    case kind*: DirectiveValueKind
    of dvString: stringValue*: string
    of dvNumber: numberValue*: float
    of dvLength:
      lengthValue*: float
      unit*: DirectiveUnit
    of dvBoolean: boolValue*: bool
    of dvKeyword: keywordValue*: string

func dvStr*(s: string): DirectiveValue {.inline.} =
  DirectiveValue(kind: dvString, stringValue: s)
func dvNum*(n: float): DirectiveValue {.inline.} =
  DirectiveValue(kind: dvNumber, numberValue: n)
func dvLen*(n: float, u: DirectiveUnit = duNone): DirectiveValue {.inline.} =
  DirectiveValue(kind: dvLength, lengthValue: n, unit: u)
func dvBool*(b: bool): DirectiveValue {.inline.} =
  DirectiveValue(kind: dvBoolean, boolValue: b)
func dvKeyword*(s: string): DirectiveValue {.inline.} =
  DirectiveValue(kind: dvKeyword, keywordValue: s)

func `==`*(a, b: DirectiveValue): bool =
  if a.kind != b.kind: return false
  case a.kind
  of dvString: a.stringValue == b.stringValue
  of dvNumber: a.numberValue == b.numberValue
  of dvLength: a.lengthValue == b.lengthValue and a.unit == b.unit
  of dvBoolean: a.boolValue == b.boolValue
  of dvKeyword: a.keywordValue == b.keywordValue

func asString*(v: DirectiveValue): (string, bool) =
  case v.kind
  of dvString: (v.stringValue, true)
  of dvKeyword: (v.keywordValue, true)
  else: ("", false)

func asDouble*(v: DirectiveValue): (float, bool) =
  case v.kind
  of dvNumber: (v.numberValue, true)
  of dvLength: (v.lengthValue, true)
  else: (0.0, false)

func asBool*(v: DirectiveValue): (bool, bool) =
  if v.kind == dvBoolean: (v.boolValue, true) else: (false, false)

func resolvedLength*(v: DirectiveValue, base: float): (float, bool) =
  ## `pt` and unitless are absolute, `em` and `%` are relative to the
  ## inherited size.
  if v.kind != dvLength:
    return asDouble(v)
  case v.unit
  of duNone, duPoint: (v.lengthValue, true)
  of duEm: (base * v.lengthValue, true)
  of duPercent: (base * v.lengthValue / 100.0, true)

# ---------------------------------------------------------------------------
# Parameter schema
# ---------------------------------------------------------------------------

type
  DirectiveParameterKind* = enum
    dpString
    dpNumber
    dpLength
    dpBoolean
    dpKeyword   ## closed set in `allowed`; an EMPTY set accepts any bareword

  DirectiveParameter* = object
    ## One declared parameter. The schema drives three things at once:
    ## argument coercion, diagnostics for a malformed call, and argument-level
    ## autocomplete inside the parens.
    label*: string          ## empty == positional (`@color(red)`)
    hasLabel*: bool
    kind*: DirectiveParameterKind
    allowed*: seq[string]   ## only for `dpKeyword`
    isRequired*: bool
    defaultValue*: DirectiveValue
    hasDefault*: bool
    documentation*: string

func labeledParam*(label: string, kind: DirectiveParameterKind,
                   allowed: seq[string] = @[], isRequired = false,
                   defaultValue: DirectiveValue = dvStr(""),
                   hasDefault = false,
                   documentation = ""): DirectiveParameter =
  DirectiveParameter(label: label, hasLabel: true, kind: kind, allowed: allowed,
                     isRequired: isRequired, defaultValue: defaultValue,
                     hasDefault: hasDefault, documentation: documentation)

func positionalParam*(kind: DirectiveParameterKind, allowed: seq[string] = @[],
                      isRequired = false,
                      defaultValue: DirectiveValue = dvStr(""),
                      hasDefault = false,
                      documentation = ""): DirectiveParameter =
  DirectiveParameter(label: "", hasLabel: false, kind: kind, allowed: allowed,
                     isRequired: isRequired, defaultValue: defaultValue,
                     hasDefault: hasDefault, documentation: documentation)

func describeKind*(p: DirectiveParameter): string =
  case p.kind
  of dpString: "string"
  of dpNumber: "number"
  of dpLength: "length"
  of dpBoolean: "boolean"
  of dpKeyword:
    if p.allowed.len == 0: "keyword" else: p.allowed.join("|")

# ---------------------------------------------------------------------------
# Syntax rule
# ---------------------------------------------------------------------------

type
  DirectiveForm* = enum
    ## `@pagebreak` — no body. A body makes the candidate literal.
    dfSelfContained = "selfContained"
    ## `@font(size: 18){…}` — body required. No body makes it literal.
    dfContainer = "container"
    ## Body optional.
    dfEither = "either"

  DirectiveSyntax* = object
    name*: string
      ## `[A-Za-z_][A-Za-z0-9_-]*`, dot-separated segments allowed
      ## (`layout.columns`). Matched EXACTLY — an unregistered name stays
      ## literal text, exactly like unregistered extension syntax.
    form*: DirectiveForm
    marker*: uint16
      ## Override the registry's default marker for this one directive; 0 uses
      ## `DirectiveRegistrySettings.defaultMarker` (`@`).
    parameters*: seq[DirectiveParameter]
    parsesBody*: bool
      ## Whether the body is re-parsed as markdown (container, like a link's
      ## text) or kept opaque (leaf, like a code span).

func initDirectiveSyntax*(name: string, form: DirectiveForm, marker: uint16 = 0,
                          parameters: seq[DirectiveParameter] = @[],
                          parsesBody = true): DirectiveSyntax =
  DirectiveSyntax(name: name, form: form, marker: marker,
                  parameters: parameters, parsesBody: parsesBody)

# ---------------------------------------------------------------------------
# Styling result
# ---------------------------------------------------------------------------

type
  DirectiveSizeKind* = enum
    dsInherit
    dsAbsolute
    dsScale

  DirectiveFontTransform* = object
    ## How a directive changes the font of its body. DATA, not a closure, so
    ## the transform is inspectable, testable, and cheap in the per-keystroke
    ## styling path — with `custom` as the escape hatch for the rare case.
    sizeKind*: DirectiveSizeKind
    sizeValue*: float
    traits*: FontTraits
    hasTraits*: bool
    familyName*: string
    custom*: proc (f: FontDesc): FontDesc {.closure, gcsafe.}

  DirectiveStyle* = object
    ## What a container directive does to its body.
    font*: DirectiveFontTransform
    attributes*: Attrs
      ## Non-font attributes for the body range (background, colour, kern…).

const inheritFontTransform* = DirectiveFontTransform(sizeKind: dsInherit)

func inheritStyle*(): DirectiveStyle {.inline.} =
  DirectiveStyle(font: inheritFontTransform, attributes: @[])

proc apply*(t: DirectiveFontTransform, font: FontDesc): FontDesc =
  ## Compose over the INHERITED font — the whole point. `@font(size: 18)`
  ## inside a heading keeps the heading's bold; `**bold**` inside the body
  ## keeps 18pt.
  result = font
  if t.familyName.len > 0:
    result = result.withFamily(t.familyName)
  case t.sizeKind
  of dsAbsolute: result = result.withSize(t.sizeValue)
  of dsScale: result = result.withSize(result.size * t.sizeValue)
  of dsInherit: discard
  if t.hasTraits:
    result = result.adding(t.traits)
  if t.custom != nil:
    result = t.custom(result)

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

type
  DirectivePresentationKind* = enum
    dprLiteral   ## style the source text only — no glyph (the default)
    dprSymbol    ## a named symbol drawn at the directive's position
    dprText      ## replacement TEXT drawn in the inherited font
    dprImage     ## a pre-rendered image; `baselineOffset` as for LaTeX

  DirectivePresentation* = object
    ## What a self-contained directive draws in place of its collapsed source.
    ##
    ## The source text is never removed — it collapses to zero width via the
    ## engine's clear-colour + negative-kern mechanism (the one inline LaTeX
    ## uses), and the glyph is drawn by the layout fragment. "Markers shrink,
    ## they don't disappear" still holds.
    case kind*: DirectivePresentationKind
    of dprLiteral: discard
    of dprSymbol:
      symbolName*: string
      tint*: Color
      hasTint*: bool
    of dprText:
      text*: string
    of dprImage:
      image*: ImageHandle
      baselineOffset*: float

func literalPresentation*(): DirectivePresentation {.inline.} =
  DirectivePresentation(kind: dprLiteral)
func symbolPresentation*(name: string, tint: Color, hasTint = true): DirectivePresentation {.inline.} =
  DirectivePresentation(kind: dprSymbol, symbolName: name, tint: tint, hasTint: hasTint)
func textPresentation*(text: string): DirectivePresentation {.inline.} =
  DirectivePresentation(kind: dprText, text: text)
func imagePresentation*(image: ImageHandle, baselineOffset: float): DirectivePresentation {.inline.} =
  DirectivePresentation(kind: dprImage, image: image, baselineOffset: baselineOffset)

type
  DirectiveContext* = object
    ## Everything a directive may read while deciding how to present itself.
    ## Read-only by construction — a directive cannot reach the text storage.
    theme*: MarkdownEditorTheme
    inheritedFont*: FontDesc
      ## Font inherited at the directive's position (heading font inside a
      ## heading, body font in a paragraph).
    isActive*: bool
      ## True when the caret is inside the directive — source is revealed.
    marker*: uint16
    appearance*: Appearance

# ---------------------------------------------------------------------------
# Diagnostics and coerced arguments
# ---------------------------------------------------------------------------

type
  DirectiveDiagnosticKind* = enum
    ddUnknownLabel
    ddTypeMismatch
    ddMissingRequired
    ddTooManyPositional

  DirectiveDiagnostic* = object
    ## A problem found while coercing a call against its schema.
    kind*: DirectiveDiagnosticKind
    label*: string
    expected*: string
    range*: Range   ## absolute range of the offending argument

  DirectiveArguments* = object
    ## Arguments of one directive call, already coerced against the schema.
    labeled*: OrderedTable[string, DirectiveValue]
    positional*: seq[DirectiveValue]
    diagnostics*: seq[DirectiveDiagnostic]

proc emptyArguments*(): DirectiveArguments =
  DirectiveArguments(labeled: initOrderedTable[string, DirectiveValue](),
                     positional: @[], diagnostics: @[])

func isValid*(a: DirectiveArguments): bool {.inline.} =
  ## True when every argument coerced cleanly and every required parameter was
  ## supplied.
  a.diagnostics.len == 0

proc value*(a: DirectiveArguments, label: string): (DirectiveValue, bool) =
  if a.labeled.hasKey(label): (a.labeled[label], true)
  else: (dvStr(""), false)

proc stringArg*(a: DirectiveArguments, label: string): (string, bool) =
  let (v, ok) = a.value(label)
  if not ok: ("", false) else: asString(v)

proc numberArg*(a: DirectiveArguments, label: string): (float, bool) =
  let (v, ok) = a.value(label)
  if not ok: (0.0, false) else: asDouble(v)

proc boolArg*(a: DirectiveArguments, label: string): (bool, bool) =
  let (v, ok) = a.value(label)
  if not ok: (false, false) else: asBool(v)

proc lengthArg*(a: DirectiveArguments, label: string, base: float): (float, bool) =
  let (v, ok) = a.value(label)
  if not ok: (0.0, false) else: resolvedLength(v, base)

# ---------------------------------------------------------------------------
# Completion metadata
# ---------------------------------------------------------------------------

type
  DirectiveCompletionItem* = object
    ## One row the embedder's picker shows for an argument VALUE.
    title*: string
      ## Primary text, e.g. `font` or `JP`.
    subtitle*: string
      ## Secondary text, e.g. a description or a country name.
    detail*: string
      ## Optional preview of the RESULT — the flag for a country code, the
      ## glyph for a symbol. Shown by the picker; never inserted. Empty means
      ## none.
    insertion*: string
      ## Text that replaces the completion context's replacement range.
    caretOffset*: int
      ## Caret position within `insertion` after the pick.
    hasCaretOffset*: bool
      ## False lands the caret at the end of `insertion`.
    symbolName*: string
      ## Symbol for the row; empty means none.

  DirectiveCompletion* = object
    ## What the embedder's picker shows for a directive. Synthesised from the
    ## syntax by default, so a directive only overrides it to add prose.
    id*: string
    title*: string
    subtitle*: string
    keywords*: seq[string]
    snippet*: string
      ## Text inserted on pick, with `|` marking the caret landing spot —
      ## e.g. `@font(size: |){}`. Exactly one `|`; the engine strips it and
      ## reports the offset when it applies the replacement.
    symbolName*: string

func completionItem*(title: string, subtitle = "", insertion = "",
                     detail = "", symbolName = "",
                     caretOffset = 0,
                     hasCaretOffset = false): DirectiveCompletionItem =
  DirectiveCompletionItem(title: title, subtitle: subtitle, detail: detail,
                          insertion: if insertion.len > 0: insertion else: title,
                          caretOffset: caretOffset,
                          hasCaretOffset: hasCaretOffset,
                          symbolName: symbolName)

# ---------------------------------------------------------------------------
# Registry settings
# ---------------------------------------------------------------------------

type
  DirectiveRegistrySettings* = object
    ## `@` is the default: the modern convention for "invoke something inline"
    ## (Notion / Linear / Slack), and unlike `\` it collides neither with the
    ## LaTeX vocabulary this engine renders through `$…$` / `$$…$$` nor with
    ## CommonMark's `\`+punctuation escapes.
    ##
    ## A marker must be a single UTF-16 code unit, so marker dispatch stays one
    ## table probe per character on the parse hot path.
    defaultMarker*: uint16

const defaultDirectiveSettings* = DirectiveRegistrySettings(defaultMarker: chAt)

# ---------------------------------------------------------------------------
# The directive value type
# ---------------------------------------------------------------------------

type
  MarkdownDirective* = ref object of RootObj
    ## An embedder-contributed inline command. Register instances via
    ## `MarkdownEditorConfiguration.directives`; an unregistered name stays
    ## literal text.
    id*: string
      ## Stable identifier, unique per directive. Defaults to `syntax.name`.
      ## Used for dispatch and cache keying — never shown to users.
    syntax*: DirectiveSyntax
    completion*: DirectiveCompletion
    styleProc*: proc (args: DirectiveArguments, ctx: DirectiveContext): DirectiveStyle {.closure, gcsafe.}
      ## Container form: how the body is styled. Ignored for self-contained.
      ## Called during styling; must be cheap and synchronous.
    presentationProc*: proc (args: DirectiveArguments, ctx: DirectiveContext): DirectivePresentation {.closure, gcsafe.}
      ## Self-contained form: what to draw. Ignored for container.
    htmlProc*: proc (args: DirectiveArguments, bodyHTML: string): string {.closure, gcsafe.}
      ## Clean-copy path. `bodyHTML` is already escaped / recursively rendered
      ## (empty for self-contained).
    valueCompletionsProc*: proc (p: DirectiveParameter, prefix: string): seq[DirectiveCompletionItem] {.closure, gcsafe.}
      ## Candidate VALUES for one parameter, filtered by what the user typed.

proc defaultDirectiveSnippet*(syntax: DirectiveSyntax,
                              settings = defaultDirectiveSettings): string =
  ## `@font(size: |){}` — the first argument slot gets the caret; container
  ## forms get braces. Exactly one caret marker: keep the first, drop the rest.
  let markerUnit = if syntax.marker != 0: syntax.marker else: settings.defaultMarker
  var text = utf16ToString([markerUnit]) & syntax.name
  if syntax.parameters.len > 0:
    var slots: seq[string] = @[]
    for param in syntax.parameters:
      if param.isRequired or not param.hasDefault:
        slots.add(if param.hasLabel: param.label & ": |" else: "|")
    text.add "(" & (if slots.len == 0: "|" else: slots.join(", ")) & ")"
  case syntax.form
  of dfContainer, dfEither: text.add "{}"
  of dfSelfContained: discard
  let first = text.find('|')
  if first < 0: return text & "|"
  result = text[0 .. first]
  for i in first + 1 ..< text.len:
    if text[i] != '|': result.add text[i]

proc defaultValueCompletions*(p: DirectiveParameter, prefix: string): seq[DirectiveCompletionItem] =
  ## Whatever the declared schema can answer by itself: closed keyword sets and
  ## booleans. An open keyword set, a string, or a number has no enumerable
  ## domain, so the default offers nothing rather than guessing.
  var values: seq[string] = @[]
  case p.kind
  of dpKeyword:
    if p.allowed.len == 0: return @[]
    values = p.allowed
  of dpBoolean:
    values = @["true", "false"]
  else:
    return @[]
  let needle = prefix.toLowerAscii
  for v in values:
    if needle.len == 0 or v.toLowerAscii.startsWith(needle):
      result.add completionItem(v, p.documentation, v)

proc newDirective*(
    syntax: DirectiveSyntax,
    id = "",
    completion = DirectiveCompletion(),
    styleProc: proc (args: DirectiveArguments, ctx: DirectiveContext): DirectiveStyle {.closure, gcsafe.} = nil,
    presentationProc: proc (args: DirectiveArguments, ctx: DirectiveContext): DirectivePresentation {.closure, gcsafe.} = nil,
    htmlProc: proc (args: DirectiveArguments, bodyHTML: string): string {.closure, gcsafe.} = nil,
    valueCompletionsProc: proc (p: DirectiveParameter, prefix: string): seq[DirectiveCompletionItem] {.closure, gcsafe.} = nil
  ): MarkdownDirective =
  ## Constructor supplying the same defaults the Swift protocol extension did.
  let resolvedID = if id.len > 0: id else: syntax.name
  var resolvedCompletion = completion
  if resolvedCompletion.snippet.len == 0:
    resolvedCompletion = DirectiveCompletion(
      id: resolvedID, title: syntax.name,
      subtitle: resolvedCompletion.subtitle,
      keywords: resolvedCompletion.keywords,
      snippet: defaultDirectiveSnippet(syntax),
      symbolName: resolvedCompletion.symbolName)
  if resolvedCompletion.id.len == 0: resolvedCompletion.id = resolvedID
  if resolvedCompletion.title.len == 0: resolvedCompletion.title = syntax.name

  result = MarkdownDirective(
    id: resolvedID, syntax: syntax, completion: resolvedCompletion,
    styleProc: styleProc, presentationProc: presentationProc,
    htmlProc: htmlProc, valueCompletionsProc: valueCompletionsProc)

proc style*(d: MarkdownDirective, args: DirectiveArguments,
            ctx: DirectiveContext): DirectiveStyle =
  if d.styleProc != nil: d.styleProc(args, ctx) else: inheritStyle()

proc presentation*(d: MarkdownDirective, args: DirectiveArguments,
                   ctx: DirectiveContext): DirectivePresentation =
  if d.presentationProc != nil: d.presentationProc(args, ctx)
  else: literalPresentation()

proc html*(d: MarkdownDirective, args: DirectiveArguments, bodyHTML: string): string =
  if d.htmlProc != nil: return d.htmlProc(args, bodyHTML)
  if bodyHTML.len == 0: "<span data-directive=\"" & d.id & "\"></span>"
  else: "<span data-directive=\"" & d.id & "\">" & bodyHTML & "</span>"

proc valueCompletions*(d: MarkdownDirective, p: DirectiveParameter,
                       prefix: string): seq[DirectiveCompletionItem] =
  if d.valueCompletionsProc != nil: d.valueCompletionsProc(p, prefix)
  else: defaultValueCompletions(p, prefix)
