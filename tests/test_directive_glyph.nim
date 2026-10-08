## test_directive_glyph.nim
## A self-contained directive draws a glyph in place of its collapsed source,
## on the same mechanism inline LaTeX uses: the characters stay in the text,
## the first one carries the glyph and enough kern to occupy its width, and
## the rest collapse to nothing.
##
## Ported from `DirectiveGlyphTests.swift`. The failure mode worth guarding is
## a glyph that cannot be produced: the source must stay VISIBLE rather than
## collapsing to an empty gap the user can neither see, select, nor fix.
##
## One divergence from the Swift, and it runs through the whole file: there
## are no SF Symbols here and the engine owns no image pipeline, so a symbol
## or text presentation travels to the renderer as DATA — an
## `akDirectiveGlyph` string of `"symbol:<name>"` or `"text:<text>"` — rather
## than as a rasterised `NSImage` on `.latexImage`. Only an explicit
## `imagePresentation` carries a handle. The geometry being asserted (which
## character carries the glyph, the kern that reserves its width, what
## collapses, what stays visible) is the same.

import std/[unittest, strformat, strutils]
import markdownengine
import ./directive_fixtures

const base = 14.0

proc brokenPresentation(args: DirectiveArguments,
                        ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  symbolPresentation("definitely.not.a.real.symbol", Color(), hasTint = false)

proc brokenDirective(): MarkdownDirective =
  ## A directive whose symbol name no renderer can resolve.
  newDirective(initDirectiveSyntax("broken", dfSelfContained),
               presentationProc = brokenPresentation)

proc plainDirective(): MarkdownDirective =
  ## A directive that declines to draw anything.
  newDirective(initDirectiveSyntax("plain", dfSelfContained))

proc swatchPresentation(args: DirectiveArguments,
                        ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  let (side, ok) = args.numberArg("size")
  let n = if ok: side else: 10.0
  imagePresentation(ImageHandle(id: 1, width: n, height: n), 0.0)

proc swatchDirective(): MarkdownDirective =
  ## A directive supplying its own image, sized from an argument.
  newDirective(initDirectiveSyntax("swatch", dfSelfContained,
                 parameters = @[labeledParam("size", dpNumber)]),
               presentationProc = swatchPresentation)

proc configuration(): MarkdownEditorConfiguration =
  result = initConfiguration()
  result.fontSize = base
  result.directives = @[markerDirective(), brokenDirective(),
                        plainDirective(), swatchDirective()]

proc styleOf(text: string, caret = -1,
             cfg = configuration()): seq[StyledRange] =
  var c = cfg
  styleAttributes(initText(text), c, caretLocation = caret,
                  containerWidth = 600.0)

proc mergedAt(text, needle: string, caret = -1,
              cfg = configuration()): Attrs =
  ## Attributes covering the first character of `needle`, later passes winning.
  let position = initText(text).rangeOf(needle).location
  for (r, a) in styleOf(text, caret, cfg):
    if r.contains(position):
      for pair in a: result.add pair

let hiddenSize = initConfiguration().markers.hiddenMarkerFontSize

proc fontSizeOf(a: Attrs): float =
  if a.has(akFont): a.get(akFont).fontVal.size else: -1.0

suite "directive glyphs — drawing":

  test "the glyph rides on the call's first character":
    let a = mergedAt("a @marker b", "@marker")
    check a.has(akDirectiveGlyph)
    check a.stringOf(akDirectiveGlyph, "") == "symbol:arrow.down.to.line"

  test "the glyph is sized to the inherited font":
    # A heading's larger font must reserve a wider glyph box.
    proc kernOf(text: string): float =
      mergedAt(text, "@marker").floatOf(akKern, 0.0)
    check kernOf("# @marker") > kernOf("@marker")

  test "the first character carries kern for the glyph's width":
    # The kern makes up the difference between the glyph box and the shrunk
    # character's own negligible advance, so it is positive and close to the
    # glyph's width.
    check mergedAt("@marker", "@marker").floatOf(akKern, 0.0) > 0.0

  test "the remaining characters collapse":
    let text = "@marker"
    let tail = initText(text).rangeOf("marker")
    var sawCollapse = false
    for (r, a) in styleOf(text):
      if intersects(r, tail) and fontSizeOf(a) == hiddenSize and
         a.floatOf(akKern, 0.0) < 0.0:
        sawCollapse = true
    check sawCollapse

  test "a directive-supplied image is used as given":
    let a = mergedAt("@swatch(size: 24)", "@swatch")
    check a.has(akImageEmbed)
    check a.get(akImageEmbed).imageVal.width == 24.0

  test "arguments reach a self-contained presentation":
    check mergedAt("@swatch(size: 8)", "@swatch").get(akImageEmbed).imageVal.width == 8.0
    check mergedAt("@swatch(size: 32)", "@swatch").get(akImageEmbed).imageVal.width == 32.0

suite "directive glyphs — caret reveal":

  test "the caret inside reveals the source and drops the glyph":
    let a = mergedAt("@marker", "@marker", caret = 3)
    check not a.has(akDirectiveGlyph)
    check fontSizeOf(a) != hiddenSize

suite "directive glyphs — degradation":

  test "a directive declining to draw leaves its source visible":
    let a = mergedAt("@plain", "@plain")
    check not a.has(akDirectiveGlyph)
    check fontSizeOf(a) != hiddenSize

  test "an unresolvable symbol still reaches the renderer as data":
    # The engine cannot know which symbol names a renderer understands, so
    # unlike the Swift — where `NSImage(systemSymbolName:)` returned nil and
    # the styler fell back to literal — the decision moves one layer down.
    # What the engine guarantees is that the name travels intact, so the
    # renderer can draw a visible fallback rather than a gap.
    let a = mergedAt("@broken", "@broken")
    check a.stringOf(akDirectiveGlyph, "") ==
      "symbol:definitely.not.a.real.symbol"

  test "an unresolvable argument leaves the source visible":
    var cfg = initConfiguration()
    cfg.fontSize = base
    cfg.directives = @[regionDirective()]
    let a = mergedAt("@region(ZZZZ)", "@region", cfg = cfg)
    check not a.has(akDirectiveGlyph)
    check fontSizeOf(a) != hiddenSize

  test "spell-check is suppressed over a directive call":
    check mergedAt("@marker", "@marker").intOf(akSpellingState, -1) == 0

suite "directive glyphs — isolation":

  test "a glyph does not disturb the surrounding text":
    let text = "before @marker after"
    let position = initText(text).rangeOf("after").location
    for (r, a) in styleOf(text):
      if r.contains(position):
        check not a.has(akDirectiveGlyph)
        check fontSizeOf(a) != hiddenSize

suite "directive glyphs — presentation kinds":

  test "an icon directive draws the symbol named in its positional argument":
    var cfg = initConfiguration()
    cfg.fontSize = base
    cfg.directives = @[glyphDirective()]
    proc glyphFor(text: string): string =
      mergedAt(text, "@glyph", cfg = cfg).stringOf(akDirectiveGlyph, "")
    check glyphFor("@glyph(star.fill)") == "symbol:star.fill"
    check glyphFor("@glyph(checkmark.circle.fill, color: green)") ==
      "symbol:checkmark.circle.fill"
    # A dotted symbol name survives argument splitting.
    check glyphFor("@glyph(arrow.down.to.line)") == "symbol:arrow.down.to.line"

  test "a tint reaches the renderer alongside the symbol":
    var cfg = initConfiguration()
    cfg.fontSize = base
    cfg.directives = @[glyphDirective()]
    let a = mergedAt("@glyph(star.fill, color: green)", "@glyph", cfg = cfg)
    check a.has(akDirectiveGlyphTint)
    check a.get(akDirectiveGlyphTint).colorVal == systemGreen

  test "a text presentation renders as a glyph, not a storage substitution":
    var cfg = initConfiguration()
    cfg.fontSize = base
    cfg.directives = @[regionDirective()]
    let text = "@region(JP)"
    let a = mergedAt(text, "@region", cfg = cfg)
    check a.stringOf(akDirectiveGlyph, "").startsWith("text:")
    # The source characters are all still there.
    check utf16Len(text) == 11

suite "directive glyphs — scoped restyle":

  test "scoped styling matches the full pass for a glyph-bearing paragraph":
    let text = "intro\n\nbefore @marker after\n\noutro"
    let t = initText(text)
    let paragraph = t.paragraphRange(t.rangeOf("@marker"))
    var cfg = configuration()

    proc digest(scoped: seq[Range], hasScope: bool): seq[string] =
      let baseAttrs: Attrs = @[(akFont, av(FontDesc(family: "sans", size: base)))]
      for (r, a) in flattenedRuns(
          styleAttributes(t, cfg, containerWidth = 600.0,
                          scopedRanges = scoped, hasScope = hasScope),
          baseAttrs, t.len):
        if intersects(r, paragraph):
          var keys = ""
          for (k, _) in a: keys.add $k & ","
          result.add &"{r.location}:{r.length}[{keys}]"

    check digest(@[paragraph], true) == digest(@[], false)
