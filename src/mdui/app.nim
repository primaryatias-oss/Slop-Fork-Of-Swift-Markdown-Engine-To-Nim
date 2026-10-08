## app.nim
## MarkdownEngine (Nim port) — demo app
##
## The SDL3 window, the event loop, and everything that wires the editor to
## them: keyboard and text input, mouse selection with the drag-autoscroll
## boost, the wheel, the clipboard, the find bar, the context menu, the
## directive-completion picker, the scroll-away header, and the toolbar.
##
## This is the `MarkdownEngineDemoApp` / `ContentView` layer. The SwiftUI
## original declared its UI; here each piece is drawn and hit-tested
## explicitly, which is the shape SDL leaves you with. The division of
## responsibility is the same one the engine's docs insist on: the engine
## publishes state (a completion context, a caret rect, a selection flag set)
## and the app decides what to show.

import std/[math, os, strutils, tables, times, unicode]
import ./sdlbridge
import ../markdownengine
import ./fontmanager, ./textstorage, ./layout, ./atlas, ./painter, ./render
import ./screenshot
import ./widgets, ./editor, ./demodirectives

type
  ToolbarAction = enum
    taBold, taItalic, taHighlight, taStrike, taCode, taH1, taH2, taQuote,
    taBullet, taNumbered, taRule, taCodeBlock, taLink, taFind, taTheme,
    taReadingWidth, taRawSource, taSample

  MenuAction = enum
    maCut, maCopy, maPaste, maSelectAll, maBold, maItalic, maHighlight,
    maStrikethrough, maInlineCode, maLink, maCodeBlock, maQuote, maBullet,
    maNumbered, maRule, maUndo, maRedo

  App* = ref object
    window: Window
    renderer: Renderer
    fonts: FontManager
    atlas: GlyphAtlas
    painter: Painter
    images: ImageStore
    editor: Editor
    config: MarkdownEditorConfiguration

    width, height: float
    pixelScale: float
    running: bool
    appearance: Appearance

    toolbarHeight: float
    toolbar: seq[Button]
    hoveredButton: int

    scroller: Scroller
    scrollerHovered: bool

    findBar: FindBar
    findFocused: bool

    menu: ContextMenu
    menuActions: seq[MenuAction]

    header: ScrollingHeader

    drag: DragState
    dragging: bool
    lastMouse: tuple[x, y: float]
    mouseDownTime: float
    clickCount: int
    lastClickPos: tuple[x, y: float]

    ibeamCursor: Cursor
    arrowCursor: Cursor
    handCursor: Cursor
    currentCursor: int

    sampleIndex: int
    statusMessage: string
    statusUntil: float

const
  windowTitle = "MarkdownEngine — Nim / SDL3"
  toolbarButtonHeight = 24.0
  findBarHeight = 38.0

# ---------------------------------------------------------------------------
# Sample documents
# ---------------------------------------------------------------------------

const welcomeDocument = """# MarkdownEngine

A live-styling Markdown editor, ported from Swift to **Nim** and drawn with **SDL3**. The engine is the same two-phase parser, the same compose-on-descent styler, and the same extension and directive seams; everything AppKit used to supply — font rasterizing, text layout, hit testing — is written here.

## Live styling

Markers *shrink*, they never disappear: put the caret inside **this bold run** and the asterisks come back. That one invariant is what keeps selection, copy, find and undo honest — the document you edit is the markdown you save.

Inline `code`, a [link](https://github.com/nodes-app/swift-markdown-engine), an ==extension span== and ~~strikethrough~~, all opt-in.

### Lists

- a bullet item
- another one, long enough to wrap so you can see that the continuation hangs under the first line's text rather than under the marker
- [ ] an unchecked task — click the box
- [x] a finished one

1. ordered items renumber positionally
1. so this reads as 2
1. and this as 3

> A blockquote keeps its bar in the gutter and mutes its text.
> Each line paints its own segment, so a run reads as one bar.

### Code

```nim
proc parseBlocks(t: Utf16Text): seq[Block] =
  ## Gap-free tiling blocks, memoised against the last parse.
  for line in t.lineRanges(t.fullRange):
    discard line
```

### Tables

| Construct | Syntax | Notes |
|---|---|---|
| heading | `# text` | six levels, scaled per level |
| emphasis | `*a*` / `**a**` | composes, so bold inside a heading stays big |
| task | `- [ ] a` | the box is drawn, the source is collapsed |

### Directives

Registered names only: @emoji(tada) and @flag(JP) and @icon(star) render, while `@notregistered` stays literal text. A container directive composes over the inherited font, so @font(size: 22){this is larger} and @color(blue){this is blue}.

***

Try: Ctrl+B, Ctrl+I, Ctrl+F, Tab inside a list, Return after a fence.
"""

const kitchenSink = """# Kitchen sink

## Emphasis composition

The flat pass pipeline got this wrong: a heading like # **n*o*des** must keep the heading's size inside bold, and italic inside bold must keep both traits.

Nested: **bold with *italic* inside**, and *italic with **bold** inside*.

## Escapes and literals

A literal \*asterisk\*, a literal \# hash, and `a code span with *stars*`.

The text `@font(size: 18){x}` inside a code span stays literal — the directive scanner runs after code spans have already claimed their text.

## Links

A wiki link to [[Another Note]], one to [[Nowhere]] that does not resolve, an auto-linked bare domain example.com, and an incomplete [bracket run.

## Block LaTeX

$$
E = mc^2
$$

Inline math like $x^2 + y^2 = r^2$ sits on the text baseline.

## Thematic breaks

---

***

___

## Wide table

| id | name | description | owner | status | updated |
|---|---|---|---|---|---|
| 1 | parser | two-phase, block structure then inline | engine | done | today |
| 2 | styler | composes attributes on descent | engine | done | today |
| 3 | layout | the TextKit 2 replacement | ui | done | today |
| 4 | raster | TrueType outlines, analytic coverage | ui | done | today |
"""

const emptyDocument = ""

