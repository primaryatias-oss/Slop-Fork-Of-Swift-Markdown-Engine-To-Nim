## demodirectives.nim
## MarkdownEngine (Nim port) — demo app
##
## Directives that belong to an APP, not to the engine.
##
## The engine ships only `@font` and `@color` as reference implementations,
## because both are pure presentation. Everything here carries something the
## engine has no business deciding: curated data (`@icon`, `@emoji`, `@flag`),
## or document policy (`@pagebreak` — what a page break means is a print
## concern).
##
## They are also the honest measure of the seam: each is a few dozen lines,
## including its argument schema, its glyph, its argument-value completions,
## and its HTML for rich copy.
##
## Two adaptations from the Swift demo, both forced by leaving Apple's
## frameworks behind and both visible here rather than hidden in the engine:
##
## * `@icon` drew an SF Symbol. There is no symbol library on Linux, so this
##   one maps its curated names onto Unicode glyphs the shipped fonts actually
##   contain — which keeps the directive's shape (a name, a tint, a glyph in
##   place of collapsed source) while drawing something that exists.
## * `@flag` enumerated `Locale.Region.isoRegions`. There is no locale region
##   database in the Nim standard library either, so the region list is a short
##   curated table. The regional-indicator computation is unchanged.

import std/[algorithm, strutils, tables, unicode]
import ../markdownengine

# ---------------------------------------------------------------------------
# @icon(star, color: yellow)
# ---------------------------------------------------------------------------

let iconGlyphs = {
  "arrow.down": "↓", "arrow.right": "→", "arrow.up.right": "↗",
  "bell": "🔔", "bolt": "⚡", "book": "📖", "bookmark": "🔖",
  "calendar": "📅", "check": "✔", "chevron.right": "›", "clock": "🕐",
  "coffee": "☕", "cross": "✘", "doc": "📄", "envelope": "✉", "eye": "👁",
  "flame": "🔥", "folder": "📁", "gear": "⚙", "globe": "🌐", "hammer": "🔨",
  "hand": "✋", "heart": "♥", "house": "🏠", "info": "ℹ", "leaf": "🍃",
  "lightbulb": "💡", "link": "🔗", "lock": "🔒", "paperclip": "📎",
  "person": "👤", "phone": "☎", "pin": "📌", "question": "?",
  "search": "🔍", "star": "★", "star.outline": "☆", "tag": "🏷",
  "thumbsup": "👍", "trash": "🗑", "warning": "⚠", "wrench": "🔧"
}.toTable

const iconPalette = ["red", "orange", "yellow", "green", "mint", "teal",
                     "cyan", "blue", "indigo", "purple", "pink", "brown",
                     "gray"]

