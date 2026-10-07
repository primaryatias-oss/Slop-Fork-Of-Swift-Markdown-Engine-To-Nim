## test_directive_completion.nim
## Phase 4 — what the caret is trying to complete.
##
## Ported from `DirectiveCompletionTests.swift`.
##
## The scanner's job is the opposite of the parser's: it must succeed on text
## the parser REJECTS, because `@gly` and `@glyph(sta` are what a directive
## looks like while you are still typing it. So these cases are mostly about
## incomplete input, plus the places a picker must stay shut.

import std/[unittest, sequtils, strutils]
import markdownengine
import ./directive_fixtures

let directives = @[newFontDirective(), newColorDirective(),
                   glyphDirective(), regionDirective(), markerDirective()]
let registry = initDirectiveRegistry(directives)

proc contextAt(text: string): (DirectiveCompletionContext, bool) =
  ## Context at the caret marked by `|` in `text`.
  let caret = text.find('|')
  completionContext(initText(text.replace("|", "")), caret, registry, directives)

proc titles(text: string): seq[string] =
  let (ctx, ok) = contextAt(text)
  if not ok: return @[]
  ctx.candidates.mapIt(it.title)

proc opens(text: string): bool =
  contextAt(text)[1]

suite "directive completion — name":

  test "a bare marker offers nothing":
    # A context here would capture Enter as "confirm" in ordinary prose any
    # time a marker precedes it (`Ping @` then a plain newline) — wait for at
    # least one typed character.
    check not opens("@|")

  test "one typed character offers every matching directive":
    check "font" in titles("@f|")

  test "an exact match to a directive needing nothing closes the picker":
    # `marker` is self-contained with no parameters — fully typing its name
    # is a finished call, not something still being completed.
    check not opens("@marker|")

  test "an exact match to a directive that still needs arguments stays open":
    # `glyph` requires a positional argument, so the name alone is not a
    # finished call yet.
    check opens("@glyph|")

  test "a partial name filters":
    check titles("@reg|") == @["region"]
    check titles("@gly|") == @["glyph"]

  test "a name match outranks a keyword-only match":
    # `fo` hits `font` by name and `color` by its "foreground" keyword. Both
    # belong in the list; the name match must lead.
    let candidates = titles("@fo|")
    check candidates[0] == "font"
    check "color" in candidates

  test "keywords match too, and rank below name matches":
    # `country` is a keyword of `region`, not a directive name.
    check titles("@country|") == @["region"]

  test "the name context replaces from the marker to the caret":
    let t = initText("hello @fo")
    let (ctx, ok) = completionContext(t, t.len, registry, directives)
    check ok
    check ctx.replacementRange == rng(6, 3)
    check ctx.prefix == "fo"

  test "a name candidate inserts its snippet and reports the caret slot":
    let (ctx, ok) = contextAt("@fo|")
    check ok
    check ctx.candidates[0].insertion == "@font(size: ){}"
    check ctx.candidates[0].hasCaretOffset
    check ctx.candidates[0].caretOffset == 12      # just after "size: "

  test "an unmatched name offers nothing":
    check not opens("@zzz|")

