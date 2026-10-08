## token.nim
## MarkdownEngine (Nim port)
##
## The flat token shape. **Tokens are a projection of the AST, not the source
## of truth** — `tokenizer.nim` walks each block and emits them. They survive
## because several consumers still read them: the image / LaTeX / table render
## passes, code-block handling, the input handlers, the context menu, and
## `detection.nim`'s caret-aware active-token indices.
##
## Token shapes are reproduced 1:1 from the original regex tokenizer, so those
## consumers keep working unchanged.

import ./ranges, ./utf16text

type
  MarkdownTokenKind* = enum
    tkItalic
    tkBoldItalic
    tkBold
    tkLink
    tkWikiLink
    tkHeading
    tkBlockquote
      ## One blockquote line; `markerRanges[0]` is the `>` run, nesting =
      ## count of `>`.
    tkCodeBlock
    tkInlineCode
    tkBlockLatex
    tkInlineLatex
    tkImageEmbed
    tkImageLink
    tkTable
    tkBackslashEscape
      ## A CommonMark backslash escape; marker is the `\`, content the escaped
      ## literal char.
    tkExtensionSpan
      ## A span contributed by a registered extension, carrying the
      ## extension's id in `extensionID` (e.g. `"highlight"`).
    tkExtensionBlock
      ## A fenced block contributed by a registered extension.

  MarkdownToken* = object
    kind*: MarkdownTokenKind
    range*: Range
    contentRange*: Range
    markerRanges*: seq[Range]
    extensionID*: string
      ## Only meaningful for `tkExtensionSpan` / `tkExtensionBlock`.

func initToken*(kind: MarkdownTokenKind, range, contentRange: Range,
                markerRanges: seq[Range] = @[],
                extensionID = ""): MarkdownToken {.inline.} =
  MarkdownToken(kind: kind, range: range, contentRange: contentRange,
                markerRanges: markerRanges, extensionID: extensionID)

func `==`*(a, b: MarkdownToken): bool =
  a.kind == b.kind and a.range == b.range and a.contentRange == b.contentRange and
  a.markerRanges == b.markerRanges and a.extensionID == b.extensionID

func shifted*(tok: MarkdownToken, delta: int): MarkdownToken =
  ## A copy with every range moved forward by `delta` UTF-16 units.
  var markers = newSeqOfCap[Range](tok.markerRanges.len)
  for m in tok.markerRanges: markers.add m.shifted(delta)
  MarkdownToken(kind: tok.kind, range: tok.range.shifted(delta),
                contentRange: tok.contentRange.shifted(delta),
                markerRanges: markers, extensionID: tok.extensionID)

func isSpanKind*(kind: MarkdownTokenKind): bool {.inline.} =
  kind in {tkItalic, tkBold, tkBoldItalic, tkLink, tkWikiLink, tkInlineCode,
           tkInlineLatex, tkImageEmbed, tkImageLink, tkBackslashEscape,
           tkExtensionSpan}

# ---------------------------------------------------------------------------
# Caret / selection questions the text view asks of a token
# ---------------------------------------------------------------------------

func standaloneParagraphRange*(tok: MarkdownToken, t: Utf16Text): (Range, bool) =
  ## The token's paragraph, when removing the token would leave that paragraph
  ## blank — i.e. the token is the only content on its line. `false` otherwise.
  let paragraph = t.paragraphRange(tok.range)
  var remaining = 0
  for i in paragraph.location ..< maxRange(paragraph):
    if i >= tok.range.location and i < maxRange(tok.range): continue
    if not isWhitespaceOrNewlineUnit(t.charAt(i)): inc remaining
  if remaining == 0: (paragraph, true) else: (notFoundRange(), false)

func containsSelectionOrStandaloneParagraph*(tok: MarkdownToken,
                                             selectionLocation: int,
                                             t: Utf16Text): bool =
  let start = tok.range.location
  let stop = maxRange(tok.range) - 1
  if selectionLocation >= start and selectionLocation <= stop:
    return true

  let (paragraph, isStandalone) = tok.standaloneParagraphRange(t)
  if not isStandalone: return false
  let paragraphEnd = maxRange(paragraph)
  # Reveal source when the caret is at document end right after the image,
  # unless that line ends in a newline.
  let endsWithNewline = paragraphEnd > paragraph.location and
                        isLineBreakUnit(t.charAt(paragraphEnd - 1))
  let isAtLastParagraphEnd = selectionLocation == t.len and
                             paragraphEnd == t.len and not endsWithNewline
  (selectionLocation >= paragraph.location and selectionLocation < paragraphEnd) or
    isAtLastParagraphEnd

func extractLanguage*(tok: MarkdownToken, t: Utf16Text): (string, bool) =
  ## The info string of a fenced code block (`” ```swift ”` → `"swift"`).
  if tok.kind != tkCodeBlock or tok.markerRanges.len == 0: return ("", false)
  let opening = tok.markerRanges[0]
  if opening.length <= 4: return ("", false)
  let langRange = rng(opening.location + 3, opening.length - 4)
  if maxRange(langRange) > t.len: return ("", false)
  let lang = trimWhitespaceAndNewlines(t.substring(langRange))
  if lang.len == 0: ("", false) else: (lang, true)