proc sampleDocuments(): seq[tuple[name, text: string]] =
  @[("Welcome", welcomeDocument), ("Kitchen sink", kitchenSink),
    ("Empty", emptyDocument)]

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

proc makeHighlighter(fonts: FontManager,
                     config: MarkdownEditorConfiguration): SyntaxHighlighter =
  ## A small keyword highlighter.
  ##
  ## The Swift package offered `HighlighterSwiftBridge` as an opt-in product
  ## built on a third-party library; nothing comparable is importable here
  ## under "standard library only", so the demo supplies its own. It only has
  ## to prove the seam works: the engine asks for coloured runs over a code
  ## string and knows nothing else about them.
  const keywords = ["proc", "func", "var", "let", "const", "type", "import",
                    "export", "return", "if", "elif", "else", "while", "for",
                    "in", "case", "of", "discard", "result", "object", "ref",
                    "enum", "template", "macro", "yield", "block", "break",
                    "continue", "and", "or", "not", "true", "false", "nil",
                    "def", "class", "function", "struct", "public", "private",
                    "static", "guard", "switch", "extension", "protocol",
                    "where", "self", "init", "fn", "pub", "use", "mut",
                    "impl", "match", "async", "await", "new", "delete"]

  proc isWordChar(ch: char): bool {.inline.} =
    ch.isAlphaNumeric or ch == '_'

  newSyntaxHighlighter(
    codeFontProc = proc (size: float): FontDesc {.closure, gcsafe.} =
      monospacedSystemFont(size),
    backgroundColorProc = proc (): Color {.closure, gcsafe.} =
      dynamicColor(Rgba(r: 0.47, g: 0.52, b: 0.58, a: 0.12),
                   Rgba(r: 0.60, g: 0.66, b: 0.74, a: 0.16)),
    highlightProc = proc (code: string, language: string,
                          hasLanguage: bool): (seq[HighlightRun], bool) {.closure, gcsafe.} =
      var runs: seq[HighlightRun] = @[]
      let keywordColor = hexColor(0x9B2393, 0xFF7AB2)
      let stringColor = hexColor(0xC41A16, 0xFF8170)
      let commentColor = hexColor(0x5D6C79, 0x7F8C98)
      let numberColor = hexColor(0x1C00CF, 0xD0BF69)
      # Offsets must be UTF-16, because that is what the engine's ranges mean.
      var utf16Index = 0
      var i = 0
      while i < code.len:
        let ch = code[i]
        if ch == '#' or (ch == '/' and i + 1 < code.len and code[i + 1] == '/'):
          let start = utf16Index
          while i < code.len and code[i] != '\n':
            utf16Index += utf16Len($code[i])
            inc i
          runs.add HighlightRun(range: rng(start, utf16Index - start),
                                color: commentColor)
          continue
        if ch == '"' or ch == '\'':
          let quote = ch
          let start = utf16Index
          utf16Index += 1
          inc i
          while i < code.len and code[i] != quote and code[i] != '\n':
            if code[i] == '\\' and i + 1 < code.len:
              utf16Index += utf16Len($code[i])
              inc i
            utf16Index += utf16Len($code[i])
            inc i
          if i < code.len and code[i] == quote:
            utf16Index += 1
            inc i
          runs.add HighlightRun(range: rng(start, utf16Index - start),
                                color: stringColor)
          continue
        if ch.isDigit and (i == 0 or not isWordChar(code[i - 1])):
          let start = utf16Index
          while i < code.len and (code[i].isDigit or code[i] == '.' or
                                  code[i] == 'x' or code[i] == '_'):
            utf16Index += 1
            inc i
          runs.add HighlightRun(range: rng(start, utf16Index - start),
                                color: numberColor)
          continue
        if isWordChar(ch) and (i == 0 or not isWordChar(code[i - 1])):
          let start = utf16Index
          let wordStart = i
          while i < code.len and isWordChar(code[i]):
            utf16Index += 1
            inc i
          let word = code[wordStart ..< i]
          if word in keywords:
            runs.add HighlightRun(range: rng(start, utf16Index - start),
                                  color: keywordColor)
          continue
        utf16Index += utf16Len($ch)
        inc i
      (runs, runs.len > 0))