suite "directive completion — values":

  test "a positional argument offers the directive's values":
    let candidates = titles("@glyph(sta|")
    check "star.fill" in candidates
    check candidates.allIt(it.startsWith("sta"))

  test "an empty argument offers the unfiltered list":
    check titles("@glyph(|").len > 0

  test "a labelled argument resolves to its own parameter":
    let (ctx, ok) = contextAt("@glyph(star.fill, color: gr|")
    check ok
    check ctx.candidates.mapIt(it.title) == @["green"]
    check ctx.kind.kind == dckArgument
    check ctx.kind.label == "color"
    check ctx.kind.index == 1

  test "the value context replaces just the typed value":
    let t = initText("@glyph(star.fill, color: gr")
    let (ctx, ok) = completionContext(t, t.len, registry, directives)
    check ok
    # "gr" only — not the label, not the preceding argument.
    check ctx.replacementRange == rng(25, 2)
    check ctx.prefix == "gr"

  test "a name replacement covers text after the caret too":
    # Caret mid-identifier in an existing name: a pick must replace the WHOLE
    # name, or the characters after the caret ("nt") survive past the
    # inserted snippet.
    let (ctx, ok) = contextAt("@fo|nt")
    check ok
    check ctx.replacementRange == rng(0, 5)
    check ctx.prefix == "fo"

  test "a value replacement covers text after the caret too":
    let (ctx, ok) = contextAt("@glyph(sta|r)")
    check ok
    check ctx.replacementRange == rng(7, 4)
    check ctx.prefix == "sta"

  test "a name pick on a call that already has arguments does not duplicate":
    # `@fo|nt(size: 18){x}` picking "font" must not bring its own snippet's
    # `(…){…}` — that call already has one. Insert just the marker and name,
    # caret landing right before what is already there.
    let (ctx, ok) = contextAt("@fo|nt(size: 18){x}")
    check ok
    let item = ctx.candidates.filterIt(it.title == "font")[0]
    check item.insertion == "@font"
    check not item.hasCaretOffset

  test "a name pick on a call already followed by a body does not duplicate":
    let (ctx, ok) = contextAt("@marke|r{x}")
    check ok
    let item = ctx.candidates.filterIt(it.title == "marker")[0]
    check item.insertion == "@marker"
    check not item.hasCaretOffset

  test "a container directive's name stays open when typed in full":
    # `font`'s parameters are all optional, but its form is container — a
    # body is still required, so the name alone is not a finished call the
    # way `@marker` is.
    check opens("@font|")

  test "a trailing period after an exact match is not absorbed":
    # The forward scan must stop before the period, mirroring the parser (a
    # `.` only continues a name when an identifier-start character follows).
    # Otherwise the period is swallowed into the replacement range, and the
    # exact-match check — which only fires when the scan ends exactly at the
    # caret — never closes the picker.
    check not opens("@marker|. Next")

  test "a trailing period after a partial name is excluded from the range":
    let (ctx, ok) = contextAt("Hello @gl|. More")
    check ok
    check ctx.prefix == "gl"
    check ctx.replacementRange == rng(6, 3)

  test "a quoted value filters on its content, not the quote":
    let (ctx, ok) = contextAt("@glyph(\"sta|r\")")
    check ok
    check ctx.prefix == "sta"
    check "star.fill" in ctx.candidates.mapIt(it.title)

  test "a quoted value replacement excludes the quotes":
    let (ctx, ok) = contextAt("@glyph(\"sta|r\")")
    check ok
    # Content is "star" inside the quotes at indices 8 ..< 12.
    check ctx.replacementRange == rng(8, 4)

  test "a closed keyword set completes from the schema alone":
    # The font directive declares weight: keyword(regular|bold) and
    # implements no value completions of its own.
    check titles("@font(weight: b|") == @["bold"]

  test "a dynamic domain matches on more than one field":
    check "JP" in titles("@region(JP|")
    check "JP" in titles("@region(jap|")

  test "a candidate previews the result it will produce":
    let (ctx, ok) = contextAt("@region(JP|")
    check ok
    let item = ctx.candidates.filterIt(it.title == "JP")[0]
    check item.detail == "\u{1F1EF}\u{1F1F5}"
    check item.insertion == "JP"

  test "a parameter with no enumerable domain offers nothing":
    # `size` is a length — there is no list to offer.
    check not opens("@font(size: 1|")

  test "an unregistered directive's arguments offer nothing":
    check not opens("@nope(x|")

suite "directive completion — where the picker stays shut":

  test "a closed call offers nothing":
    check not opens("@glyph(star.fill)| ")
    check not opens("@glyph(star.fill) and then|")

  test "the caret inside a container body is not completing arguments":
    check not opens("@font(size: 18){hel|")

  test "an email address does not open a picker":
    check not opens("jason@example|")

  test "a marker run does not open a picker":
    check not opens("@@fo|")

  test "an escaped marker does not open a picker":
    check not opens("\\@fo|")

  test "the scan stops at the line start":
    check not opens("@font\nplain text|")

  test "a bare marker with no directives registered offers nothing":
    let (_, ok) = completionContext(initText("@"), 1,
                                    emptyDirectiveRegistry(), @[])
    check not ok

  test "markup delimiters before the marker still open a picker":
    check titles("*@reg|") == @["region"]
    check titles("- @reg|") == @["region"]
    check titles("**@reg|") == @["region"]

suite "directive completion — commit requests":

  test "a request carries the range, the insertion and the caret":
    let (ctx, ok) = contextAt("@fo|")
    check ok
    let request = completionRequest("doc", ctx, ctx.candidates[0])
    check request.replacementRange == ctx.replacementRange
    check request.insertion == "@font(size: ){}"
    check request.hasCaretOffset
    check request.caretOffset == 12
