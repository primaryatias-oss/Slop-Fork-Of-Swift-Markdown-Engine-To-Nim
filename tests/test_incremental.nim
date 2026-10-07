## test_incremental.nim
## Differential fuzz for the incremental pipeline.
##
## Ported from `ParseIncrementalEquivalenceTests.swift`,
## `RestyleApplyEquivalenceTests.swift` and `ScopedListRestyleEquivalenceTests.swift`.
##
## After every random edit, `DocumentParseState` — descriptor-driven and
## scan-driven — must produce tokens identical to a from-scratch full parse,
## and the incremental backtick census must equal the full scan. The
## incremental paths are free to fall back to a full parse at any time;
## equivalence is the only contract, never "it took the fast path".

import std/[unittest, strutils, strformat]
import markdownengine

# ---------------------------------------------------------------------------
# Deterministic PRNG (SplitMix64) — a failing seed reproduces exactly.
# ---------------------------------------------------------------------------

type Rng = object
  state: uint64

proc next(r: var Rng): uint64 =
  r.state = r.state + 0x9E3779B97F4A7C15'u64
  var z = r.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc intBelow(r: var Rng, upper: int): int =
  if upper <= 0: 0 else: int(r.next() mod uint64(upper))

proc pick[T](r: var Rng, a: openArray[T]): T =
  a[r.intBelow(a.len)]

const lineTemplates = [
  "Plain prose with **bold** and *italic* text here.",
  "# Heading level one",
  "## Second heading",
  "- list item with `inline code`",
  "1. ordered item",
  "> a blockquote line",
  "| a | b |", "|---|---|", "| 1 | 2 |",
  "```swift", "let x = 1", "```",
  "$$", "E = mc^2", "$$",
  "A [[Wiki Link]] and ==highlight== and ~~strike~~.",
  "Inline $x^2$ latex and an ![[embed.png]] image.",
  "",
]

const editSnippets = [
  "x", "ab", " ", "\n", "`", "``", "```", "$", "$$", "**", "- ", "# ",
  "| c |", "[[N]]", "\n\n", "word and more",
]

proc makeDoc(r: var Rng, lines: int): string =
  var parts: seq[string] = @[]
  for _ in 0 ..< lines: parts.add r.pick(lineTemplates)
  parts.join("\n")

proc dump(tokens: seq[MarkdownToken]): seq[string] =
  ## A comparable projection: kind, geometry, markers and extension id.
  for tok in tokens:
    var markers = ""
    for i, m in tok.markerRanges:
      if i > 0: markers.add ","
      markers.add $m
    result.add &"{tok.kind}|{tok.range}|{tok.contentRange}|{markers}|{tok.extensionID}"

proc groundTruth(text: string, registry: ExtensionRegistry): seq[string] =
  let t = initText(text)
  dump(fullTokens(computeBlocks(t, registry), t, registry))

proc replacing(text: string, r: Range, insert: string): string =
  let t = initText(text)
  utf16ToString(t.replacingCharacters(r, toUtf16(insert)))

proc runFuzz(seed: uint64, useDescriptor: bool, widen = false,
             steps = 250) =
  var rng = Rng(state: seed)
  let registry = initRegistry(@[newHighlightExtension(),
                                newStrikethroughExtension()])
  let state = newDocumentParseState()
  var text = makeDoc(rng, 40)

  # Seed the state with the initial document.
  discard state.tokens(initText(text), registry)

  for step in 0 ..< steps:
    let length = utf16Len(text)
    let loc = rng.intBelow(length + 1)
    let removeLen = min(rng.intBelow(6), length - loc)
    let insert = if rng.intBelow(4) == 0: "" else: rng.pick(editSnippets)
    text = replacing(text, rng(loc, removeLen), insert)

    var edit = ParseEditDescriptor()
    if useDescriptor:
      var editedRange = rng(loc, utf16Len(insert))
      if widen:
        # A containing region must be just as correct as the minimal one.
        let grow = rng.intBelow(3)
        let lo = max(0, editedRange.location - grow)
        let hi = min(utf16Len(text), maxRange(editedRange) + grow)
        editedRange = rng(lo, hi - lo)
      edit = ParseEditDescriptor(editedRange: editedRange,
                                 delta: utf16Len(insert) - removeLen)

    let incremental = dump(state.tokens(initText(text), edit, useDescriptor,
                                        registry))
    let full = groundTruth(text, registry)
    checkpoint(&"seed {seed:#x} step {step}: edit at {loc}, removed " &
               &"{removeLen}, inserted {insert.escape()}")
    require incremental == full          # stop at the first divergence

