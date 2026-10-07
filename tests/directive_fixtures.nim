## directive_fixtures.nim
## Directives used across the directive suites.
##
## Ported from `DirectiveTestFixtures.swift`, and deliberately test-local for
## the same reason: the engine ships only `font` and `color` as reference
## implementations. Anything carrying curated data or app policy (icons,
## flags, print semantics) belongs to the embedder, so the shapes those would
## have exercised are declared here instead. That also keeps the suites
## hermetic — they test the SEAM, not the bundled directives. A schema is a
## schema whether it came from the engine or from an embedder.

import std/strutils
import markdownengine

# ---------------------------------------------------------------------------
# Parsing and argument shapes
# ---------------------------------------------------------------------------

proc sizedDirective*(): MarkdownDirective =
  ## Container form with a mixed labelled schema — the shape the parser has to
  ## carry through argument coercion.
  newDirective(initDirectiveSyntax("font", dfContainer, parameters = @[
    labeledParam("size", dpLength,
                 documentation = "Point size, or 1.5em / 120% relative to the " &
                                 "surrounding text."),
    labeledParam("family", dpString, documentation = "Font family name."),
    labeledParam("weight", dpKeyword, allowed = @["regular", "bold"],
                 defaultValue = dvKeyword("regular"), hasDefault = true,
                 documentation = "Font weight."),
  ]))

proc tintDirective*(): MarkdownDirective =
  ## Container form with a required POSITIONAL argument.
  newDirective(initDirectiveSyntax("color", dfContainer, parameters = @[
    positionalParam(dpKeyword, isRequired = true, documentation = "Colour name."),
  ]))

proc selfContainedPair*(): MarkdownDirective =
  ## Self-contained with two POSITIONAL parameters — the shape that exercises
  ## defaults on positionals, which labelled-only filling used to skip.
  newDirective(initDirectiveSyntax("pair", dfSelfContained, parameters = @[
    positionalParam(dpString, defaultValue = dvStr("a"), hasDefault = true),
    positionalParam(dpString, defaultValue = dvStr("b"), hasDefault = true),
  ]))

# ---------------------------------------------------------------------------
# Presentation and completion shapes
# ---------------------------------------------------------------------------

