## input.nim
## MarkdownEngine (Nim port)
##
## Typing-time helpers: list continuation, indent/outdent, auto-closing pairs,
## the `-` → `→` substitution, the ``` completion, blockquote continuation, and
## the auto-wrap rules that keep `$$…$$` / `![[…]]` on their own line and turn
## Return inside a table row into `<br>`.
##
## The Swift originals mutated the `NSTextView` in place and returned a Bool
## meaning "let the keystroke through". This port returns an `InputDecision`
## instead: whether to let the keystroke through, and the programmatic edit to
## apply in its place. Same semantics, no hidden mutation, and every rule is
## testable without a text view.

import std/strutils
import ./ranges, ./utf16text, ./configuration, ./token, ./lists

type
  InputDecision* = object
    allow*: bool
      ## True to let the proposed edit apply unchanged (the Swift `true`).
    hasEdit*: bool
      ## True when the handler replaces the keystroke with its own edit.
    replaceRange*: Range
    replacement*: string
    hasSelection*: bool
    newSelection*: Range
      ## Where the caret/selection lands after the edit.

func allowEdit*(): InputDecision {.inline.} =
  InputDecision(allow: true)

func consume*(): InputDecision {.inline.} =
  ## Swallow the keystroke without editing (e.g. Tab at the nesting cap).
  InputDecision(allow: false)

func replaceWith*(r: Range, replacement: string, caret: int): InputDecision {.inline.} =
  InputDecision(allow: false, hasEdit: true, replaceRange: r,
                replacement: replacement, hasSelection: true,
                newSelection: caretAt(caret))

func replaceKeeping*(r: Range, replacement: string): InputDecision {.inline.} =
  ## Replace and let the editor place the caret after the replacement.
  InputDecision(allow: false, hasEdit: true, replaceRange: r,
                replacement: replacement, hasSelection: false)

# ---------------------------------------------------------------------------
# List / pair / arrow handling
# ---------------------------------------------------------------------------

proc removeLinePrefixAndExit(t: Utf16Text, currentLine: Range,
                             prefixLength: int): InputDecision =
  ## Remove the current line's leading marker and put the caret at line start
  ## (exit an empty list/quote item on Return).
  let lineEnd = maxRange(currentLine)
  let hasNewline = currentLine.length > 0 and isLineBreakUnit(t.charAt(lineEnd - 1))
  let maxBodyLen = if hasNewline: currentLine.length - 1 else: currentLine.length
  let removalLength = min(prefixLength, maxBodyLen)
  replaceWith(rng(currentLine.location, removalLength), "", currentLine.location)