suite "incremental parse is equivalent to a full parse":

  test "descriptor-driven matches a full parse":
    runFuzz(0xA11CE'u64, useDescriptor = true)
    runFuzz(0xB0B'u64, useDescriptor = true)

  test "a widened descriptor matches a full parse":
    runFuzz(0xC0FFEE'u64, useDescriptor = true, widen = true)

  test "scan-driven matches a full parse":
    runFuzz(0xD00D'u64, useDescriptor = false)

  test "a registry change invalidates the splice base":
    # Tokens cached under one grammar must not be reused under another, or
    # `==x==` stays literal text after the extension is registered.
    let state = newDocumentParseState()
    let text = initText("a ==b== c")
    let plain = state.tokens(text, emptyRegistry())
    check plain.len == 0
    let withHighlight = state.tokens(text, initRegistry(@[newHighlightExtension()]))
    check withHighlight.len == 1
    check withHighlight[0].kind == tkExtensionSpan

suite "backtick census composes exactly":

  test "boundary cases compose":
    # Completing ``` between existing backticks, joining fences by deleting
    # the separator, runs of 4/6/7.
    let cases = [
      ("a``b", rng(2, 0), "`"),      # `` + ` → ```
      ("```\n```", rng(3, 1), ""),   # join to ``````
      ("````x````", rng(4, 1), "`"),
      ("abc", rng(1, 0), "```"),
      ("`````", rng(2, 1), ""),
    ]
    for (before, edit, insert) in cases:
      let beforeText = initText(before)
      let oldWindow = backtickWindowCount(beforeText, edit)
      let after = initText(replacing(before, edit, insert))
      let newRange = rng(edit.location, utf16Len(insert))
      let newWindow = backtickWindowCount(after, newRange)
      let composed = tripleBacktickCount(beforeText) - oldWindow + newWindow
      checkpoint(&"census composition for {before.escape()} + {insert.escape()}")
      check composed == tripleBacktickCount(after)

  test "the window census survives a fuzz":
    var rng0 = Rng(state: 0xFACE'u64)
    const alphabet = ["`", "a", "\n", "``", "b`"]
    var text = ""
    for _ in 0 ..< 60: text.add rng0.pick(alphabet)

    for step in 0 ..< 400:
      let t = initText(text)
      let loc = rng0.intBelow(t.len + 1)
      let removeLen = min(rng0.intBelow(4), t.len - loc)
      let insert = if rng0.intBelow(4) == 0: "" else: rng0.pick(alphabet)
      let editOld = rng(loc, removeLen)

      let oldWindow = backtickWindowCount(t, editOld)
      let afterText = replacing(text, editOld, insert)
      let after = initText(afterText)
      let editNew = rng(loc, utf16Len(insert))
      let newWindow = backtickWindowCount(after, editNew)

      let composed = tripleBacktickCount(t) - oldWindow + newWindow
      checkpoint(&"step {step}")
      require composed == tripleBacktickCount(after)
      text = afterText

proc attrsAt(runs: seq[StyledRange], index: int): Attrs =
  ## The attributes in force at `index`, over FLATTENED runs (the styler emits
  ## overlapping ranges pass by pass; only the flattened view is comparable).
  for (r, a) in runs:
    if r.contains(index): return a
  @[]

suite "restyle is equivalent to a full style pass":

  test "a scoped restyle matches styling the whole document":
    # The scoped path exists only to do less work. Inside the scope, every
    # attribute it produces must be the one the full pass would produce.
    let doc = """
# Heading

Some **bold** prose with a [[Wiki Link]].

- [ ] todo item
- [x] done item

```swift
let x = 1
```

| a | b |
|---|---|
| 1 | 2 |
"""
    var cfg = initConfiguration()
    let t = initText(doc)
    let base: Attrs = @[(akFont, av(FontDesc(family: "sans", size: 14.0)))]
    let full = flattenedRuns(
      styleAttributes(t, cfg, caretLocation = -1, containerWidth = 600.0),
      base, t.len)

    for probe in ["# Heading", "**bold**", "- [x] done item", "let x = 1",
                  "| 1 | 2 |"]:
      let paragraph = t.paragraphRange(t.rangeOf(probe))
      let scoped = flattenedRuns(
        styleAttributes(t, cfg, caretLocation = -1, containerWidth = 600.0,
                        scopedRanges = @[paragraph], hasScope = true),
        base, t.len)
      for i in paragraph.location ..< maxRange(paragraph):
        checkpoint(&"scope {probe.escape()} index {i}")
        require attrsAt(scoped, i) == attrsAt(full, i)

  test "ordered list display numbers survive a scoped restyle":
    # Source numbering is `1.` throughout; the styler paints the running
    # count over it. A scoped restyle sees only the third line, so it has to
    # seed the counter from the lines above rather than restart at 1.
    let t = initText("1. one\n1. two\n1. three\n")
    var cfg = initConfiguration()
    let third = t.paragraphRange(t.rangeOf("1. three"))

    proc displayNumber(runs: seq[StyledRange], within: Range): string =
      for (r, a) in runs:
        if containsRange(within, r) and a.has(akOrderedMarker):
          return a.stringOf(akOrderedMarker, "")
      ""

    let full = styleAttributes(t, cfg, caretLocation = -1, containerWidth = 600.0)
    let scoped = styleAttributes(t, cfg, caretLocation = -1,
                                 containerWidth = 600.0,
                                 scopedRanges = @[third], hasScope = true)
    check displayNumber(full, third) == "3."
    check displayNumber(scoped, third) == "3."

  test "the first ordered item is left alone when the source already matches":
    # No override attribute means the source text renders as-is — painting
    # "1." over "1." would be a pointless run split on every list in the
    # document.
    let t = initText("1. one\n1. two\n")
    var cfg = initConfiguration()
    let first = t.paragraphRange(rng(0, 1))
    var painted = false
    for (r, a) in styleAttributes(t, cfg, caretLocation = -1,
                                  containerWidth = 600.0):
      if containsRange(first, r) and a.has(akOrderedMarker): painted = true
    check not painted