proc markerPresentation(args: DirectiveArguments,
                        ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  if ctx.isActive: literalPresentation()
  else: symbolPresentation("arrow.down.to.line", ctx.theme.mutedText)

proc markerHtml(args: DirectiveArguments, bodyHTML: string): string {.gcsafe.} =
  "<hr class=\"marker\" />"

proc markerDirective*(): MarkdownDirective =
  ## Self-contained, no arguments, draws a fixed symbol. The minimal glyph case.
  newDirective(initDirectiveSyntax("marker", dfSelfContained),
    completion = DirectiveCompletion(
      id: "marker", title: "marker", subtitle: "A fixed glyph",
      keywords: @["rule", "divider"], snippet: "@marker",
      symbolName: "arrow.down.to.line"),
    presentationProc = markerPresentation,
    htmlProc = markerHtml)

const glyphSymbols* = ["star.fill", "star", "bolt.fill",
                       "checkmark.circle.fill", "flame.fill"]

proc glyphPresentation(args: DirectiveArguments,
                       ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  if ctx.isActive or args.positional.len == 0: return literalPresentation()
  let (name, ok) = args.positional[0].asString
  if not ok: return literalPresentation()
  let (colour, hasColour) = args.stringArg("color")
  if not hasColour: return symbolPresentation(name, Color(), hasTint = false)
  case colour
  of "red": symbolPresentation(name, systemRed)
  of "green": symbolPresentation(name, systemGreen)
  of "blue": symbolPresentation(name, systemBlue)
  else: symbolPresentation(name, Color(), hasTint = false)

proc glyphValueCompletions(p: DirectiveParameter,
                           prefix: string): seq[DirectiveCompletionItem] {.gcsafe.} =
  # Only the positional slot is dynamic; `color:` falls through to the
  # schema-derived default.
  if p.hasLabel: return defaultValueCompletions(p, prefix)
  let needle = prefix.toLowerAscii
  for symbol in glyphSymbols:
    if needle.len == 0 or symbol.startsWith(needle):
      result.add DirectiveCompletionItem(title: symbol, subtitle: "Symbol",
                                         insertion: symbol, symbolName: symbol)

proc glyphDirective*(): MarkdownDirective =
  ## Self-contained, symbol chosen by a positional argument, with a static
  ## value-completion list. Stands in for an icon-style directive.
  newDirective(initDirectiveSyntax("glyph", dfSelfContained, parameters = @[
      positionalParam(dpKeyword, isRequired = true,
                      documentation = "Symbol name."),
      labeledParam("color", dpKeyword, allowed = @["red", "green", "blue"],
                   documentation = "Tint."),
    ]),
    completion = DirectiveCompletion(
      id: "glyph", title: "glyph", subtitle: "Draw a symbol",
      keywords: @["symbol", "icon"], snippet: "@glyph(|)", symbolName: "star"),
    presentationProc = glyphPresentation,
    valueCompletionsProc = glyphValueCompletions)

const regionTable* = [
  ("JP", "Japan", "\u{1F1EF}\u{1F1F5}"),
  ("US", "United States", "\u{1F1FA}\u{1F1F8}"),
  ("DE", "Germany", "\u{1F1E9}\u{1F1EA}"),
  ("BR", "Brazil", "\u{1F1E7}\u{1F1F7}"),
]

proc regionPresentation(args: DirectiveArguments,
                        ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  if ctx.isActive or args.positional.len == 0: return literalPresentation()
  let (code, ok) = args.positional[0].asString
  if not ok: return literalPresentation()
  for (entryCode, _, glyph) in regionTable:
    if entryCode.toLowerAscii == code.toLowerAscii:
      return textPresentation(glyph)
  literalPresentation()

proc regionValueCompletions(p: DirectiveParameter,
                            prefix: string): seq[DirectiveCompletionItem] {.gcsafe.} =
  let needle = prefix.toLowerAscii
  for (code, name, glyph) in regionTable:
    if needle.len == 0 or code.toLowerAscii.startsWith(needle) or
       name.toLowerAscii.startsWith(needle):
      result.add DirectiveCompletionItem(title: code, subtitle: name,
                                         detail: glyph, insertion: code)

proc regionDirective*(): MarkdownDirective =
  ## Self-contained, renders replacement TEXT chosen by argument, with dynamic
  ## value completions that match on two fields. Stands in for a flag/emoji
  ## style directive — the case whose domain is too large to declare.
  newDirective(initDirectiveSyntax("region", dfSelfContained, parameters = @[
      positionalParam(dpKeyword, isRequired = true,
                      documentation = "Region code."),
    ]),
    completion = DirectiveCompletion(
      id: "region", title: "region", subtitle: "Region flag",
      keywords: @["country", "flag"], snippet: "@region(|)", symbolName: "flag"),
    presentationProc = regionPresentation,
    valueCompletionsProc = regionValueCompletions)

# ---------------------------------------------------------------------------
# Shapes used by the parser suite
# ---------------------------------------------------------------------------

proc wildthinkDirective*(): MarkdownDirective =
  ## Named after a domain label, so the email-boundary test runs against a
  ## name that WOULD otherwise match.
  newDirective(initDirectiveSyntax("wildthink", dfSelfContained))

proc opaqueDirective*(): MarkdownDirective =
  newDirective(initDirectiveSyntax("raw", dfContainer, parsesBody = false))

proc eitherDirective*(): MarkdownDirective =
  newDirective(initDirectiveSyntax("note", dfEither))

proc backslashDirective*(): MarkdownDirective =
  newDirective(initDirectiveSyntax("bigger", dfContainer,
                                   marker = uint16(ord('\\'))))
