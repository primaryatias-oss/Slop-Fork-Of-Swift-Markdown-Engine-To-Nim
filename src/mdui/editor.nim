## editor.nim
## MarkdownEngine (Nim port) — UI layer
##
## The editor view: what `NativeTextView` plus its coordinator did.
##
## It owns the text storage, the layout, the selection, the undo stack, the
## scroll offset and the restyle pipeline, and it routes input through the
## engine's typing-time handlers before applying it.
##
## The restyle pipeline keeps the original's shape and its reasons:
##
## * one parse per keystroke, through `DocumentParseState`, which splices the
##   buffer, the block list and the token list under a single edit descriptor
## * a SCOPED restyle: the paragraphs the edit touched, plus the paragraphs of
##   every token whose active (caret-revealed) state flipped — so moving the
##   caret into a `**bold**` span restyles two paragraphs, not the document
## * the storage/display split for wiki links, run both ways on every rebuild,
##   so `[[Name|<id>]]` is what the binding sees and `[[Name]]` is what the
##   reader does

import std/[algorithm, math, sets, strutils, tables]
import ../markdownengine
import ./fontmanager, ./textstorage, ./layout

type
  UndoEntry = object
    ## One reversible edit. `coalesceGroup` lets a run of typed characters
    ## undo as one step, which is what a text view does.
    range: Range
    replaced: string
    inserted: string
    selectionBefore: Range
    selectionAfter: Range
    coalesceGroup: int

  EditorHooks* = object
    ## Callbacks the host app supplies. Each is optional.
    textDidChange*: proc (storageText: string) {.closure.}
      ## The document in STORAGE form, i.e. what should be persisted.
    selectionDidChange*: proc (flags: SelectionFlags) {.closure.}
    linkActivated*: proc (target: string, isWikiLink: bool) {.closure.}
    findResults*: proc (count, current: int) {.closure.}
    directiveCompletion*: proc (ctx: DirectiveCompletionContext,
                                hasContext: bool) {.closure.}

  Editor* = ref object
    storage*: TextStorage
    layout*: TextLayout
    fonts*: FontManager
    widths*: WidthCache
    config*: MarkdownEditorConfiguration
    appearance*: Appearance
    documentID*: string

    parseState: DocumentParseState
    tokens*: seq[MarkdownToken]
    classified*: ClassifiedStyleTokens
    activeTokens*: HashSet[int]
    blocks*: seq[Block]

    selection*: Range
    desiredX*: float
    hasDesiredX: bool

    scrollY*: float
    viewport*: tuple[x, y, w, h: float]
      ## The text column's frame in view coordinates.
    contentInsets*: tuple[x, y: float]

    hasFocus*: bool
    caretOn*: bool
    lastCaretBlink: float
    isEditable*: bool

    undoStack: seq[UndoEntry]
    redoStack: seq[UndoEntry]
    coalesceGroup: int
    lastEditWasTyping: bool

    findQuery*: string
    findMatches*: seq[Range]
    currentMatch*: int

    wikiMetadata: LinkMetadataTable
    storageText: string
      ## The last storage-form text published to the host.

    hooks*: EditorHooks
    tableOffsets*: Table[int, float]
    completionContext*: DirectiveCompletionContext
    hasCompletionContext*: bool
    completionIndex*: int

    baseFont*: FontDesc
    baseParagraph*: ParagraphStyle
    needsRelayout: bool
    needsRedraw*: bool

const caretBlinkInterval = 0.56

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc makeBaseFontAndStyle*(fonts: FontManager,
                           config: MarkdownEditorConfiguration): (FontDesc, ParagraphStyle) =
  ## `TextStylingService.makeBaseFontAndStyle` — the typing attributes every
  ## paragraph is reset to before the styled ranges paint over them.
  let baseFont = initFont(config.fontName, config.fontSize)
  let defaultLineHeight = lineHeight(fonts.textMetrics(), baseFont)
  let paragraph = newParagraphStyle()
  paragraph.minimumLineHeight = ceil(defaultLineHeight) +
                                config.paragraph.lineHeightExtraSpacing
  paragraph.lineSpacing = 0
  paragraph.paragraphSpacing = ceil(defaultLineHeight * config.paragraph.spacingFactor)
  paragraph.paragraphSpacingBefore = 0
  paragraph.lineBreakMode = lbWordWrapping
  # 24 explicit tab stops at `indentPerLevel` intervals, then natural wrap.
  paragraph.tabStops = evenTabStops(config.lists.indentPerLevel)
  paragraph.defaultTabInterval = 0
  (baseFont, paragraph)

proc newEditor*(fonts: FontManager, config: MarkdownEditorConfiguration,
                documentID = "default"): Editor =
  let storage = newTextStorage("")
  let (baseFont, baseParagraph) = makeBaseFontAndStyle(fonts, config)
  result = Editor(
    storage: storage, fonts: fonts, widths: newWidthCache(), config: config,
    appearance: apLight, documentID: documentID,
    parseState: newDocumentParseState(), tokens: @[],
    activeTokens: initHashSet[int](), blocks: @[],
    selection: caretAt(0), desiredX: 0, hasDesiredX: false, scrollY: 0,
    viewport: (0.0, 0.0, 600.0, 400.0), contentInsets: (20.0, 10.0),
    hasFocus: true, caretOn: true, lastCaretBlink: 0, isEditable: true,
    undoStack: @[], redoStack: @[], coalesceGroup: 0, lastEditWasTyping: false,
    findQuery: "", findMatches: @[], currentMatch: -1,
    wikiMetadata: initTable[RangeKey, LinkMetadata](), storageText: "",
    tableOffsets: initTable[int, float](), hasCompletionContext: false,
    completionIndex: 0, baseFont: baseFont, baseParagraph: baseParagraph,
    needsRelayout: true, needsRedraw: true)
  result.layout = newTextLayout(storage, fonts, baseFont, baseParagraph)

proc baseAttributes(editor: Editor): Attrs =
  ## `makeBaseTypingAttributes`.
  @[(akFont, av(editor.baseFont)),
    (akForegroundColor, av(editor.config.theme.bodyText)),
    (akParagraphStyle, av(editor.baseParagraph))]

proc textColumnWidth*(editor: Editor): float =
  ## The width styling and layout measure against: the reading column when one
  ## is configured, otherwise the viewport minus the text insets.
  let full = max(1.0, editor.viewport.w - editor.contentInsets.x * 2.0)
  if editor.config.hasReadingWidth and editor.config.readingWidth > 0:
    min(full, editor.config.readingWidth)
  else:
    full