proc handleListInsertion*(t: Utf16Text, affectedRange: Range,
                          replacement: string,
                          config: MarkdownEditorConfiguration,
                          isInsideCode: bool): InputDecision =
  ## The Return / Tab / `[` / `(` / `{` / `>` / space path.
  ##
  ## `isInsideCode` is the caller's pre-parsed answer for
  ## `affectedRange.location`; the editor derives it from the keystroke's
  ## existing parse so this never walks the document.

  # Fast path: plain characters never trigger list/pair/arrow handling.
  if replacement.len == 1 and replacement[0] notin {'>', '[', '(', '{', '\t', ' ', '\n'}:
    return allowEdit()

  let listsEnabled = config.lists.helpersEnabled
  let autoClosePairs = config.lists.autoClosePairsEnabled

  proc insertAutoPair(openChar, closeChar: string): InputDecision =
    replaceWith(affectedRange, openChar & closeChar,
                affectedRange.location + utf16Len(openChar))

  if replacement == ">" and affectedRange.length == 0 and not isInsideCode:
    let insertionLocation = affectedRange.location
    if insertionLocation <= 0: return allowEdit()
    let previousCharRange = rng(insertionLocation - 1, 1)
    if t.substring(previousCharRange) == "-":
      return replaceWith(previousCharRange, "→", insertionLocation)

  # Auto-complete Obsidian-style wiki brackets and single square brackets.
  if replacement == "[":
    let insertionLocation = affectedRange.location
    if insertionLocation > 0:
      let prevChar = t.substring(rng(insertionLocation - 1, 1))
      if prevChar == "[":
        let hasAutoCloseBracket = insertionLocation < t.len and
          t.substring(rng(insertionLocation, 1)) == "]"
        if hasAutoCloseBracket:
          # Collapse an auto-paired "[]" into "[[]]" without changing the
          # surrounding text.
          return replaceWith(rng(insertionLocation - 1, 2), "[[]]",
                             insertionLocation + 1)
        # If the char to the right is not "]" (e.g. a newline), don't delete it.
        return replaceWith(affectedRange, "]]", insertionLocation + 1)
    if not autoClosePairs: return allowEdit()
    return insertAutoPair("[", "]")

  # Auto-complete parentheses / braces.
  if replacement == "(" or replacement == "{":
    if not autoClosePairs: return allowEdit()
    let closeChar = if replacement == "(": ")" else: "}"
    return insertAutoPair(replacement, closeChar)

  # TAB: indent list items (skipped in code blocks).
  if replacement == "\t" and not isInsideCode:
    if not listsEnabled: return allowEdit()
    let insertionLocation = affectedRange.location
    let safeLoc = min(affectedRange.location, t.len)
    let currentLine = t.lineRange(caretAt(safeLoc))
    let (listMatch, isList) = matchListLine(t, currentLine)
    if isList:
      if indentLevel(t, listMatch.leadingWhitespace) >= config.lists.maximumNestingLevel:
        return consume()
      return replaceWith(caretAt(currentLine.location), "\t", insertionLocation + 1)
    if matchDashNoSpace(t, currentLine):
      let ws = leadingWhitespaceRange(t, currentLine)
      if indentLevel(t, ws) >= config.lists.maximumNestingLevel:
        return consume()
      return replaceWith(caretAt(currentLine.location), "\t", insertionLocation + 1)
    return allowEdit()

  # ENTER: fence completion, then blockquote / list continuation.
  if replacement == "\n":
    let safeLoc = min(affectedRange.location, t.len)
    let currentLine = t.lineRange(caretAt(safeLoc))
    let lineText = trimWhitespaceAndNewlines(t.substring(currentLine))

    # Horizontal rules render via the styler; the source stays literal `---`
    # so files round-trip.

    # `^```\w*$` — an opening fence typed on its own line completes itself.
    if lineText.startsWith("```"):
      var isBareFence = true
      for ch in lineText[3 .. ^1]:
        if not (ch.isAlphaNumeric or ch == '_'):
          isBareFence = false
          break
      if isBareFence:
        # Non-overlapping ``` count before the line.
        var openingCount = 0
        var searchLocation = 0
        while searchLocation < currentLine.location:
          let found = rangeOf(t, "```",
                              rng(searchLocation, currentLine.location - searchLocation))
          if found.location == NotFound: break
          inc openingCount
          searchLocation = maxRange(found)
        let afterLineStart = maxRange(currentLine)
        var hasClosingAfter = false
        if afterLineStart < t.len:
          hasClosingAfter = rangeOf(t, "```",
                                    rng(afterLineStart, t.len - afterLineStart)).location != NotFound
        let lineEnd = currentLine.location + max(0, currentLine.length - 1)
        let cursorAtLineEnd = affectedRange.location >= lineEnd

        if (openingCount mod 2) == 0 and cursorAtLineEnd and not hasClosingAfter:
          return replaceWith(affectedRange, "\n\n```", affectedRange.location + 1)

    # Skip list / blockquote continuation in code blocks.
    if not listsEnabled or isInsideCode: return allowEdit()

    # Blockquote continuation: `> foo` → `\n> `, `>>>` stays `>>>`, an empty
    # marker exits.
    let (quoteMatch, isQuote) = matchBlockquoteLine(t, currentLine)
    if isQuote:
      let ws = t.substring(quoteMatch.leadingWhitespace)
      let markers = t.substring(quoteMatch.markers)
      let prefixLength = quoteMatch.range.length
      let contentStart = currentLine.location + prefixLength
      let contentRange = rng(contentStart, max(0, maxRange(currentLine) - contentStart))
      if trimWhitespaceAndNewlines(t.substring(contentRange)).len == 0:
        return removeLinePrefixAndExit(t, currentLine, prefixLength)
      return replaceKeeping(affectedRange, "\n" & ws & markers & " ")

    let (listMatch, isList) = matchListLine(t, currentLine)
    if isList:
      let contentStart = maxRange(listMatch.prefix)
      let contentRange = rng(contentStart, max(0, maxRange(currentLine) - contentStart))
      if trimWhitespaceAndNewlines(t.substring(contentRange)).len == 0:
        return removeLinePrefixAndExit(t, currentLine, listMatch.prefix.length)
      let leadingWhitespace = t.substring(listMatch.leadingWhitespace)
      let hasCheckbox = listMatch.hasCheckbox
      var newItem: string
      if listMatch.ordered and listMatch.hasNumber:
        newItem = "\n" & leadingWhitespace & $(listMatch.number + 1) & ". " &
                  (if hasCheckbox: "[ ] " else: "")
      else:
        # Continue with the user's marker char (legacy `•` → `-`), keeping the
        # leading whitespace.
        let markerText = t.substring(listMatch.marker)
        let bulletChar = if markerText == "•": "-" else: markerText
        newItem = "\n" & leadingWhitespace & bulletChar & " " &
                  (if hasCheckbox: "[ ] " else: "")
      return replaceKeeping(affectedRange, newItem)

  allowEdit()

