## builtin_directives.nim
## MarkdownEngine (Nim port)
##
## The two reference directives, mirroring how the highlight / strikethrough
## extensions ship: not registered by default, opted into the same way, and
## present mainly as templates for writing your own.
##
## ```nim
## configuration.directives = @[newFontDirective(), newColorDirective()]
## ```
##
## Both are PURE PRESENTATION — a font transform and a colour. Both are
## containers, so neither draws a glyph; directives that carry curated data
## (icons, flags, emoji) or encode document policy (page breaks) are app
## concerns, not engine primitives, so they belong to the embedder. The demo
## app shows what those look like.

import std/strutils
import ./color, ./font, ./attributes, ./directive

const
  fontDirectiveID* = "font"
  colorDirectiveID* = "color"

proc newFontDirective*(): MarkdownDirective =
  ## `@font(size: 18){…}` — container, font composition. The motivating case.
  ##
  ## Note the FORM: a bare `@font(size: 18)` has no meaning under tree-shaped
  ## semantics — there is nothing for it to apply to — so the directive
  ## requires a body. That is the one place this seam departs from a
  ## LaTeX-style `\font(size: 18)` sketch, and it is what keeps per-keystroke
  ## restyling block-local.
  newDirective(
    syntax = initDirectiveSyntax(
      name = fontDirectiveID, form = dfContainer,
      parameters = @[
        labeledParam("size", dpLength,
          documentation = "Point size, or 1.5em / 120% relative to the surrounding text."),
        labeledParam("family", dpString,
          documentation = "Font family name; falls back to the editor font when unavailable."),
        labeledParam("weight", dpKeyword, allowed = @["regular", "bold"],
          defaultValue = dvKeyword("regular"), hasDefault = true,
          documentation = "Font weight.")]),
    completion = DirectiveCompletion(
      title: "font", subtitle: "Set size, family, or weight for a span",
      keywords: @["size", "typeface", "typography"],
      snippet: "@font(size: |){}", symbolName: "textformat.size"),
    styleProc = proc (args: DirectiveArguments, ctx: DirectiveContext): DirectiveStyle {.closure, gcsafe.} =
      # An invalid call mutes rather than restyles, so a typo reads as broken
      # instead of silently doing nothing.
      if not args.isValid:
        return DirectiveStyle(font: inheritFontTransform,
                              attributes: @[(akForegroundColor, av(ctx.theme.disabledText))])
      var transform = DirectiveFontTransform(sizeKind: dsInherit)
      let (size, hasSize) = args.lengthArg("size", ctx.inheritedFont.size)
      if hasSize:
        transform.sizeKind = dsAbsolute
        transform.sizeValue = size
      let (family, hasFamily) = args.stringArg("family")
      if hasFamily and family.len > 0:
        transform.familyName = family
      let (weight, hasWeight) = args.stringArg("weight")
      if hasWeight and weight == "bold":
        transform.traits = {ftBold}
        transform.hasTraits = true
      DirectiveStyle(font: transform, attributes: @[]),
    htmlProc = proc (args: DirectiveArguments, bodyHTML: string): string {.closure, gcsafe.} =
      var css: seq[string] = @[]
      let (size, hasSize) = args.numberArg("size")
      if hasSize: css.add "font-size:" & formatFloat(size, ffDecimal, 1) & "px"
      let (family, hasFamily) = args.stringArg("family")
      if hasFamily and family.len > 0: css.add "font-family:" & family
      let (weight, hasWeight) = args.stringArg("weight")
      if hasWeight and weight == "bold": css.add "font-weight:bold"
      if css.len == 0: bodyHTML
      else: "<span style=\"" & css.join(";") & "\">" & bodyHTML & "</span>")

proc newColorDirective*(): MarkdownDirective =
  ## `@color(red){…}` — container, positional argument.
  ##
  ## The schema declares an OPEN keyword set, not a closed one: the schema
  ## can't know the embedder's palette names, so resolution (and failure)
  ## belongs in `style`, not in argument coercion.
  newDirective(
    syntax = initDirectiveSyntax(
      name = colorDirectiveID, form = dfContainer,
      parameters = @[
        positionalParam(dpKeyword, allowed = @[], isRequired = true,
          documentation = "Standard colour name, or a name from your palette.")]),
    completion = DirectiveCompletion(
      title: "color", subtitle: "Tint a span",
      keywords: @["colour", "tint", "foreground"],
      snippet: "@color(|){}", symbolName: "paintpalette"),
    styleProc = proc (args: DirectiveArguments, ctx: DirectiveContext): DirectiveStyle {.closure, gcsafe.} =
      if args.positional.len == 0: return inheritStyle()
      let (name, ok) = asString(args.positional[0])
      if not ok: return inheritStyle()
      # An unresolvable name leaves the body alone rather than guessing — the
      # source stays readable and the mistake is visible.
      let (resolved, found) = namedSystemColor(name)
      if not found: return inheritStyle()
      DirectiveStyle(font: inheritFontTransform,
                     attributes: @[(akForegroundColor, av(resolved))]),
    htmlProc = proc (args: DirectiveArguments, bodyHTML: string): string {.closure, gcsafe.} =
      if args.positional.len == 0: return bodyHTML
      let (name, ok) = asString(args.positional[0])
      if not ok: return bodyHTML
      "<span style=\"color:" & name & "\">" & bodyHTML & "</span>")