proc textColumnX*(editor: Editor): float =
  ## Left edge of the text column in view coordinates — centred when a reading
  ## width is set, which is what `readingWidth` means.
  let width = editor.textColumnWidth()
  let full = max(1.0, editor.viewport.w - editor.contentInsets.x * 2.0)
  editor.viewport.x + editor.contentInsets.x + max(0.0, (full - width) * 0.5)

# ---------------------------------------------------------------------------
# Wiki-link storage / display transform
# ---------------------------------------------------------------------------

proc wikiLinkIDProvider(editor: Editor): WikiLinkIDProvider =
  ## Resolve a display-range wiki link to its stored opaque id, which is what
  ## the styler tags the content with.
  let metadata = editor.wikiMetadata
  proc provider(r: Range): (string, bool) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let key = rangeKey(r)
      if metadata.hasKey(key) and metadata[key].hasID:
        return (metadata[key].id, true)
      # The metadata is keyed by the link's FULL display range; the styler asks
      # with that same range, but a caret-revealed link may have shifted, so
      # fall back to a containment scan.
      for candidate, meta in metadata:
        if meta.hasID and candidate.location <= r.location and
           candidate.location + candidate.length >= maxRange(r):
          return (meta.id, true)
      ("", false)
  provider

proc publishStorageText(editor: Editor) =
  ## Convert the displayed text back to storage form and hand it to the host.
  ## Display and storage differ only inside wiki links, so this is the one
  ## place the two forms meet.
  let (storage, metadata) = makeStorageState(
    editor.storage.text, editor.wikiMetadata,
    proc (location: int): (string, bool) {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        let attrs = editor.storage.attributesAt(location)
        let id = attrs.stringOf(akWikiLinkID, "")
        if id.len > 0: (id, true) else: ("", false))
  editor.wikiMetadata = metadata
  editor.storageText = storage
  if editor.hooks.textDidChange != nil:
    editor.hooks.textDidChange(storage)

proc storageFormText*(editor: Editor): string =
  ## The document as it should be persisted.
  editor.storageText

# ---------------------------------------------------------------------------
# Restyle
# ---------------------------------------------------------------------------

proc activeTokenIndicesNow(editor: Editor): HashSet[int] =
  computeActiveTokenIndices(editor.selection, editor.tokens, editor.storage.text,
                            suppressed = not editor.isEditable)

proc paragraphsForRange(editor: Editor, r: Range): seq[Range] =
  ## Every paragraph `r` touches.
  let length = editor.storage.len
  if length == 0: return @[rng(0, 0)]
  var start = max(0, min(r.location, length))
  let stop = max(start, min(maxRange(r), length))
  if start >= length: start = max(0, length - 1)
  if stop <= start:
    return @[editor.storage.text.paragraphRange(caretAt(start))]
  var cursor = start
  while cursor < stop:
    let paragraph = editor.storage.text.paragraphRange(caretAt(cursor))
    result.add paragraph
    let next = maxRange(paragraph)
    if next <= cursor: break
    cursor = next

proc tokenRestyleParagraphs(editor: Editor, current,
                            previous: HashSet[int]): seq[Range] =
  ## Paragraphs of every token whose active state flipped — the scope that
  ## makes a caret move restyle two paragraphs instead of the document.
  var indices = current
  for idx in previous: indices.incl idx
  for idx in indices:
    if idx < 0 or idx >= editor.tokens.len: continue
    let tok = editor.tokens[idx]
    result.add editor.storage.text.paragraphRange(tok.range)
    if tok.kind == tkCodeBlock or tok.kind == tkBlockLatex:
      for marker in tok.markerRanges:
        result.add editor.storage.text.paragraphRange(marker)

proc restyle*(editor: Editor, paragraphCandidates: seq[Range],
              scoped: bool) =
  ## Apply the styler's output over the candidate paragraphs.
  let paragraphs = if scoped: editor.storage.paragraphsFor(paragraphCandidates)
                   else: editor.storage.fullParagraphs()
  if paragraphs.len == 0:
    editor.needsRedraw = true
    return
  let styled = styleAttributes(
    editor.storage.text, editor.config, editor.fonts.textMetrics(),
    editor.widths, editor.appearance,
    caretLocation = editor.selection.location,
    selection = editor.selection,
    hasSelection = editor.selection.length > 0,
    activeTokenIndices = editor.activeTokens,
    wikiLinkID = editor.wikiLinkIDProvider(),
    precomputedTokens = editor.tokens, hasPrecomputedTokens = true,
    precomputedBlocks = editor.blocks, hasPrecomputedBlocks = true,
    containerWidth = editor.textColumnWidth(),
    scopedRanges = paragraphs, hasScope = scoped)
  editor.storage.applyStyledRanges(styled, paragraphs, editor.baseAttributes())
  for paragraph in paragraphs:
    editor.layout.invalidateRange(paragraph)
  editor.needsRelayout = true
  editor.needsRedraw = true

proc reparse(editor: Editor, edit: ParseEditDescriptor, hasEdit: bool) =
  let registry = editor.config.extensionRegistry()
  editor.tokens = editor.parseState.tokens(editor.storage.text, edit, hasEdit,
                                           registry)
  editor.blocks = editor.parseState.currentBlocks()
  editor.classified = classify(editor.tokens)
  editor.activeTokens = editor.activeTokenIndicesNow()

proc rebuildAndStyle*(editor: Editor) =
  ## The full rebuild: reparse the document and restyle every paragraph. This
  ## is the document-open path; a keystroke takes the scoped path instead.
  editor.parseState.invalidate()
  resetBlockCache()
  resetTokenCache()
  editor.reparse(ParseEditDescriptor(), false)
  editor.restyle(@[], false)

proc setDocument*(editor: Editor, storageMarkdown: string) =
  ## Load a document in STORAGE form. The display form is what the editor shows
  ## and edits; the metadata map remembers how to get back.
  let (display, metadata) = makeDisplayState(storageMarkdown)
  editor.wikiMetadata = metadata
  editor.storageText = storageMarkdown
  editor.storage.setText(display)
  editor.selection = caretAt(0)
  editor.undoStack = @[]
  editor.redoStack = @[]
  editor.findMatches = @[]
  editor.currentMatch = -1
  editor.scrollY = 0
  editor.layout.invalidate()
  editor.rebuildAndStyle()

proc displayText*(editor: Editor): string {.inline.} = $editor.storage.text

# ---------------------------------------------------------------------------
# Layout and scrolling
# ---------------------------------------------------------------------------

proc bottomOverscroll*(editor: Editor): float =
  ## Empty space below the last line, so typing at the bottom of a long
  ## document stays comfortable instead of pinning to the viewport edge.
  ##
  ## Ramped in with the content height, exactly as `OverscrollPolicy`
  ## describes: a short document gets none, and the slack grows to
  ## `percent` of the viewport over the activation range.
  if editor.config.heightBehavior == hbFitsContent: return 0.0
  let policy = editor.config.overscroll
  let viewportHeight = max(1.0, editor.viewport.h)
  let contentHeight = editor.layout.contentHeight
  let startHeight = viewportHeight * policy.activationStartFraction
  if contentHeight <= startHeight: return 0.0
  let rangeHeight = max(1.0, viewportHeight * policy.activationRangeFraction)
  let ramp = clamp((contentHeight - startHeight) / rangeHeight, 0.0, 1.0)
  let target = viewportHeight * policy.percent * ramp
  clamp(target, policy.minPoints * ramp, policy.maxPoints)

proc totalContentHeight*(editor: Editor): float {.inline.} =
  editor.layout.contentHeight + editor.bottomOverscroll()

proc maxScroll*(editor: Editor): float {.inline.} =
  max(0.0, editor.totalContentHeight() - editor.viewport.h)

proc ensureLayout*(editor: Editor) =
  if not editor.needsRelayout: return
  editor.layout.layout(editor.textColumnWidth(),
                       editor.textColumnX() - editor.viewport.x)
  editor.needsRelayout = false
  editor.scrollY = clamp(editor.scrollY, 0.0, editor.maxScroll())

proc setViewport*(editor: Editor, x, y, w, h: float) =
  let widthChanged = abs(w - editor.viewport.w) > 0.01
  editor.viewport = (x, y, w, h)
  if widthChanged:
    # Width changes cannot alter non-table markdown styling, but they DO change
    # table geometry — so re-run only the table pass, which keeps an all-table
    # resize linear in the number of tables.
    editor.layout.invalidate()
    editor.needsRelayout = true
    let tableStyled = styleTableAttributes(
      editor.storage.text, editor.config, editor.fonts.textMetrics(),
      editor.widths, editor.appearance, editor.activeTokens,
      editor.tokens, true, editor.textColumnWidth(), @[], false)
    if tableStyled.len > 0:
      var paragraphs: seq[Range] = @[]
      for (r, _) in tableStyled:
        paragraphs.add editor.storage.text.paragraphRange(r)
      editor.storage.applyStyledRanges(tableStyled,
                                       normalizeParagraphCandidates(paragraphs),
                                       editor.baseAttributes())
  editor.needsRelayout = true
  editor.needsRedraw = true

proc scrollBy*(editor: Editor, delta: float) =
  editor.ensureLayout()
  let clamped = clamp(editor.scrollY + delta, 0.0, editor.maxScroll())
  if abs(clamped - editor.scrollY) > 0.001:
    editor.scrollY = clamped
    editor.needsRedraw = true

proc scrollTo*(editor: Editor, y: float) =
  editor.ensureLayout()
  let clamped = clamp(y, 0.0, editor.maxScroll())
  if abs(clamped - editor.scrollY) > 0.001:
    editor.scrollY = clamped
    editor.needsRedraw = true

proc scrollRangeToVisible*(editor: Editor, r: Range) =
  editor.ensureLayout()
  let rect = editor.layout.boundingRectForRange(r)
  let margin = 24.0
  if rect.y < editor.scrollY + margin:
    editor.scrollTo(rect.y - margin)
  elif rect.y + rect.h > editor.scrollY + editor.viewport.h - margin:
    editor.scrollTo(rect.y + rect.h - editor.viewport.h + margin)

proc scrollCaretToVisible*(editor: Editor) =
  editor.scrollRangeToVisible(caretAt(editor.selection.location))

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

proc selectionFlags*(editor: Editor): SelectionFlags =
  ## What a host toolbar reflects: whether the caret sits in bold, italic or
  ## highlighted text.
  let probe = if editor.selection.length > 0: editor.selection.location
              else: max(0, editor.selection.location - 1)
  if probe >= editor.storage.len: return SelectionFlags()
  let attrs = editor.storage.attributesAt(probe)
  let f = attrs.fontOf(editor.baseFont)
  SelectionFlags(isBold: ftBold in f.traits, isItalic: ftItalic in f.traits,
                 isHighlight: attrs.has(akMarkdownBlockBackground))

proc updateDirectiveCompletion(editor: Editor) =
  ## Publish what the caret is completing. The engine owns the candidates
  ## because it owns the registry, so a newly registered directive appears in
  ## the picker with no host change.
  let registry = editor.config.directiveRegistry()
  if registry.isEmpty or editor.selection.length > 0:
    if editor.hasCompletionContext:
      editor.hasCompletionContext = false
      if editor.hooks.directiveCompletion != nil:
        editor.hooks.directiveCompletion(DirectiveCompletionContext(), false)
    return
  let (ctx, has) = completionContext(editor.storage.text,
                                     editor.selection.location, registry,
                                     editor.config.directives,
                                     editor.config.directiveSettings)
  editor.completionContext = ctx
  if has != editor.hasCompletionContext or has:
    editor.completionIndex = 0
  editor.hasCompletionContext = has
  if editor.hooks.directiveCompletion != nil:
    editor.hooks.directiveCompletion(ctx, has)

proc setSelection*(editor: Editor, r: Range, resetDesiredX = true) =
  ## Move the selection and restyle whatever the move revealed or hid.
  let length = editor.storage.len
  var clampedRange = clamped(r, length)
  if clampedRange.location > length: clampedRange.location = length
  if editor.selection == clampedRange: return

  let previousActive = editor.activeTokens
  let previousSelection = editor.selection
  editor.selection = clampedRange
  editor.activeTokens = editor.activeTokenIndicesNow()
  if resetDesiredX: editor.hasDesiredX = false

  var candidates = editor.paragraphsForRange(previousSelection)
  candidates.add editor.paragraphsForRange(clampedRange)
  candidates.add editor.tokenRestyleParagraphs(editor.activeTokens, previousActive)
  editor.restyle(candidates, true)
  editor.caretOn = true
  editor.updateDirectiveCompletion()
  if editor.hooks.selectionDidChange != nil:
    editor.hooks.selectionDidChange(editor.selectionFlags())

# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

proc applyEdit(editor: Editor, r: Range, replacement: string,
               newSelection: Range, hasNewSelection: bool,
               isTyping: bool, recordUndo = true) =
  ## The single path every text change goes through: splice the storage,
  ## reparse under one edit descriptor, restyle the touched paragraphs, and
  ## publish the storage form.
  if not editor.isEditable: return
  let target = clamped(r, editor.storage.len)
  let replaced = editor.storage.substring(target)
  if replaced == replacement and target.length == 0 and replacement.len == 0:
    return

  if recordUndo:
    if not (isTyping and editor.lastEditWasTyping): inc editor.coalesceGroup
    editor.undoStack.add UndoEntry(
      range: target, replaced: replaced, inserted: replacement,
      selectionBefore: editor.selection,
      selectionAfter: if hasNewSelection: newSelection
                      else: caretAt(target.location + utf16Len(replacement)),
      coalesceGroup: editor.coalesceGroup)
    editor.redoStack = @[]
    editor.lastEditWasTyping = isTyping

  let replacementUnits = toUtf16(replacement)
  editor.storage.replaceCharacters(target, replacementUnits)
  let delta = replacementUnits.len - target.length
  let edited = rng(target.location, replacementUnits.len)

  editor.selection =
    if hasNewSelection: clamped(newSelection, editor.storage.len)
    else: caretAt(min(target.location + replacementUnits.len, editor.storage.len))

  editor.reparse(ParseEditDescriptor(editedRange: edited, delta: delta), true)

  # The layout cache is keyed by paragraph start, so everything at or after the
  # edit has moved: drop the tail rather than trusting stale keys.
  editor.layout.invalidateRange(rng(edited.location,
                                    max(1, editor.storage.len - edited.location)))

  var candidates = editor.paragraphsForRange(edited)
  candidates.add editor.tokenRestyleParagraphs(editor.activeTokens, initHashSet[int]())
  editor.restyle(candidates, true)
  editor.publishStorageText()
  editor.updateDirectiveCompletion()
  editor.caretOn = true
  if editor.hooks.selectionDidChange != nil:
    editor.hooks.selectionDidChange(editor.selectionFlags())

proc applyDecision(editor: Editor, decision: InputDecision,
                   fallbackRange: Range, fallbackText: string,
                   isTyping: bool): bool =
  ## Run an engine input decision. `true` means the keystroke was handled.
  if decision.allow:
    editor.applyEdit(fallbackRange, fallbackText, caretAt(0), false, isTyping)
    return true
  if not decision.hasEdit: return true
  editor.applyEdit(decision.replaceRange, decision.replacement,
                   decision.newSelection, decision.hasSelection, isTyping)
  true

proc codeTokens(editor: Editor): seq[MarkdownToken] {.inline.} =
  editor.classified.code

proc insertText*(editor: Editor, text: string) =
  ## Insert typed text, giving the engine's handlers first refusal.
  if not editor.isEditable or text.len == 0: return
  let target = editor.selection
  let insideCode = isInsideCodeBlock(target.location, editor.codeTokens())

  # List / pair / arrow handling.
  let listDecision = handleListInsertion(editor.storage.text, target, text,
                                         editor.config, insideCode)
  if not listDecision.allow:
    discard editor.applyDecision(listDecision, target, text, true)
    return

  # Return inside a table row becomes `<br>`, since a GFM row is one line.
  if text == "\n":
    var tableTokens: seq[MarkdownToken] = @[]
    for (_, tok) in editor.classified.table: tableTokens.add tok
    let tableDecision = handleTableCellNewline(editor.storage.text, target, text,
                                               tableTokens)
    if not tableDecision.allow:
      discard editor.applyDecision(tableDecision, target, text, true)
      return

  # Keep block LaTeX and image embeds on their own line.
  var blockLatexTokens: seq[MarkdownToken] = @[]
  for (_, tok) in editor.classified.blockLatex: blockLatexTokens.add tok
  let latexDecision = handleBlockLatexAutoWrap(editor.storage.text, target, text,
                                               blockLatexTokens)
  if not latexDecision.allow:
    discard editor.applyDecision(latexDecision, target, text, true)
    return
  var embedTokens: seq[MarkdownToken] = @[]
  for (_, tok) in editor.classified.imageEmbed: embedTokens.add tok
  let embedDecision = handleImageEmbedAutoWrap(editor.storage.text, target, text,
                                               embedTokens)
  if not embedDecision.allow:
    discard editor.applyDecision(embedDecision, target, text, true)
    return

  editor.applyEdit(target, text, caretAt(0), false, true)

proc deleteBackward*(editor: Editor) =
  if not editor.isEditable: return
  if editor.selection.length > 0:
    editor.applyEdit(editor.selection, "", caretAt(0), false, false)
    return
  let location = editor.selection.location
  if location <= 0: return
  let start = editor.layout.previousLocation(location)
  editor.applyEdit(rng(start, location - start), "", caretAt(0), false, true)

proc deleteForward*(editor: Editor) =
  if not editor.isEditable: return
  if editor.selection.length > 0:
    editor.applyEdit(editor.selection, "", caretAt(0), false, false)
    return
  let location = editor.selection.location
  if location >= editor.storage.len: return
  let stop = editor.layout.nextLocation(location)
  editor.applyEdit(rng(location, stop - location), "", caretAt(0), false, true)

proc deleteWordBackward*(editor: Editor) =
  if editor.selection.length > 0:
    editor.deleteBackward()
    return
  let location = editor.selection.location
  let start = editor.layout.wordBoundaryBackward(location)
  if start >= location: return
  editor.applyEdit(rng(start, location - start), "", caretAt(0), false, false)

# ---------------------------------------------------------------------------
# Undo / redo
# ---------------------------------------------------------------------------

proc undo*(editor: Editor) =
  if editor.undoStack.len == 0: return
  let group = editor.undoStack[^1].coalesceGroup
  while editor.undoStack.len > 0 and editor.undoStack[^1].coalesceGroup == group:
    let entry = editor.undoStack.pop()
    editor.redoStack.add entry
    let inserted = rng(entry.range.location, utf16Len(entry.inserted))
    editor.applyEdit(inserted, entry.replaced, entry.selectionBefore, true,
                     false, recordUndo = false)
  editor.lastEditWasTyping = false
  editor.scrollCaretToVisible()

proc redo*(editor: Editor) =
  if editor.redoStack.len == 0: return
  let group = editor.redoStack[^1].coalesceGroup
  var replayed: seq[UndoEntry] = @[]
  while editor.redoStack.len > 0 and editor.redoStack[^1].coalesceGroup == group:
    replayed.add editor.redoStack.pop()
  # The undo pass popped them newest-first, so replay in the original order.
  replayed.reverse()
  for entry in replayed:
    let replacedRange = rng(entry.range.location, utf16Len(entry.replaced))
    editor.applyEdit(replacedRange, entry.inserted, entry.selectionAfter, true,
                     false, recordUndo = false)
    editor.undoStack.add entry
  editor.lastEditWasTyping = false
  editor.scrollCaretToVisible()

# ---------------------------------------------------------------------------
# Caret movement
# ---------------------------------------------------------------------------

type
  MoveKind* = enum
    mvLeft, mvRight, mvUp, mvDown, mvLineStart, mvLineEnd,
    mvWordLeft, mvWordRight, mvDocStart, mvDocEnd, mvPageUp, mvPageDown

proc moveCaret*(editor: Editor, kind: MoveKind, extend = false) =
  editor.ensureLayout()
  let anchor = if extend and editor.selection.length > 0:
                 # Extend from the far end of the current selection.
                 if editor.selection.location == editor.selection.location:
                   editor.selection.location
                 else: maxRange(editor.selection)
               else: editor.selection.location
  var caret = if editor.selection.length > 0 and not extend:
                case kind
                of mvLeft, mvUp, mvLineStart, mvWordLeft, mvDocStart, mvPageUp:
                  editor.selection.location
                else: maxRange(editor.selection)
              else: editor.selection.location
  if extend and editor.selection.length > 0:
    caret = maxRange(editor.selection)

  var keepDesiredX = false
  case kind
  of mvLeft: caret = editor.layout.previousLocation(caret)
  of mvRight: caret = editor.layout.nextLocation(caret)
  of mvUp, mvDown:
    if not editor.hasDesiredX:
      editor.desiredX = editor.layout.caretRect(caret).x
      editor.hasDesiredX = true
    caret = editor.layout.locationMovingVertically(
      caret, (if kind == mvUp: -1 else: 1), editor.desiredX)
    keepDesiredX = true
  of mvLineStart: caret = editor.layout.lineStartLocation(caret)
  of mvLineEnd: caret = editor.layout.lineEndLocation(caret)
  of mvWordLeft: caret = editor.layout.wordBoundaryBackward(caret)
  of mvWordRight: caret = editor.layout.wordBoundaryForward(caret)
  of mvDocStart: caret = 0
  of mvDocEnd: caret = editor.storage.len
  of mvPageUp, mvPageDown:
    let page = max(1.0, editor.viewport.h - 24.0)
    if not editor.hasDesiredX:
      editor.desiredX = editor.layout.caretRect(caret).x
      editor.hasDesiredX = true
    let current = editor.layout.caretRect(caret)
    let targetY = current.y + (if kind == mvPageUp: -page else: page)
    caret = editor.layout.locationAtPoint(editor.desiredX, targetY)
    editor.scrollBy(if kind == mvPageUp: -page else: page)
    keepDesiredX = true

  if extend:
    let lo = min(anchor, caret)
    let hi = max(anchor, caret)
    editor.setSelection(rng(lo, hi - lo), resetDesiredX = not keepDesiredX)
  else:
    editor.setSelection(caretAt(caret), resetDesiredX = not keepDesiredX)
  editor.scrollCaretToVisible()

proc selectAll*(editor: Editor) =
  editor.setSelection(rng(0, editor.storage.len))

# ---------------------------------------------------------------------------
# Hit testing
# ---------------------------------------------------------------------------

proc documentPoint*(editor: Editor, viewX, viewY: float): (float, float) {.inline.} =
  (viewX - editor.viewport.x, viewY - editor.viewport.y + editor.scrollY -
   editor.contentInsets.y)

proc locationAt*(editor: Editor, viewX, viewY: float): int =
  editor.ensureLayout()
  let (x, y) = editor.documentPoint(viewX, viewY)
  editor.layout.locationAtPoint(x, y)

proc checkboxAt*(editor: Editor, viewX, viewY: float): (Range, bool) =
  ## Hit test the DRAWN checkbox square, which sits left of the content edge
  ## and is not where the `[ ]` characters are — their advance is collapsed.
  ## Sharing the geometry with the renderer is what keeps the two from
  ## drifting apart.
  editor.ensureLayout()
  let (x, y) = editor.documentPoint(viewX, viewY)
  let size = taskCheckboxSize(editor.fonts.textMetrics(), editor.widths,
                              editor.baseFont)
  let metrics = editor.fonts.metricsFor(editor.baseFont)
  for line in editor.layout.visibleLines(y - 1.0, y + 1.0):
    for item in line.items:
      if not item.attributes.has(akTaskCheckbox): continue
      let contentX = line.textOriginX + item.x
      let boxX = taskCheckboxBoxX(contentX, size)
      let baselineY = line.origin.y + line.baseline
      let centerY = baselineY + (metrics.descent - metrics.ascent) * 0.5
      let boxY = centerY - size * 0.5
      if x >= boxX - 2.0 and x <= boxX + size + 2.0 and
         y >= boxY - 2.0 and y <= boxY + size + 2.0:
        return (rng(item.location, item.length), true)
  (notFoundRange(), false)

proc linkAt*(editor: Editor, viewX, viewY: float): (string, bool, bool) =
  ## `(target, isWikiLink, found)` for a click.
  editor.ensureLayout()
  let location = editor.locationAt(viewX, viewY)
  if location < 0 or location >= editor.storage.len: return ("", false, false)
  let attrs = editor.storage.attributesAt(location)
  let wikiID = attrs.stringOf(akWikiLinkID, "")
  let link = attrs.stringOf(akLink, "")
  if wikiID.len > 0: return (wikiID, true, true)
  if link.len > 0: return (link, false, true)
  ("", false, false)

proc toggleCheckbox*(editor: Editor, boxRange: Range) =
  ## Flip `[ ]` ⇄ `[x]`. The box range the hit test reports is the collapsed
  ## `[ ]` run, which is exactly what the engine's toggle expects.
  let line = editor.storage.text.lineRange(boxRange)
  let (m, ok) = matchListLine(editor.storage.text, line)
  if not ok or not m.hasCheckbox: return
  let decision = toggleTaskCheckbox(editor.storage.text, m.checkbox)
  if not decision.hasEdit: return
  let savedSelection = editor.selection
  editor.applyEdit(decision.replaceRange, decision.replacement,
                   savedSelection, true, false)

# ---------------------------------------------------------------------------
# Mouse
# ---------------------------------------------------------------------------

type
  DragState* = object
    active*: bool
    anchor*: int
    mode*: range[0 .. 2]     ## 0 = character, 1 = word, 2 = line

proc beginDrag*(editor: Editor, viewX, viewY: float, clickCount: int,
                extend: bool): DragState =
  editor.ensureLayout()
  let location = editor.locationAt(viewX, viewY)
  if clickCount >= 3:
    let line = editor.storage.text.lineRange(caretAt(location))
    editor.setSelection(line)
    return DragState(active: true, anchor: location, mode: 2)
  if clickCount == 2:
    let word = editor.layout.wordRangeAt(location)
    editor.setSelection(word)
    return DragState(active: true, anchor: location, mode: 1)
  if extend:
    let anchor = if editor.selection.length > 0 and
                    location > editor.selection.location:
                   editor.selection.location
                 else: maxRange(editor.selection)
    let lo = min(anchor, location)
    let hi = max(anchor, location)
    editor.setSelection(rng(lo, hi - lo))
    return DragState(active: true, anchor: anchor, mode: 0)
  editor.setSelection(caretAt(location))
  DragState(active: true, anchor: location, mode: 0)

proc continueDrag*(editor: Editor, state: DragState, viewX, viewY: float) =
  if not state.active: return
  editor.ensureLayout()
  let location = editor.locationAt(viewX, viewY)
  case state.mode
  of 1:
    let anchorWord = editor.layout.wordRangeAt(state.anchor)
    let currentWord = editor.layout.wordRangeAt(location)
    let lo = min(anchorWord.location, currentWord.location)
    let hi = max(maxRange(anchorWord), maxRange(currentWord))
    editor.setSelection(rng(lo, hi - lo))
  of 2:
    let anchorLine = editor.storage.text.lineRange(caretAt(state.anchor))
    let currentLine = editor.storage.text.lineRange(caretAt(location))
    let lo = min(anchorLine.location, currentLine.location)
    let hi = max(maxRange(anchorLine), maxRange(currentLine))
    editor.setSelection(rng(lo, hi - lo))
  else:
    let lo = min(state.anchor, location)
    let hi = max(state.anchor, location)
    editor.setSelection(rng(lo, hi - lo))

proc dragAutoscroll*(editor: Editor, viewY: float, dt: float) =
  ## The drag-select autoscroll boost: once the pointer passes the viewport
  ## edge, scroll toward it so a selection can reach past the visible text.
  let policy = editor.config.dragSelection
  let top = editor.viewport.y + policy.edgeTriggerDistance
  let bottom = editor.viewport.y + editor.viewport.h - policy.edgeTriggerDistance
  let step = policy.scrollStepPerTick * policy.ticksPerSecond * dt
  if viewY < top: editor.scrollBy(-step)
  elif viewY > bottom: editor.scrollBy(step)

# ---------------------------------------------------------------------------
# Clipboard
# ---------------------------------------------------------------------------

proc selectedMarkdown*(editor: Editor): string =
  ## The selection in STORAGE form, so a copy carries `[[Name|<id>]]` rather
  ## than the display label.
  if editor.selection.length <= 0: return ""
  let display = editor.storage.substring(editor.selection)
  let fragmentStorage = makeStorageState(
    initText(display), initTable[RangeKey, LinkMetadata](),
    proc (location: int): (string, bool) {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        let attrs = editor.storage.attributesAt(editor.selection.location + location)
        let id = attrs.stringOf(akWikiLinkID, "")
        if id.len > 0: (id, true) else: ("", false))
  fragmentStorage[0]

proc copyPayload*(editor: Editor): (ClipboardPayload, bool) =
  let markdown = editor.selectedMarkdown()
  if markdown.len == 0: return (ClipboardPayload(), false)
  (makeClipboardPayload(markdown, editor.config.extensions,
                        editor.config.directives,
                        editor.config.directiveSettings), true)

proc cutPayload*(editor: Editor): (ClipboardPayload, bool) =
  let (payload, ok) = editor.copyPayload()
  if ok: editor.applyEdit(editor.selection, "", caretAt(0), false, false)
  (payload, ok)

proc pasteMarkdown*(editor: Editor, markdown: string) =
  ## Paste, after the engine's quote-continuation transform: pasting into a
  ## blockquote keeps every line inside the quote.
  if markdown.len == 0: return
  let display = makeDisplayState(markdown)[0]
  let adjusted = blockquoteContinuedPaste(display, editor.selection.location,
                                          editor.storage.text)
  editor.applyEdit(editor.selection, adjusted, caretAt(0), false, false)
  editor.scrollCaretToVisible()

# ---------------------------------------------------------------------------
# Find / replace
# ---------------------------------------------------------------------------

proc runFind*(editor: Editor, query: string, keepCurrent = false) =
  ## Match in DISPLAY coordinates, so highlights land correctly even where the
  ## displayed text differs from the source.
  editor.findQuery = query
  editor.findMatches = @[]
  if query.len == 0:
    editor.currentMatch = -1
    editor.needsRedraw = true
    if editor.hooks.findResults != nil: editor.hooks.findResults(0, -1)
    return
  let needle = toUtf16(query.toLowerAscii)
  let haystack = toUtf16(($editor.storage.text).toLowerAscii)
  if needle.len == 0 or haystack.len < needle.len:
    editor.currentMatch = -1
    editor.needsRedraw = true
    if editor.hooks.findResults != nil: editor.hooks.findResults(0, -1)
    return
  var i = 0
  while i + needle.len <= haystack.len:
    var k = 0
    while k < needle.len and haystack[i + k] == needle[k]: inc k
    if k == needle.len:
      editor.findMatches.add rng(i, needle.len)
      i += needle.len
    else:
      inc i
  if editor.findMatches.len == 0:
    editor.currentMatch = -1
  elif not keepCurrent or editor.currentMatch < 0:
    # Start from the match at or after the caret.
    editor.currentMatch = 0
    for index, match in editor.findMatches:
      if match.location >= editor.selection.location:
        editor.currentMatch = index
        break
  else:
    editor.currentMatch = min(editor.currentMatch, editor.findMatches.len - 1)
  editor.needsRedraw = true
  if editor.hooks.findResults != nil:
    editor.hooks.findResults(editor.findMatches.len, editor.currentMatch)

proc focusMatch(editor: Editor) =
  if editor.currentMatch < 0 or editor.currentMatch >= editor.findMatches.len:
    return
  let match = editor.findMatches[editor.currentMatch]
  editor.setSelection(match)
  editor.scrollRangeToVisible(match)
  if editor.hooks.findResults != nil:
    editor.hooks.findResults(editor.findMatches.len, editor.currentMatch)

proc findNext*(editor: Editor) =
  if editor.findMatches.len == 0: return
  editor.currentMatch = (editor.currentMatch + 1) mod editor.findMatches.len
  editor.focusMatch()

proc findPrevious*(editor: Editor) =
  if editor.findMatches.len == 0: return
  editor.currentMatch = (editor.currentMatch - 1 + editor.findMatches.len) mod
                        editor.findMatches.len
  editor.focusMatch()

proc clearFind*(editor: Editor) =
  editor.findQuery = ""
  editor.findMatches = @[]
  editor.currentMatch = -1
  editor.needsRedraw = true

proc replaceCurrentMatch*(editor: Editor, replacement: string) =
  if editor.currentMatch < 0 or editor.currentMatch >= editor.findMatches.len:
    return
  let match = editor.findMatches[editor.currentMatch]
  editor.applyEdit(match, replacement,
                   caretAt(match.location + utf16Len(replacement)), true, false)
  let saved = editor.currentMatch
  editor.runFind(editor.findQuery, keepCurrent = true)
  editor.currentMatch = min(saved, max(0, editor.findMatches.len - 1))
  if editor.findMatches.len > 0: editor.focusMatch()

proc replaceAllMatches*(editor: Editor, replacement: string) =
  ## One undo step for the whole sweep, replacing from the END so earlier
  ## offsets stay valid.
  if editor.findMatches.len == 0: return
  inc editor.coalesceGroup
  let group = editor.coalesceGroup
  for index in countdown(editor.findMatches.len - 1, 0):
    let match = editor.findMatches[index]
    editor.applyEdit(match, replacement, caretAt(match.location), true, false)
    if editor.undoStack.len > 0:
      editor.undoStack[^1].coalesceGroup = group
  editor.lastEditWasTyping = false
  editor.runFind(editor.findQuery)

# ---------------------------------------------------------------------------
# Formatting actions
# ---------------------------------------------------------------------------

proc wordAround(t: Utf16Text, location: int): Range =
  ## The word run touching `location`, or an empty range when the caret sits
  ## between two non-word characters.
  ##
  ## Deliberately not `wordRangeAt`: that one selects a whitespace or
  ## punctuation run so a double-click always selects something, which here
  ## would wrap the spaces in `hello |  world` instead of inserting an empty
  ## pair for the user to type into.
  proc isWordUnit(c: uint16): bool =
    isAlphanumericUnit(c) or c == chUnderscore

  let onLeft = location > 0 and isWordUnit(t.charAt(location - 1))
  let onRight = location < t.len and isWordUnit(t.charAt(location))
  if not onLeft and not onRight: return rng(location, 0)
  var lo = location
  var hi = location
  while lo > 0 and isWordUnit(t.charAt(lo - 1)): dec lo
  while hi < t.len and isWordUnit(t.charAt(hi)): inc hi
  rng(lo, hi - lo)

proc enclosingToken(editor: Editor, target: Range,
                    kind: MarkdownTokenKind,
                    extensionID = ""): (MarkdownToken, bool) =
  ## The innermost token of `kind` containing `target`.
  ##
  ## Toggling a format OFF goes through the token list rather than through a
  ## literal probe of the characters around the selection. The markers are
  ## almost never part of what the user highlighted, and a selection dragged
  ## by hand lands half on them as often as not — `**bb**` with `b**` selected
  ## is still a request to unbold `bb`. The parser already knows where the
  ## span begins and ends, so asking it is both simpler and more forgiving
  ## than re-deriving that from the text.
  result = (MarkdownToken(), false)
  for tok in editor.tokens:
    if tok.kind != kind: continue
    if extensionID.len > 0 and tok.extensionID != extensionID: continue
    if not containsRange(tok.range, target): continue
    if not result[1] or tok.range.length < result[0].range.length:
      result = (tok, true)

proc unwrapToken(editor: Editor, tok: MarkdownToken, trim: int) =
  ## Remove `trim` units from each of the token's two markers.
  ##
  ## A full strip passes the marker's own length; a partial one is how
  ## `***both***` degrades — bold off leaves `*both*`, italic off leaves
  ## `**both**` — instead of refusing because the span is not purely one or
  ## the other.
  if tok.markerRanges.len < 2: return
  let openMarker = tok.markerRanges[0]
  let closeMarker = tok.markerRanges[1]
  let keepOpen = max(0, openMarker.length - trim)
  let keepClose = max(0, closeMarker.length - trim)
  let inner = editor.storage.substring(
    rng(maxRange(openMarker), closeMarker.location - maxRange(openMarker)))
  let replacement = editor.storage.substring(rng(openMarker.location, keepOpen)) &
                    inner &
                    editor.storage.substring(rng(closeMarker.location, keepClose))
  editor.applyEdit(tok.range, replacement,
                   rng(tok.range.location + keepOpen, utf16Len(inner)),
                   true, false)

proc wrapSelection(editor: Editor, open, close: string,
                   kind: MarkdownTokenKind, extensionID = "",
                   mixedKind = tkItalic, hasMixed = false, mixedTrim = 0,
                   expandToWord = true) =
  ## Toggle a delimiter pair around the selection.
  ##
  ## With no selection the target is the word under the caret — what ⌘B does
  ## mid-word in every editor that has the key — and with no word there
  ## either, an empty pair goes in with the caret between the markers.
  ##
  ## `mixedKind` is the combined span this format is one half of: toggling
  ## bold inside `***both***` has to find a `tkBoldItalic` token, because no
  ## `tkBold` one exists there.
  let t = editor.storage.text
  let selection = editor.selection
  let hadSelection = selection.length > 0
  let target = if hadSelection: selection
               elif expandToWord: wordAround(t, selection.location)
               else: selection
  let openLen = utf16Len(open)

  if target.length == 0:
    editor.applyEdit(target, open & close,
                     caretAt(target.location + openLen), true, false)
    return

  let (tok, found) = editor.enclosingToken(target, kind, extensionID)
  if found:
    editor.unwrapToken(tok, max(tok.markerRanges[0].length,
                                tok.markerRanges[1].length))
    return
  if hasMixed:
    let (mixed, foundMixed) = editor.enclosingToken(target, mixedKind)
    if foundMixed:
      editor.unwrapToken(mixed, mixedTrim)
      return

  let inner = editor.storage.substring(target)
  let wrapped = open & inner & close
  # A caret keeps its offset within the word; a selection keeps its content
  # selected, now without the markers around it.
  let after = if hadSelection:
                rng(target.location + openLen, target.length)
              else:
                caretAt(selection.location + openLen)
  editor.applyEdit(target, wrapped, after, true, false)

proc insertBlock(editor: Editor, body: string, caretOffset: int) =
  ## Put `body` on lines of its own, splitting the current line when the caret
  ## is inside one. `caretOffset` is measured from the start of `body`.
  let t = editor.storage.text
  let location = editor.selection.location
  let atLineStart = location == 0 or isLineBreakUnit(t.charAt(location - 1))
  let prefix = if atLineStart: "" else: "\n"
  let replacement = prefix & body & "\n"
  editor.applyEdit(editor.selection, replacement,
                   caretAt(editor.selection.location + utf16Len(prefix) + caretOffset),
                   true, false)

proc prefixLines(editor: Editor, prefix: string, toggle: bool) =
  ## Apply a line prefix to every line the selection touches, toggling it off
  ## when all of them already have it.
  let paragraphs = editor.paragraphsForRange(editor.selection)
  if paragraphs.len == 0: return
  let region = rng(paragraphs[0].location,
                   maxRange(paragraphs[^1]) - paragraphs[0].location)
  var lines: seq[string] = @[]
  var allPrefixed = true
  for line in editor.storage.text.lineRanges(region):
    let text = editor.storage.substring(editor.storage.text.trimmedTrailingNewlines(line))
    lines.add text
    if not text.startsWith(prefix): allPrefixed = false
  if lines.len == 0: return
  var rebuilt: seq[string] = @[]
  for text in lines:
    if toggle and allPrefixed: rebuilt.add text[prefix.len .. ^1]
    else: rebuilt.add prefix & text
  var replacement = rebuilt.join("\n")
  # Keep the region's trailing newline so the following block does not merge.
  if region.length > 0 and
     isLineBreakUnit(editor.storage.text.charAt(maxRange(region) - 1)):
    replacement.add "\n"
  editor.applyEdit(region, replacement,
                   rng(region.location, utf16Len(replacement)), true, false)

proc headingPrefix(level: int): string =
  if level <= 0: "" else: repeat('#', min(6, level)) & " "

proc applyHeading*(editor: Editor, level: int) =
  ## Replace whatever heading marker the line already has, so the levels
  ## cycle rather than stack.
  let line = editor.storage.text.lineRange(caretAt(editor.selection.location))
  let content = editor.storage.text.trimmedTrailingNewlines(line)
  let text = editor.storage.substring(content)
  var stripped = text
  var existing = 0
  var i = 0
  while i < stripped.len and stripped[i] == '#' and existing < 6:
    inc existing
    inc i
  if existing > 0 and i < stripped.len and stripped[i] == ' ':
    stripped = stripped[i + 1 .. ^1]
  elif existing > 0:
    stripped = stripped[i .. ^1]
  let wanted = if existing == level: 0 else: level
  let replacement = headingPrefix(wanted) & stripped
  editor.applyEdit(content, replacement,
                   caretAt(content.location + utf16Len(replacement)), true, false)

proc applyRequest*(editor: Editor, request: EditorRequest) =
  ## The host-facing formatting commands.
  case request.kind
  of erApplyBold:
    editor.wrapSelection("**", "**", tkBold,
                         mixedKind = tkBoldItalic, hasMixed = true,
                         mixedTrim = 2)
  of erApplyItalic:
    editor.wrapSelection("*", "*", tkItalic,
                         mixedKind = tkBoldItalic, hasMixed = true,
                         mixedTrim = 1)
  of erApplyHighlight:
    editor.wrapSelection("==", "==", tkExtensionSpan, highlightExtensionID)
  of erApplyStrikethrough:
    editor.wrapSelection("~~", "~~", tkExtensionSpan, strikethroughExtensionID)
  of erApplyInlineCode:
    editor.wrapSelection("`", "`", tkInlineCode)
  of erApplyHeading: editor.applyHeading(request.level)
  of erApplyBlockquote: editor.prefixLines("> ", true)
  of erApplyUnorderedList: editor.prefixLines("- ", true)
  of erApplyOrderedList: editor.prefixLines("1. ", true)
  of erApplyLink:
    # No selection means empty brackets with the caret between them, ready for
    # the label — never a placeholder word, which the user would have to
    # select and delete before typing the one they wanted.
    let label = if editor.selection.length > 0:
                  editor.storage.substring(editor.selection)
                else: ""
    let url = if request.text.len > 0: request.text else: "https://"
    let replacement = "[" & label & "](" & url & ")"
    let caret = if editor.selection.length > 0:
                  editor.selection.location + utf16Len(replacement)
                else: editor.selection.location + 1
    editor.applyEdit(editor.selection, replacement, caretAt(caret), true, false)
  of erApplyImage:
    let url = if request.text.len > 0: request.text else: "image.png"
    let replacement = "![](" & url & ")"
    editor.applyEdit(editor.selection, replacement,
                     caretAt(editor.selection.location + utf16Len(replacement)),
                     true, false)
  of erApplyCodeBlock:
    let inner = if editor.selection.length > 0:
                  editor.storage.substring(editor.selection)
                else: ""
    editor.insertBlock("```\n" & inner & "\n```", 4)
  of erApplyHorizontalRule:
    editor.insertBlock("---", 3)
  of erFindQuery: editor.runFind(request.text)
  of erFindClearHighlights: editor.clearFind()
  of erReplaceCurrent: editor.replaceCurrentMatch(request.replacement)
  of erReplaceAll: editor.replaceAllMatches(request.replacement)

# ---------------------------------------------------------------------------
# Directive completion commit
# ---------------------------------------------------------------------------

proc completionCandidateCount*(editor: Editor): int =
  if editor.hasCompletionContext: editor.completionContext.candidates.len else: 0

proc moveCompletionSelection*(editor: Editor, delta: int) =
  let count = editor.completionCandidateCount()
  if count == 0: return
  editor.completionIndex = (editor.completionIndex + delta + count) mod count
  editor.needsRedraw = true

proc commitCompletion*(editor: Editor): bool =
  ## Apply the highlighted candidate. The commit path is deliberately separate
  ## from the wiki-link replacement path, which runs the storage/display
  ## transform; a directive snippet is literal text.
  if not editor.hasCompletionContext: return false
  let count = editor.completionContext.candidates.len
  if count == 0: return false
  let candidate = editor.completionContext.candidates[
    clamp(editor.completionIndex, 0, count - 1)]
  let target = editor.completionContext.replacementRange
  let caret = if candidate.hasCaretOffset:
                target.location + candidate.caretOffset
              else: target.location + utf16Len(candidate.insertion)
  editor.applyEdit(target, candidate.insertion, caretAt(caret), true, false)
  editor.hasCompletionContext = false
  true

# ---------------------------------------------------------------------------
# Frame tick
# ---------------------------------------------------------------------------

proc tick*(editor: Editor, now: float) =
  ## Blink the caret. Called once per frame; the blink is the only thing in the
  ## editor that changes without input.
  if not editor.hasFocus:
    if editor.caretOn:
      editor.caretOn = false
      editor.needsRedraw = true
    return
  if editor.lastCaretBlink == 0: editor.lastCaretBlink = now
  if now - editor.lastCaretBlink >= caretBlinkInterval:
    editor.lastCaretBlink = now
    editor.caretOn = not editor.caretOn
    editor.needsRedraw = true
