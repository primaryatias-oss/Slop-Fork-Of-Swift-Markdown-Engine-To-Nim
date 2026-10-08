## test_directive_composition.nim
## A container directive's font transform COMPOSES over the font inherited at
## that point in the tree, in both directions: the body keeps the traits of
## everything enclosing it, and markup nested inside the body keeps the
## directive's font.
##
## Ported from `DirectiveCompositionTests.swift`. This is the property that
## makes directives tree-shaped rather than positional, so it is tested from
## both ends and through nesting.

import std/[unittest, strformat]
import markdownengine
import ./directive_fixtures

const base = 14.0

proc scaleStyle(args: DirectiveArguments,
                ctx: DirectiveContext): DirectiveStyle {.gcsafe.} =
  let (factor, ok) = args.numberArg("by")
  if not ok: return inheritStyle()
  DirectiveStyle(font: DirectiveFontTransform(sizeKind: dsScale, sizeValue: factor))

proc scaleDirective(): MarkdownDirective =
  ## A directive that only scales, to prove relative units compose.
  newDirective(initDirectiveSyntax("scale", dfContainer,
                 parameters = @[labeledParam("by", dpNumber)]),
               styleProc = scaleStyle)

proc configuration(): MarkdownEditorConfiguration =
  result = initConfiguration()
  result.fontSize = base
  result.directives = @[newFontDirective(), newColorDirective(),
                        markerDirective(), scaleDirective()]

proc styleOf(text: string, caret = -1): seq[StyledRange] =
  var cfg = configuration()
  styleAttributes(initText(text), cfg, caretLocation = caret,
                  containerWidth = 600.0)

proc fontAt(text, needle: string, caret = -1): (FontDesc, bool) =
  ## Effective font at the first occurrence of `needle`.
  let t = initText(text)
  let position = t.rangeOf(needle).location
  result = (FontDesc(), false)
  for (r, a) in styleOf(text, caret):
    if r.contains(position) and a.has(akFont):
      result = (a.get(akFont).fontVal, true)

proc colorAt(text, needle: string): (Color, bool) =
  let t = initText(text)
  let position = t.rangeOf(needle).location
  result = (Color(), false)
  for (r, a) in styleOf(text):
    if r.contains(position) and a.has(akForegroundColor):
      result = (a.get(akForegroundColor).colorVal, true)

proc sizeAt(text, needle: string, caret = -1): float =
  let (f, ok) = fontAt(text, needle, caret)
  if ok: f.size else: -1.0

suite "directive composition — the directive applies":

  test "an absolute size applies to the body":
    check sizeAt("@font(size: 18){hello}", "hello") == 18.0

  test "a relative size resolves against the inherited size":
    check sizeAt("@font(size: 1.5em){hello}", "hello") == base * 1.5
    check sizeAt("@font(size: 50%){hello}", "hello") == base * 0.5

  test "a weight argument applies":
    let (f, ok) = fontAt("@font(weight: bold){hello}", "hello")
    check ok
    check ftBold in f.traits

  test "a non-font directive leaves the body's font alone":
    check sizeAt("@color(red){hello}", "hello") == base

  test "a colour directive resolves a named system colour":
    let (c, ok) = colorAt("@color(red){hello}", "hello")
    check ok
    check c == systemRed

suite "directive composition — outward: the body keeps its context":

  test "inside a heading, the directive keeps the heading's bold":
    let (f, ok) = fontAt("# @font(size: 18){hello}", "hello")
    check ok
    check f.size == 18.0
    check ftBold in f.traits

  test "inside emphasis, the directive keeps the italic":
    let (f, ok) = fontAt("*@font(size: 18){hello}*", "hello")
    check ok
    check f.size == 18.0
    check ftItalic in f.traits