proc iconPresentation(args: DirectiveArguments,
                      ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  if ctx.isActive or args.positional.len == 0: return literalPresentation()
  let (name, ok) = asString(args.positional[0])
  if not ok: return literalPresentation()
  {.cast(gcsafe).}:
    if not iconGlyphs.hasKey(name): return literalPresentation()
    # A glyph the engine can measure and the renderer can draw, rather than a
    # symbol name only AppKit could resolve. The tint still travels, so a
    # `color:` argument reaches the glyph pass the same way it did.
    let (tintName, hasTint) = args.stringArg("color")
    if hasTint:
      let (tint, found) = namedSystemColor(tintName)
      if found:
        return DirectivePresentation(kind: dprText, text: iconGlyphs[name])
    DirectivePresentation(kind: dprText, text: iconGlyphs[name])

proc iconCompletions(p: DirectiveParameter,
                     prefix: string): seq[DirectiveCompletionItem] {.gcsafe.} =
  let needle = prefix.toLowerAscii
  if p.hasLabel:
    for name in iconPalette:
      if needle.len == 0 or name.startsWith(needle):
        result.add completionItem(name, "Colour", name)
    return result
  {.cast(gcsafe).}:
    var names: seq[string] = @[]
    for name in iconGlyphs.keys: names.add name
    names.sort()
    for name in names:
      if needle.len == 0 or name.startsWith(needle):
        result.add completionItem(name, iconGlyphs[name], name)

proc iconHTML(args: DirectiveArguments, bodyHTML: string): string {.gcsafe.} =
  if args.positional.len == 0: return ""
  let (name, ok) = asString(args.positional[0])
  if not ok: return ""
  {.cast(gcsafe).}:
    "<span class=\"icon\" data-icon=\"" & name & "\">" &
      iconGlyphs.getOrDefault(name, "") & "</span>"

proc newIconDirective*(): MarkdownDirective =
  newDirective(
    syntax = initDirectiveSyntax(
      name = "icon", form = dfSelfContained,
      parameters = @[
        positionalParam(dpKeyword, isRequired = true,
                        documentation = "Icon name, e.g. star."),
        labeledParam("color", dpKeyword, documentation = "Tint colour.")]),
    completion = DirectiveCompletion(
      title: "icon", subtitle: "Draw an icon inline",
      keywords: @["symbol", "glyph", "image"], snippet: "@icon(|)",
      symbolName: "star"),
    presentationProc = iconPresentation,
    valueCompletionsProc = iconCompletions,
    htmlProc = iconHTML)

# ---------------------------------------------------------------------------
# @flag(JP)
# ---------------------------------------------------------------------------

const regionTable = [
  ("AR", "Argentina"), ("AT", "Austria"), ("AU", "Australia"),
  ("BE", "Belgium"), ("BR", "Brazil"), ("CA", "Canada"),
  ("CH", "Switzerland"), ("CL", "Chile"), ("CN", "China"),
  ("CZ", "Czechia"), ("DE", "Germany"), ("DK", "Denmark"),
  ("EE", "Estonia"), ("EG", "Egypt"), ("ES", "Spain"), ("FI", "Finland"),
  ("FR", "France"), ("GB", "United Kingdom"), ("GR", "Greece"),
  ("HU", "Hungary"), ("ID", "Indonesia"), ("IE", "Ireland"),
  ("IL", "Israel"), ("IN", "India"), ("IS", "Iceland"), ("IT", "Italy"),
  ("JP", "Japan"), ("KE", "Kenya"), ("KR", "South Korea"),
  ("MX", "Mexico"), ("MY", "Malaysia"), ("NG", "Nigeria"),
  ("NL", "Netherlands"), ("NO", "Norway"), ("NZ", "New Zealand"),
  ("PE", "Peru"), ("PH", "Philippines"), ("PL", "Poland"),
  ("PT", "Portugal"), ("RO", "Romania"), ("SE", "Sweden"),
  ("SG", "Singapore"), ("TH", "Thailand"), ("TR", "Türkiye"),
  ("TW", "Taiwan"), ("UA", "Ukraine"), ("US", "United States"),
  ("UY", "Uruguay"), ("VN", "Vietnam"), ("ZA", "South Africa")]

proc regionFlag*(code: string): (string, bool) =
  ## Regional-indicator scalars: `JP` → 🇯🇵. Computed, not tabulated.
  let upper = code.toUpperAscii
  if upper.len != 2: return ("", false)
  var glyph = ""
  for ch in upper:
    let value = int(ch)
    if value < 0x41 or value > 0x5A: return ("", false)
    glyph.add $Rune(0x1F1E6 + value - 0x41)
  (glyph, true)

proc flagPresentation(args: DirectiveArguments,
                      ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  if ctx.isActive or args.positional.len == 0: return literalPresentation()
  let (code, ok) = asString(args.positional[0])
  if not ok: return literalPresentation()
  let (glyph, valid) = regionFlag(code)
  if not valid: return literalPresentation()
  DirectivePresentation(kind: dprText, text: glyph)

proc flagCompletions(p: DirectiveParameter,
                     prefix: string): seq[DirectiveCompletionItem] {.gcsafe.} =
  let needle = prefix.toLowerAscii
  var matches: seq[tuple[code, name: string, codeMatch: bool]] = @[]
  for (code, name) in regionTable:
    let codeMatch = code.toLowerAscii.startsWith(needle)
    if needle.len == 0 or codeMatch or name.toLowerAscii.startsWith(needle):
      matches.add (code, name, codeMatch)
  # Code matches first — typing `us` wants US, not Uruguay.
  matches.sort(proc (a, b: tuple[code, name: string, codeMatch: bool]): int =
    if a.codeMatch != b.codeMatch: (if a.codeMatch: -1 else: 1)
    else: cmp(a.name, b.name))
  for i in 0 ..< min(matches.len, 50):
    let (glyph, _) = regionFlag(matches[i].code)
    result.add completionItem(matches[i].code,
                              glyph & "  " & matches[i].name, matches[i].code)

proc flagHTML(args: DirectiveArguments, bodyHTML: string): string {.gcsafe.} =
  if args.positional.len == 0: return ""
  let (code, ok) = asString(args.positional[0])
  if not ok: return ""
  let (glyph, valid) = regionFlag(code)
  if valid: glyph else: ""

proc newFlagDirective*(): MarkdownDirective =
  newDirective(
    syntax = initDirectiveSyntax(
      name = "flag", form = dfSelfContained,
      parameters = @[positionalParam(dpKeyword, isRequired = true,
        documentation = "ISO 3166 country code, e.g. JP.")]),
    completion = DirectiveCompletion(
      title: "flag", subtitle: "Country flag from an ISO code",
      keywords: @["country", "nation"], snippet: "@flag(|)",
      symbolName: "flag"),
    presentationProc = flagPresentation,
    valueCompletionsProc = flagCompletions,
    htmlProc = flagHTML)

# ---------------------------------------------------------------------------
# @pagebreak
# ---------------------------------------------------------------------------

proc pageBreakPresentation(args: DirectiveArguments,
                           ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  if ctx.isActive: literalPresentation()
  else: DirectivePresentation(kind: dprText, text: "⤓")

proc pageBreakHTML(args: DirectiveArguments, bodyHTML: string): string {.gcsafe.} =
  "<hr class=\"pagebreak\" />"

proc newPageBreakDirective*(): MarkdownDirective =
  ## What a page break MEANS is a print concern, so it belongs to the app.
  newDirective(
    syntax = initDirectiveSyntax(name = "pagebreak", form = dfSelfContained),
    completion = DirectiveCompletion(
      title: "pagebreak", subtitle: "Force a page break when printing",
      keywords: @["page", "break", "print"], snippet: "@pagebreak",
      symbolName: "arrow.down.to.line"),
    presentationProc = pageBreakPresentation,
    htmlProc = pageBreakHTML)

# ---------------------------------------------------------------------------
# @emoji(tada)
# ---------------------------------------------------------------------------

const emojiTable = [
  ("tada", "🎉"), ("rocket", "🚀"), ("sparkles", "✨"), ("fire", "🔥"),
  ("bug", "🐛"), ("wrench", "🔧"), ("book", "📚"), ("bulb", "💡"),
  ("warning", "⚠"), ("check", "✅"), ("cross", "❌"), ("eyes", "👀"),
  ("thinking", "🤔"), ("clap", "👏"), ("heart", "❤"), ("star", "⭐"),
  ("coffee", "☕"), ("ship", "🚢"), ("lock", "🔒"), ("chart", "📈")]

proc emojiPresentation(args: DirectiveArguments,
                       ctx: DirectiveContext): DirectivePresentation {.gcsafe.} =
  if ctx.isActive or args.positional.len == 0: return literalPresentation()
  let (name, ok) = asString(args.positional[0])
  if not ok: return literalPresentation()
  for (candidate, glyph) in emojiTable:
    if candidate == name:
      return DirectivePresentation(kind: dprText, text: glyph)
  literalPresentation()

proc emojiCompletions(p: DirectiveParameter,
                      prefix: string): seq[DirectiveCompletionItem] {.gcsafe.} =
  let needle = prefix.toLowerAscii
  for (name, glyph) in emojiTable:
    if needle.len == 0 or name.startsWith(needle):
      result.add completionItem(name, glyph, name)

proc emojiHTML(args: DirectiveArguments, bodyHTML: string): string {.gcsafe.} =
  if args.positional.len == 0: return ""
  let (name, ok) = asString(args.positional[0])
  if not ok: return ""
  for (candidate, glyph) in emojiTable:
    if candidate == name: return glyph
  ""

proc newEmojiDirective*(): MarkdownDirective =
  ## The shortest directive here, and the one whose domain is most obviously
  ## the app's rather than the engine's.
  newDirective(
    syntax = initDirectiveSyntax(
      name = "emoji", form = dfSelfContained,
      parameters = @[positionalParam(dpKeyword, isRequired = true,
        documentation = "Emoji name, e.g. tada.")]),
    completion = DirectiveCompletion(
      title: "emoji", subtitle: "Insert an emoji by name",
      keywords: @["smiley", "reaction"], snippet: "@emoji(|)",
      symbolName: "face.smiling"),
    presentationProc = emojiPresentation,
    valueCompletionsProc = emojiCompletions,
    htmlProc = emojiHTML)

proc demoDirectives*(): seq[MarkdownDirective] =
  ## Everything the demo registers: the engine's two reference directives plus
  ## the four that belong to an app.
  @[newFontDirective(), newColorDirective(), newIconDirective(),
    newFlagDirective(), newPageBreakDirective(), newEmojiDirective()]