proc makeImageProvider(store: ImageStore): EmbeddedImageProvider =
  ## Loads what SDL3 and the standard library can actually decode: BMP, and the
  ## uncompressed PNM family. PNG and JPEG need an inflate/DCT decoder, and
  ## there is none in the Nim standard library — so those reserve space and the
  ## renderer draws a labelled placeholder instead of pretending.
  var cache = initTable[string, ImageHandle]()
  newEmbeddedImageProvider(
    imageProc = proc (request: EmbeddedImageRequest): (ImageHandle, bool) {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        if cache.hasKey(request.name): return (cache[request.name], true)
        var candidates = @[request.name]
        if not request.name.isAbsolute:
          candidates.add getCurrentDir() / request.name
          candidates.add getCurrentDir() / "media" / request.name
        for candidate in candidates:
          if not fileExists(candidate): continue
          let (handle, ok) = store.loadImageFile(candidate)
          if ok:
            cache[request.name] = handle
            return (handle, true)
        (ImageHandle(), false),
    fingerprintProc = proc (): string {.closure, gcsafe.} = "demo")

proc makeWikiResolver(): WikiLinkResolver =
  ## A tiny in-memory note index, so wiki links resolve (and some deliberately
  ## do not, to show the broken-link styling).
  const known = ["Another Note", "Design System", "Architecture"]
  newWikiLinkResolver(
    resolveProc = proc (displayName: string,
                        r: Range): (WikiLinkResolution, bool) {.closure, gcsafe.} =
      for name in known:
        if name == displayName:
          return (WikiLinkResolution(id: name, exists: true), true)
      (WikiLinkResolution(id: displayName, exists: false), true),
    fingerprintProc = proc (): string {.closure, gcsafe.} = "demo-notes")

# ---------------------------------------------------------------------------
# Chrome layout
# ---------------------------------------------------------------------------

proc chromeFont(app: App): FontDesc = initFont("sans", 12.0)
proc chromeSmallFont(app: App): FontDesc = initFont("sans", 10.5)

proc toolbarLabels(): seq[tuple[action: ToolbarAction, label, tooltip: string]] =
  @[(taBold, "B", "Bold"), (taItalic, "I", "Italic"),
    (taHighlight, "H", "Highlight"), (taStrike, "S", "Strikethrough"),
    (taCode, "`", "Inline code"), (taH1, "H1", "Heading 1"),
    (taH2, "H2", "Heading 2"), (taQuote, ">", "Blockquote"),
    (taBullet, "•", "Bulleted list"), (taNumbered, "1.", "Numbered list"),
    (taRule, "—", "Horizontal rule"), (taCodeBlock, "{}", "Code block"),
    (taLink, "link", "Insert link"), (taFind, "find", "Find & replace"),
    (taTheme, "theme", "Light / dark"),
    (taReadingWidth, "column", "Reading column"),
    (taRawSource, "raw", "Raw source mode"),
    (taSample, "sample", "Next sample document")]

proc layoutToolbar(app: App) =
  app.toolbar = @[]
  var x = 10.0
  let y = (app.toolbarHeight - toolbarButtonHeight) * 0.5
  let desc = app.chromeFont()
  for (action, label, tooltip) in toolbarLabels():
    let width = max(26.0, app.fonts.measureString(label, desc) + 16.0)
    var active = false
    case action
    of taTheme: active = app.appearance == apDark
    of taReadingWidth: active = app.config.hasReadingWidth
    of taRawSource: active = app.config.rawSourceMode
    of taFind: active = app.findBar.visible
    of taBold: active = app.editor.selectionFlags().isBold
    of taItalic: active = app.editor.selectionFlags().isItalic
    of taHighlight: active = app.editor.selectionFlags().isHighlight
    else: discard
    app.toolbar.add Button(rect: rect(x, y, width, toolbarButtonHeight),
                           label: label, tooltip: tooltip, id: ord(action),
                           active: active, enabled: true)
    x += width + 4.0

proc editorFrame(app: App): tuple[x, y, w, h: float] =
  let top = app.toolbarHeight + (if app.findBar.visible: findBarHeight else: 0.0)
  (0.0, top, app.width, max(1.0, app.height - top))

proc headerBandHeight(app: App): float =
  if app.header.bandHeight <= 0: 0.0
  else:
    let progress = app.header.headerCollapseProgress(app.editor.scrollY)
    app.header.bandHeight - (app.header.bandHeight - app.header.collapsedHeight) * progress

proc applyLayout(app: App) =
  app.toolbarHeight = 36.0
  if app.findBar.visible:
    app.findBar.rect = rect(0.0, app.toolbarHeight, app.width, findBarHeight)
  let frame = app.editorFrame()
  # The header band is part of the scrolled content in the original; here it
  # sits above the text column and the editor's own inset accounts for it.
  app.editor.contentInsets = (24.0, app.header.bandHeight + 12.0)
  app.editor.setViewport(frame.x, frame.y, frame.w, frame.h)
  app.layoutToolbar()

# ---------------------------------------------------------------------------
# Status line
# ---------------------------------------------------------------------------

proc showStatus(app: App, message: string) =
  app.statusMessage = message
  app.statusUntil = epochTime() + 2.4
  app.editor.needsRedraw = true

# ---------------------------------------------------------------------------
# Clipboard
# ---------------------------------------------------------------------------

proc copySelection(app: App, cut: bool) =
  let (payload, ok) = if cut: app.editor.cutPayload() else: app.editor.copyPayload()
  if not ok:
    app.showStatus("Nothing selected")
    return
  # SDL3's clipboard carries one text flavour, so the plain-text (raw markdown)
  # form is what goes on it — which is also the flavour the engine's own paste
  # path prefers, so a copy inside the editor round-trips byte-exact.
  discard setClipboardText(payload.plain.cstring)
  app.showStatus(if cut: "Cut" else: "Copied")

proc pasteClipboard(app: App) =
  if not hasClipboardText():
    app.showStatus("Clipboard is empty")
    return
  let raw = getClipboardText()
  if raw == nil: return
  let text = $raw
  # A paste that looks like HTML goes through the lenient converter, which is
  # what the smart-paste path did; anything else is markdown already.
  let trimmed = text.strip()
  if trimmed.startsWith("<") and trimmed.contains(">"):
    let (converted, ok) = markdownFromHTML(text)
    app.editor.pasteMarkdown(if ok: converted else: text)
  else:
    app.editor.pasteMarkdown(text)

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------

proc buildContextMenu(app: App, x, y: float) =
  let hasSelection = app.editor.selection.length > 0
  var items: seq[MenuItem] = @[]
  var actions: seq[MenuAction] = @[]

  proc add(title: string, action: MenuAction, enabled = true) =
    items.add MenuItem(title: title, id: items.len, enabled: enabled)
    actions.add action

  proc separator() =
    items.add MenuItem(isSeparator: true)
    actions.add maCut

  add("Cut", maCut, hasSelection)
  add("Copy", maCopy, hasSelection)
  add("Paste", maPaste, hasClipboardText())
  add("Select All", maSelectAll)
  separator()
  add("Bold", maBold)
  add("Italic", maItalic)
  add("Highlight", maHighlight)
  add("Strikethrough", maStrikethrough)
  add("Inline Code", maInlineCode)
  separator()
  add("Insert Link", maLink)
  add("Code Block", maCodeBlock)
  add("Blockquote", maQuote)
  add("Bulleted List", maBullet)
  add("Numbered List", maNumbered)
  add("Horizontal Rule", maRule)
  separator()
  add("Undo", maUndo)
  add("Redo", maRedo)

  app.menuActions = actions
  let width = menuWidthFor(app.fonts, items, app.chromeFont())
  var origin: tuple[x, y: float] = (x, y)
  let height = ContextMenu(items: items).menuHeight()
  if origin.x + width > app.width: origin.x = max(0.0, app.width - width)
  if origin.y + height > app.height: origin.y = max(0.0, app.height - height)
  app.menu = ContextMenu(visible: true, origin: origin, width: width,
                         items: items, highlighted: -1)

proc performMenuAction(app: App, index: int) =
  if index < 0 or index >= app.menuActions.len: return
  case app.menuActions[index]
  of maCut: app.copySelection(true)
  of maCopy: app.copySelection(false)
  of maPaste: app.pasteClipboard()
  of maSelectAll: app.editor.selectAll()
  of maBold: app.editor.applyRequest(EditorRequest(kind: erApplyBold))
  of maItalic: app.editor.applyRequest(EditorRequest(kind: erApplyItalic))
  of maHighlight: app.editor.applyRequest(EditorRequest(kind: erApplyHighlight))
  of maStrikethrough:
    app.editor.applyRequest(EditorRequest(kind: erApplyStrikethrough))
  of maInlineCode: app.editor.applyRequest(EditorRequest(kind: erApplyInlineCode))
  of maLink:
    app.editor.applyRequest(EditorRequest(kind: erApplyLink, text: "https://"))
  of maCodeBlock: app.editor.applyRequest(EditorRequest(kind: erApplyCodeBlock))
  of maQuote: app.editor.applyRequest(EditorRequest(kind: erApplyBlockquote))
  of maBullet: app.editor.applyRequest(EditorRequest(kind: erApplyUnorderedList))
  of maNumbered: app.editor.applyRequest(EditorRequest(kind: erApplyOrderedList))
  of maRule: app.editor.applyRequest(EditorRequest(kind: erApplyHorizontalRule))
  of maUndo: app.editor.undo()
  of maRedo: app.editor.redo()

# ---------------------------------------------------------------------------
# Toolbar actions
# ---------------------------------------------------------------------------

proc loadSample(app: App, index: int) =
  let samples = sampleDocuments()
  app.sampleIndex = index mod samples.len
  app.editor.setDocument(samples[app.sampleIndex].text)
  app.header.title = samples[app.sampleIndex].name
  app.header.subtitle = "MarkdownEngine demo · " &
                        $app.fonts.availableFamilies().len & " font families"
  app.editor.needsRedraw = true

proc performToolbarAction(app: App, action: ToolbarAction) =
  case action
  of taBold: app.editor.applyRequest(EditorRequest(kind: erApplyBold))
  of taItalic: app.editor.applyRequest(EditorRequest(kind: erApplyItalic))
  of taHighlight: app.editor.applyRequest(EditorRequest(kind: erApplyHighlight))
  of taStrike: app.editor.applyRequest(EditorRequest(kind: erApplyStrikethrough))
  of taCode: app.editor.applyRequest(EditorRequest(kind: erApplyInlineCode))
  of taH1: app.editor.applyRequest(EditorRequest(kind: erApplyHeading, level: 1))
  of taH2: app.editor.applyRequest(EditorRequest(kind: erApplyHeading, level: 2))
  of taQuote: app.editor.applyRequest(EditorRequest(kind: erApplyBlockquote))
  of taBullet: app.editor.applyRequest(EditorRequest(kind: erApplyUnorderedList))
  of taNumbered: app.editor.applyRequest(EditorRequest(kind: erApplyOrderedList))
  of taRule: app.editor.applyRequest(EditorRequest(kind: erApplyHorizontalRule))
  of taCodeBlock: app.editor.applyRequest(EditorRequest(kind: erApplyCodeBlock))
  of taLink:
    app.editor.applyRequest(EditorRequest(kind: erApplyLink, text: "https://"))
  of taFind:
    app.findBar.visible = not app.findBar.visible
    app.findFocused = app.findBar.visible
    if not app.findBar.visible: app.editor.clearFind()
    app.applyLayout()
  of taTheme:
    app.appearance = if app.appearance == apLight: apDark else: apLight
    app.painter.appearance = app.appearance
    app.editor.appearance = app.appearance
    app.editor.rebuildAndStyle()
    app.showStatus(if app.appearance == apDark: "Dark appearance" else: "Light appearance")
  of taReadingWidth:
    app.config.hasReadingWidth = not app.config.hasReadingWidth
    app.config.readingWidth = 680.0
    app.editor.config = app.config
    app.editor.layout.invalidate()
    app.editor.rebuildAndStyle()
    app.applyLayout()
    app.showStatus(if app.config.hasReadingWidth: "Reading column on"
                   else: "Reading column off")
  of taRawSource:
    app.config.rawSourceMode = not app.config.rawSourceMode
    app.editor.config = app.config
    app.editor.rebuildAndStyle()
    app.showStatus(if app.config.rawSourceMode: "Raw source mode"
                   else: "Styled mode")
  of taSample:
    app.loadSample(app.sampleIndex + 1)
  app.layoutToolbar()

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

proc findBarKey(app: App, keycode: uint32, modifiers: uint16, text: string): bool =
  ## Route a keystroke to the find bar when it has focus. `true` = consumed.
  if not app.findBar.visible or not app.findFocused: return false
  let shift = (modifiers and KMOD_SHIFT) != 0
  case keycode
  of SDLK_ESCAPE:
    app.findBar.visible = false
    app.findFocused = false
    app.editor.clearFind()
    app.applyLayout()
    return true
  of SDLK_TAB:
    app.findBar.focusReplace = not app.findBar.focusReplace
    return true
  of SDLK_RETURN, SDLK_KP_ENTER:
    if app.findBar.focusReplace:
      app.editor.replaceCurrentMatch(app.findBar.replacement)
    elif shift:
      app.editor.findPrevious()
    else:
      app.editor.findNext()
    return true
  of SDLK_BACKSPACE:
    if app.findBar.focusReplace:
      if app.findBar.replacement.len > 0:
        app.findBar.replacement.setLen(app.findBar.replacement.len - 1)
    else:
      if app.findBar.query.len > 0:
        # Drop a whole UTF-8 scalar, not a byte.
        var cut = app.findBar.query.len - 1
        while cut > 0 and (uint8(app.findBar.query[cut]) and 0xC0'u8) == 0x80'u8:
          dec cut
        app.findBar.query.setLen(cut)
        app.editor.runFind(app.findBar.query)
    return true
  else:
    if text.len > 0:
      if app.findBar.focusReplace: app.findBar.replacement.add text
      else:
        app.findBar.query.add text
        app.editor.runFind(app.findBar.query)
      return true
  false

proc handleKey(app: App, keycode: uint32, modifiers: uint16) =
  let ctrl = (modifiers and KMOD_CTRL) != 0 or (modifiers and KMOD_GUI) != 0
  let shift = (modifiers and KMOD_SHIFT) != 0
  let alt = (modifiers and KMOD_ALT) != 0

  if app.menu.visible:
    if keycode == SDLK_ESCAPE:
      app.menu.visible = false
      app.editor.needsRedraw = true
      return

  if app.findBarKey(keycode, modifiers, ""): return

  # The completion picker takes the arrow keys, Return and Escape while it is
  # open — the engine routes them through `onInlinePreviewKey` for exactly this.
  if app.editor.hasCompletionContext and app.editor.completionCandidateCount() > 0:
    case keycode
    of SDLK_DOWN:
      app.editor.moveCompletionSelection(1)
      return
    of SDLK_UP:
      app.editor.moveCompletionSelection(-1)
      return
    of SDLK_RETURN, SDLK_KP_ENTER, SDLK_TAB:
      if app.editor.commitCompletion(): return
    of SDLK_ESCAPE:
      app.editor.hasCompletionContext = false
      app.editor.needsRedraw = true
      return
    else: discard

  if ctrl:
    case keycode
    of SDLK_B: app.editor.applyRequest(EditorRequest(kind: erApplyBold)); return
    of SDLK_I: app.editor.applyRequest(EditorRequest(kind: erApplyItalic)); return
    of SDLK_E: app.editor.applyRequest(EditorRequest(kind: erApplyInlineCode)); return
    of SDLK_K: app.editor.applyRequest(EditorRequest(kind: erApplyLink, text: "https://")); return
    of SDLK_A: app.editor.selectAll(); return
    of SDLK_C: app.copySelection(false); return
    of SDLK_X: app.copySelection(true); return
    of SDLK_V: app.pasteClipboard(); return
    of SDLK_Z:
      if shift: app.editor.redo() else: app.editor.undo()
      return
    of SDLK_Y: app.editor.redo(); return
    of SDLK_F:
      app.findBar.visible = true
      app.findFocused = true
      app.findBar.focusReplace = false
      app.applyLayout()
      return
    of SDLK_G:
      if shift: app.editor.findPrevious() else: app.editor.findNext()
      return
    of SDLK_HOME: app.editor.moveCaret(mvDocStart, shift); return
    of SDLK_END: app.editor.moveCaret(mvDocEnd, shift); return
    of SDLK_LEFT: app.editor.moveCaret(mvWordLeft, shift); return
    of SDLK_RIGHT: app.editor.moveCaret(mvWordRight, shift); return
    of SDLK_BACKSPACE: app.editor.deleteWordBackward(); return
    of SDLK_1 .. SDLK_6:
      app.editor.applyRequest(EditorRequest(kind: erApplyHeading,
                                            level: int(keycode - SDLK_1) + 1))
      return
    else: discard

  case keycode
  of SDLK_LEFT:
    app.editor.moveCaret(if alt: mvWordLeft else: mvLeft, shift)
  of SDLK_RIGHT:
    app.editor.moveCaret(if alt: mvWordRight else: mvRight, shift)
  of SDLK_UP: app.editor.moveCaret(mvUp, shift)
  of SDLK_DOWN: app.editor.moveCaret(mvDown, shift)
  of SDLK_HOME: app.editor.moveCaret(mvLineStart, shift)
  of SDLK_END: app.editor.moveCaret(mvLineEnd, shift)
  of SDLK_PAGEUP: app.editor.moveCaret(mvPageUp, shift)
  of SDLK_PAGEDOWN: app.editor.moveCaret(mvPageDown, shift)
  of SDLK_BACKSPACE: app.editor.deleteBackward()
  of SDLK_DELETE: app.editor.deleteForward()
  of SDLK_RETURN, SDLK_KP_ENTER: app.editor.insertText("\n")
  of SDLK_TAB: app.editor.insertText("\t")
  of SDLK_ESCAPE:
    if app.editor.findMatches.len > 0: app.editor.clearFind()
  else: discard

proc handleTextInput(app: App, text: string) =
  if app.findBar.visible and app.findFocused:
    discard app.findBarKey(0, 0, text)
    return
  app.editor.insertText(text)

# ---------------------------------------------------------------------------
# Mouse
# ---------------------------------------------------------------------------

proc setCursor(app: App, which: int) =
  if app.currentCursor == which: return
  app.currentCursor = which
  let cursor = case which
               of 1: app.ibeamCursor
               of 2: app.handCursor
               else: app.arrowCursor
  if cursor != nil: discard setCursor(cursor)

proc updateHoverCursor(app: App, x, y: float) =
  let frame = app.editorFrame()
  if y < frame.y or app.menu.visible:
    app.setCursor(0)
    return
  if app.scroller.visible and app.scroller.track.contains(x, y):
    app.setCursor(0)
    return
  let (_, _, found) = app.editor.linkAt(x, y)
  if found:
    app.setCursor(2)
    return
  let (_, isCheckbox) = app.editor.checkboxAt(x, y)
  app.setCursor(if isCheckbox: 0 else: 1)

proc handleMouseDown(app: App, x, y: float, button: uint8, clicks: int) =
  if app.menu.visible:
    let index = app.menu.menuItemAt(x, y)
    app.menu.visible = false
    app.editor.needsRedraw = true
    if index >= 0: app.performMenuAction(index)
    return

  if button == 3:
    app.buildContextMenu(x, y)
    app.editor.needsRedraw = true
    return

  # Toolbar.
  if y < app.toolbarHeight:
    for b in app.toolbar:
      if b.rect.contains(x, y):
        app.performToolbarAction(ToolbarAction(b.id))
        return
    return

  # Find bar.
  if app.findBar.visible and app.findBar.rect.contains(x, y):
    app.findFocused = true
    let halfWidth = max(120.0, (app.findBar.rect.w - 220.0) * 0.5)
    app.findBar.focusReplace = x > app.findBar.rect.x + 12.0 + halfWidth
    app.editor.needsRedraw = true
    return

  # Scroller.
  if app.scroller.visible and app.scroller.track.contains(x, y):
    if app.scroller.knob.contains(x, y):
      app.scroller.dragging = true
      app.scroller.dragOffset = y - app.scroller.knob.y
    else:
      app.editor.scrollTo(app.scroller.scrollForKnobY(
        y - app.scroller.knob.h * 0.5, app.editor.totalContentHeight(),
        app.editor.viewport.h))
    return

  app.findFocused = false

  # A checkbox click toggles instead of moving the caret, so the box behaves
  # like a control rather than like text.
  let (boxRange, isCheckbox) = app.editor.checkboxAt(x, y)
  if isCheckbox:
    app.editor.toggleCheckbox(boxRange)
    return

  # A modifier-free click on a link follows it; a plain click elsewhere places
  # the caret.
  let (target, isWiki, hasLink) = app.editor.linkAt(x, y)
  let modifiers = getModState()
  if hasLink and (modifiers and KMOD_CTRL) == 0 and clicks == 1:
    if app.editor.hooks.linkActivated != nil:
      app.editor.hooks.linkActivated(target, isWiki)
    return

  let shift = (modifiers and KMOD_SHIFT) != 0
  app.drag = app.editor.beginDrag(x, y, clicks, shift)
  app.dragging = true

proc handleMouseMotion(app: App, x, y: float) =
  app.lastMouse = (x, y)
  if app.menu.visible:
    let index = app.menu.menuItemAt(x, y)
    if index != app.menu.highlighted:
      app.menu.highlighted = index
      app.editor.needsRedraw = true
    return
  if app.scroller.dragging:
    app.editor.scrollTo(app.scroller.scrollForKnobY(
      y - app.scroller.dragOffset, app.editor.totalContentHeight(),
      app.editor.viewport.h))
    return
  if app.dragging:
    app.editor.continueDrag(app.drag, x, y)
    return

  var hovered = -1
  for index, b in app.toolbar:
    if b.rect.contains(x, y): hovered = index
  if hovered != app.hoveredButton:
    app.hoveredButton = hovered
    app.editor.needsRedraw = true
  let wasHovered = app.scrollerHovered
  app.scrollerHovered = app.scroller.visible and
                        x > app.scroller.track.x - 12.0
  if wasHovered != app.scrollerHovered: app.editor.needsRedraw = true
  app.updateHoverCursor(x, y)

proc handleMouseUp(app: App) =
  app.dragging = false
  app.drag.active = false
  app.scroller.dragging = false

proc handleWheel(app: App, deltaX, deltaY: float, mouseX, mouseY: float) =
  ## A wheel over a WIDE table scrolls the table horizontally, which is how the
  ## original's breakout overlay behaved; anywhere else it scrolls the document.
  app.editor.ensureLayout()
  if abs(deltaX) > abs(deltaY):
    let (_, docY) = app.editor.documentPoint(mouseX, mouseY)
    for line in app.editor.layout.visibleLines(docY - 1.0, docY + 1.0):
      for item in line.items:
        if not item.attributes.has(akScrollableBlockSourceID): continue
        let sourceID = item.attributes.intOf(akScrollableBlockSourceID, 0)
        let natural = item.attributes.floatOf(akScrollableBlockNaturalWidth,
                                              app.editor.textColumnWidth())
        let travel = max(0.0, natural - app.editor.textColumnWidth())
        let current = app.editor.tableOffsets.getOrDefault(sourceID, 0.0)
        app.editor.tableOffsets[sourceID] = clamp(current - deltaX * 24.0,
                                                  0.0, travel)
        app.editor.needsRedraw = true
        return
  app.editor.scrollBy(-deltaY * 54.0)

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

proc drawToolbar(app: App) =
  app.painter.fillRect(0.0, 0.0, app.width, app.toolbarHeight,
                       app.config.theme.chromeBackground)
  app.painter.hLine(0.0, app.toolbarHeight - 1.0, app.width,
                    app.painter.resolve(app.config.theme.chromeBorder))
  let desc = app.chromeFont()
  for index, b in app.toolbar:
    app.painter.drawButton(app.atlas, app.fonts, b, app.config.theme, desc,
                           index == app.hoveredButton)

  # A right-aligned status line: the hovered button's tooltip, a transient
  # message, or the document's size.
  var status = ""
  if app.statusMessage.len > 0 and epochTime() < app.statusUntil:
    status = app.statusMessage
  elif app.hoveredButton >= 0 and app.hoveredButton < app.toolbar.len:
    status = app.toolbar[app.hoveredButton].tooltip
  else:
    status = $app.editor.storage.len & " chars · " &
             $app.editor.layout.lines.len & " lines"
  let width = app.fonts.measureString(status, desc)
  app.painter.drawTextCentered(app.atlas, app.fonts, status,
                               rect(app.width - width - 14.0, 0.0, width,
                                    app.toolbarHeight),
                               desc,
                               app.painter.resolve(
                                 withAlpha(app.config.theme.chromeText, 0.55)))

proc drawCompletionPicker(app: App) =
  if not app.editor.hasCompletionContext: return
  let ctx = app.editor.completionContext
  if ctx.candidates.len == 0: return
  var titles: seq[string] = @[]
  var subtitles: seq[string] = @[]
  for candidate in ctx.candidates:
    titles.add candidate.title
    subtitles.add candidate.subtitle
  # Anchored to the caret rect the engine reports, which is what
  # `onCaretRectChange` was for.
  app.editor.ensureLayout()
  let caret = app.editor.layout.caretRect(ctx.replacementRange.location)
  let x = caret.x + app.editor.viewport.x
  var y = caret.y - app.editor.scrollY + app.editor.viewport.y + caret.h + 2.0
  let rows = min(titles.len, 8)
  let height = float(rows) * 32.0 + 8.0
  if y + height > app.height:
    y = max(0.0, caret.y - app.editor.scrollY + app.editor.viewport.y - height - 2.0)
  app.painter.drawCompletionPicker(app.atlas, app.fonts, titles, subtitles,
                                   app.editor.completionIndex, x, y,
                                   app.config.theme, app.chromeFont(),
                                   app.chromeSmallFont())

proc drawFrame(app: App) =
  app.editor.ensureLayout()
  app.painter.setColor(app.config.theme.editorBackground)
  discard renderClear(app.renderer)

  let frame = app.editorFrame()
  app.painter.withClip(frame.x, frame.y, frame.w, frame.h):
    var ctx = RenderContext(
      painter: app.painter, atlas: app.atlas, fonts: app.fonts,
      images: app.images, layout: app.editor.layout,
      storage: app.editor.storage, config: app.config,
      widths: app.editor.widths, baseFont: app.editor.baseFont,
      scrollY: app.editor.scrollY, viewportTop: frame.y,
      viewportHeight: frame.h, viewX: app.editor.textColumnX(),
      viewY: frame.y + app.editor.contentInsets.y,
      containerWidth: app.editor.textColumnWidth(),
      selection: app.editor.selection, hasFocus: app.editor.hasFocus,
      caretVisible: app.editor.caretOn,
      findMatches: app.editor.findMatches,
      currentMatch: app.editor.currentMatch,
      tableOffsets: app.editor.tableOffsets)
    ctx.drawDocument()

  # The header band draws over the top of the scrolled content, so the text
  # slides under it as it collapses.
  if app.header.bandHeight > 0:
    app.painter.drawScrollingHeader(app.atlas, app.fonts, app.header,
                                    0.0, frame.y, app.width,
                                    app.editor.scrollY, app.config.theme,
                                    initFont("sans", 22.0),
                                    app.chromeFont())

  app.scroller.layoutScroller(frame.x, frame.y, frame.w, frame.h,
                              app.editor.totalContentHeight(),
                              app.editor.scrollY,
                              app.config.scrollers.autohidesScrollers)
  app.painter.drawScroller(app.scroller, app.config.theme, app.scrollerHovered)

  app.drawToolbar()
  app.findBar.matchCount = app.editor.findMatches.len
  app.findBar.currentMatch = app.editor.currentMatch
  app.painter.drawFindBar(app.atlas, app.fonts, app.findBar, app.config.theme,
                          app.chromeFont(), app.editor.caretOn)
  app.drawCompletionPicker()
  app.painter.drawContextMenu(app.atlas, app.fonts, app.menu, app.config.theme,
                              app.chromeFont())
  discard renderPresent(app.renderer)
  app.editor.needsRedraw = false

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc newApp*(width = 1100, height = 760, headless = false): App =
  discard setAppMetadata("MarkdownEngine", "0.14.0",
                         "dev.markdownengine.demo")
  if not init(INIT_VIDEO):
    raise newException(IOError, "could not initialize SDL: " & $getError())

  var window: Window
  var renderer: Renderer
  if not createWindowAndRenderer(windowTitle, cint(width), cint(height),
                                 WINDOW_RESIZABLE or WINDOW_HIGH_PIXEL_DENSITY,
                                 window, renderer):
    raise newException(IOError, "could not create window: " & $getError())
  discard setRenderVSync(renderer, 1)
  # Without this every `a` the theme carries is ignored and a 6%-opaque button
  # fill paints solid black. SDL's default is `BLENDMODE_NONE`.
  discard setRenderDrawBlendMode(renderer, BLENDMODE_BLEND)

  let fonts = newFontManager()
  if fonts.availableFamilies().len == 0:
    raise newException(IOError,
      "no usable TrueType fonts found — install DejaVu or Liberation fonts")

  var config = initConfiguration(
    extensions = @[newHighlightExtension(), newStrikethroughExtension(),
                   newContainerExtension()],
    directives = demoDirectives())
  let images = newImageStore(renderer)
  config.services = initServices(
    wikiLinks = makeWikiResolver(),
    images = makeImageProvider(images),
    syntaxHighlighter = makeHighlighter(fonts, config))

  let scale = getWindowDisplayScale(window)
  result = App(
    window: window, renderer: renderer, fonts: fonts,
    atlas: newGlyphAtlas(renderer, fonts),
    painter: newPainter(renderer, apLight, if scale > 0: float(scale) else: 1.0),
    images: images, config: config, width: float(width), height: float(height),
    pixelScale: if scale > 0: float(scale) else: 1.0, running: true,
    appearance: apLight, toolbarHeight: 36.0, toolbar: @[], hoveredButton: -1,
    findBar: FindBar(visible: false), findFocused: false,
    menu: ContextMenu(visible: false), menuActions: @[],
    header: ScrollingHeader(title: "Welcome", subtitle: "",
                            bandHeight: 64.0, collapsedHeight: 30.0),
    drag: DragState(), dragging: false, lastMouse: (0.0, 0.0),
    clickCount: 0, sampleIndex: 0, statusMessage: "", statusUntil: 0,
    currentCursor: -1)
  result.editor = newEditor(fonts, config, "demo")
  result.editor.appearance = apLight

  result.ibeamCursor = createSystemCursor(SYSTEM_CURSOR_TEXT)
  result.arrowCursor = createSystemCursor(SYSTEM_CURSOR_DEFAULT)
  result.handCursor = createSystemCursor(SYSTEM_CURSOR_POINTER)

  let app = result
  result.editor.hooks = EditorHooks(
    linkActivated: proc (target: string, isWikiLink: bool) {.closure.} =
      {.cast(gcsafe).}:
        app.showStatus((if isWikiLink: "Wiki link: " else: "Link: ") & target),
    findResults: proc (count, current: int) {.closure.} =
      {.cast(gcsafe).}:
        app.findBar.matchCount = count
        app.findBar.currentMatch = current)

  if not headless:
    discard startTextInput(window)
  result.loadSample(0)
  result.applyLayout()

proc pumpEvents(app: App) =
  var event: Event
  while pollEvent(event):
    case event.type
    of EVENT_QUIT:
      app.running = false
    of EVENT_WINDOW_RESIZED, EVENT_WINDOW_PIXEL_SIZE_CHANGED:
      var w, h: cint
      if getWindowSize(app.window, w, h):
        app.width = float(w)
        app.height = float(h)
      let scale = getWindowDisplayScale(app.window)
      if scale > 0:
        app.pixelScale = float(scale)
        app.painter.scale = float(scale)
      app.applyLayout()
      app.editor.needsRedraw = true
    of EVENT_WINDOW_FOCUS_GAINED:
      app.editor.hasFocus = true
      app.editor.needsRedraw = true
    of EVENT_WINDOW_FOCUS_LOST:
      app.editor.hasFocus = false
      app.editor.needsRedraw = true
    of EVENT_KEY_DOWN:
      app.handleKey(event.key.key, event.key.mod)
    of EVENT_TEXT_INPUT:
      if event.text.text != nil:
        app.handleTextInput($event.text.text)
    of EVENT_MOUSE_BUTTON_DOWN:
      app.handleMouseDown(float(event.button.x), float(event.button.y),
                          event.button.button, int(event.button.clicks))
    of EVENT_MOUSE_BUTTON_UP:
      app.handleMouseUp()
    of EVENT_MOUSE_MOTION:
      app.handleMouseMotion(float(event.motion.x), float(event.motion.y))
    of EVENT_MOUSE_WHEEL:
      app.handleWheel(float(event.wheel.x), float(event.wheel.y),
                      float(event.wheel.mouse_x), float(event.wheel.mouse_y))
    else:
      discard

proc run*(app: App) =
  var lastFrame = epochTime()
  while app.running:
    app.pumpEvents()
    let now = epochTime()
    let dt = min(0.1, now - lastFrame)
    lastFrame = now
    app.editor.tick(now)
    if app.dragging:
      # The drag-select autoscroll boost: keep scrolling while the pointer is
      # held against an edge.
      app.editor.dragAutoscroll(app.lastMouse.y, dt)
      app.editor.continueDrag(app.drag, app.lastMouse.x, app.lastMouse.y)
    if app.statusMessage.len > 0 and now >= app.statusUntil:
      app.statusMessage = ""
      app.editor.needsRedraw = true
    app.drawFrame()

proc shutdown*(app: App) =
  app.atlas.destroy()
  app.images.destroy()
  if app.ibeamCursor != nil: destroyCursor(app.ibeamCursor)
  if app.arrowCursor != nil: destroyCursor(app.arrowCursor)
  if app.handCursor != nil: destroyCursor(app.handCursor)
  if app.renderer != nil: destroyRenderer(app.renderer)
  if app.window != nil: destroyWindow(app.window)
  sdlbridge.quit()

proc editorRef*(app: App): Editor = app.editor
  ## The editor behind the window, for tests and host integrations.

proc openDocument*(app: App, path: string) =
  ## Load a markdown file from disk, in STORAGE form — so a document holding
  ## `[[Name|<id>]]` shows `[[Name]]` and saves back with the id intact.
  try:
    app.editor.setDocument(readFile(path))
    app.header.title = extractFilename(path)
    app.header.subtitle = path
    discard setWindowTitle(app.window,
                           (extractFilename(path) & " — " & windowTitle).cstring)
    app.showStatus("Opened " & extractFilename(path))
  except IOError, OSError:
    app.showStatus("Could not read " & path)

proc frameSummary*(app: App): string =
  ## What the headless smoke test prints, so a regression in any stage of the
  ## pipeline shows up as a changed number rather than a silent blank frame.
  app.editor.ensureLayout()
  var glyphRuns = 0
  for line in app.editor.layout.lines:
    glyphRuns += line.items.len
  $app.editor.storage.len & " chars, " &
    $app.editor.storage.runs.len & " attribute runs, " &
    $app.editor.layout.lines.len & " lines, " &
    $glyphRuns & " laid-out glyphs, " &
    $app.editor.tokens.len & " tokens, " &
    $app.atlas.uploadCount & " glyph uploads, content height " &
    formatFloat(app.editor.layout.contentHeight, ffDecimal, 1)

proc renderOnce*(app: App) =
  ## One frame, for the headless smoke test: it proves the whole pipeline
  ## (parse → style → layout → rasterize → draw) runs without a display.
  app.drawFrame()

proc captureTo*(app: App, path: string): bool =
  ## Draw a frame and write it out. A frame that draws nothing still
  ## "succeeds", so looking at the pixels is the only honest check.
  app.drawFrame()
  captureFrame(app.renderer, path)

proc scrollToFraction*(app: App, fraction: float) =
  ## Jump to a point in the document, so a capture run can photograph more
  ## than the first screen.
  app.editor.ensureLayout()
  app.editor.scrollTo(app.editor.maxScroll() * clamp(fraction, 0.0, 1.0))

proc setAppearance*(app: App, appearance: Appearance) =
  app.appearance = appearance
  app.painter.appearance = appearance
  app.editor.appearance = appearance
  app.editor.rebuildAndStyle()
  app.layoutToolbar()

proc selectRange*(app: App, r: Range) =
  app.editor.setSelection(r)

proc loadSampleIndex*(app: App, index: int) =
  app.loadSample(index)

proc toggleFindBar*(app: App, query: string) =
  app.findBar.visible = true
  app.findBar.query = query
  app.findFocused = true
  app.applyLayout()
  app.editor.runFind(query)