# ---------------------------------------------------------------------------
# Auto-wrap for block constructs
# ---------------------------------------------------------------------------

proc handleBlockAutoWrap(t: Utf16Text, affectedRange: Range, replacement: string,
                         tokens: seq[MarkdownToken]): InputDecision =
  ## Shared auto-wrap logic: ensures a block-level token stays on its own line.
  if replacement.len == 0 or replacement == "\n": return allowEdit()
  let replacementLength = utf16Len(replacement)

  for tok in tokens:
    let tokenEnd = maxRange(tok.range)

    # Typing right after the closing marker.
    if affectedRange.location == tokenEnd:
      if tokenEnd < t.len and t.charAt(tokenEnd) == chLF:
        return replaceWith(caretAt(tokenEnd + 1), replacement,
                           tokenEnd + 1 + replacementLength)
      return replaceWith(affectedRange, "\n" & replacement,
                         affectedRange.location + 1 + replacementLength)

    # Typing right before the opening marker.
    if affectedRange.location == tok.range.location:
      if tok.range.location > 0 and t.charAt(tok.range.location - 1) == chLF:
        return replaceWith(caretAt(tok.range.location - 1), replacement,
                           tok.range.location - 1 + replacementLength)
      return replaceWith(affectedRange, replacement & "\n",
                         affectedRange.location + replacementLength)

  allowEdit()

proc handleBlockLatexAutoWrap*(t: Utf16Text, affectedRange: Range,
                               replacement: string,
                               blockLatexTokens: seq[MarkdownToken]): InputDecision =
  ## Keeps block LaTeX (`$$…$$`) on its own line by inserting newlines.
  handleBlockAutoWrap(t, affectedRange, replacement, blockLatexTokens)

proc handleImageEmbedAutoWrap*(t: Utf16Text, affectedRange: Range,
                               replacement: string,
                               imageEmbedTokens: seq[MarkdownToken]): InputDecision =
  ## Ensures image embeds (`![[…]]`) stay on their own line.
  handleBlockAutoWrap(t, affectedRange, replacement, imageEmbedTokens)

proc handleTableCellNewline*(t: Utf16Text, affectedRange: Range,
                             replacement: string,
                             tableTokens: seq[MarkdownToken]): InputDecision =
  ## Return inside a table row inserts `<br>` instead of splitting the row.
  ##
  ## A GFM row is ONE source line, so a bare newline tears the table in half.
  ## `<br>` is the format's only in-cell line break, and the renderer draws it
  ## as one.
  ##
  ## Deliberately NOT handled at the token's outer edges — Return at the very
  ## start or end of the table stays a normal newline, which is the only way
  ## out of a table that reaches the end of the document.
  if replacement != "\n": return allowEdit()
  let start = affectedRange.location
  let stop = maxRange(affectedRange)
  var inside = false
  for tok in tableTokens:
    if start > tok.range.location and stop < maxRange(tok.range):
      inside = true
      break
  if not inside: return allowEdit()
  const insertion = "<br>"
  replaceWith(affectedRange, insertion, start + utf16Len(insertion))

# ---------------------------------------------------------------------------
# Paste helpers
# ---------------------------------------------------------------------------

proc blockquoteContinuedPaste*(pasted: string, location: int,
                               t: Utf16Text): string =
  ## Mirror Enter-key quote continuation for multi-line pastes: when `location`
  ## sits on a blockquote line, prefix every line after the first with that
  ## line's `>` marker run so the whole paste stays inside the quote. Returns
  ## `pasted` unchanged when it has no newline or the caret isn't in a quote.
  if not pasted.contains('\n'): return pasted
  if location < 0 or location > t.len: return pasted
  let line = t.lineRange(caretAt(location))
  let (m, ok) = matchBlockquoteLine(t, line)
  if not ok: return pasted
  let prefix = t.substring(m.leadingWhitespace) & t.substring(m.markers) & " "
  pasted.replace("\n", "\n" & prefix)

# ---------------------------------------------------------------------------
# Task checkbox toggle
# ---------------------------------------------------------------------------

proc toggleTaskCheckbox*(t: Utf16Text, boxRange: Range): InputDecision =
  ## Flip `[ ]` ⇄ `[x]` in place. The editor calls this from the checkbox hit
  ## test; keeping it here means the toggle, the styler and the parser all agree
  ## on the box's shape.
  if boxRange.length != 3: return consume()
  let mid = t.charAt(boxRange.location + 1)
  let replacement = if mid == chSpace: "[x]" else: "[ ]"
  InputDecision(allow: false, hasEdit: true, replaceRange: boxRange,
                replacement: replacement, hasSelection: false)