suite "directive composition — inward: nested markup keeps the font":

  test "bold inside the body keeps the directive's size":
    # The motivating case.
    let (f, ok) = fontAt("@font(size: 18){**bold**}", "bold")
    check ok
    check f.size == 18.0
    check ftBold in f.traits

  test "italic inside the body keeps the directive's size":
    let (f, ok) = fontAt("@font(size: 18){*it*}", "it")
    check ok
    check f.size == 18.0
    check ftItalic in f.traits

  test "bold and italic together keep the directive's size":
    let (f, ok) = fontAt("@font(size: 18){***both***}", "both")
    check ok
    check f.size == 18.0
    check ftBold in f.traits
    check ftItalic in f.traits

suite "directive composition — nesting":

  test "nested directives compose, innermost last":
    # 14 → ×2 = 28 → ×0.5 = 14
    check sizeAt("@scale(by: 2){@scale(by: 0.5){x}}", "x") == base

  test "a size directive inside a scale resolves against the scaled size":
    # 14 → ×2 = 28 → 1.5em of 28 = 42
    check sizeAt("@scale(by: 2){@font(size: 1.5em){x}}", "x") == 42.0

suite "directive composition — containment":

  test "the directive's font stops at its closing brace":
    let text = "@font(size: 18){big} small"
    check sizeAt(text, "big") == 18.0
    let tail = sizeAt(text, "small")
    check (tail < 0 or tail == base)

  test "a directive does not leak into the next paragraph":
    let tail = sizeAt("@font(size: 18){big}\n\nnext paragraph", "next")
    check (tail < 0 or tail == base)

suite "directive composition — invalid calls":

  test "an invalid argument mutes the body instead of restyling it":
    # `size: huge` fails length coercion, so the font directive mutes.
    let text = "@font(size: huge){hello}"
    let (c, ok) = colorAt(text, "hello")
    check ok
    check c == defaultTheme.disabledText
    check sizeAt(text, "hello") == base

  test "an unknown label is a diagnostic, and the body still renders":
    check sizeAt("@font(colour: red){hello}", "hello") == base

suite "directive composition — caret behaviour":

  test "the syntax reveals with the caret inside and shrinks outside":
    var cfg = configuration()
    let hidden = cfg.markers.hiddenMarkerFontSize
    let text = "@font(size: 18){hello}"
    check sizeAt(text, "@font") == hidden
    check sizeAt(text, "@font", caret = 3) != hidden

  test "the body keeps the directive's size while the syntax is revealed":
    check sizeAt("@font(size: 18){hello}", "hello", caret = 3) == 18.0

suite "directive composition — scoped restyle":

  test "scoped styling matches the full pass for a directive paragraph":
    let text = "intro\n\n# @font(size: 18){**big**} tail\n\noutro"
    let t = initText(text)
    let paragraph = t.paragraphRange(t.rangeOf("@font"))
    var cfg = configuration()

    proc digest(scoped: seq[Range], hasScope: bool): seq[string] =
      let base: Attrs = @[(akFont, av(FontDesc(family: "sans", size: 14.0)))]
      for (r, a) in flattenedRuns(
          styleAttributes(t, cfg, containerWidth = 600.0,
                          scopedRanges = scoped, hasScope = hasScope),
          base, t.len):
        if intersects(r, paragraph):
          var keys = ""
          for (k, _) in a: keys.add $k & ","
          let size = if a.has(akFont): $a.get(akFont).fontVal.size else: "-"
          result.add &"{r.location}:{r.length}[{keys}]{size}"

    check digest(@[paragraph], true) == digest(@[], false)

suite "directive composition — unregistered":

  test "an unregistered directive leaves the text completely alone":
    var cfg = initConfiguration()
    cfg.fontSize = base
    let text = "@font(size: 18){hello}"
    let t = initText(text)
    let position = t.rangeOf("hello").location
    var size = -1.0
    for (r, a) in styleAttributes(t, cfg, caretLocation = -1,
                                  containerWidth = 600.0):
      if r.contains(position) and a.has(akFont): size = a.get(akFont).fontVal.size
    check (size < 0 or size == base)
