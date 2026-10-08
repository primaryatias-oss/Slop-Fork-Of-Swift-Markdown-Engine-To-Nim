## services.nim
## MarkdownEngine (Nim port)
##
## The engine's dependencies on the host app, as four service values with
## no-op defaults.
##
## The engine resolves wiki-links, syntax highlighting, LaTeX rendering, and
## embedded image lookup through these. Embedders supply the implementations;
## the engine never reaches into the host app for any of these concerns.
##
## **Invariant:** service callbacks are SYNCHRONOUS. If an embedder's
## implementation is slow, it caches; the engine never async-renders.
##
## Swift used protocols with defaulted requirements. Here each service is a ref
## object of proc fields, so an embedder constructs a value and overrides only
## what it needs — and a service left unset behaves exactly like the Swift
## no-op conformance.

import ./ranges, ./color, ./font, ./attributes, ./theme

# ---------------------------------------------------------------------------
# Wiki links
# ---------------------------------------------------------------------------

type
  WikiLinkResolution* = object
    ## The result of resolving a wiki-link.
    id*: string      ## stable identifier persisted in `[[Name|<id>]]`
    exists*: bool    ## whether the linked target currently exists

  WikiLinkResolver* = ref object
    ## Resolves a wiki-link's display name to a stable storage identifier.
    ##
    ## The engine stores wiki-links as `[[Name|<id>]]` and displays them as
    ## `[[Name]]`. The resolver maps a display name (and the range it occupies)
    ## to whatever stable identifier the embedder uses. The identifier is
    ## opaque to the engine.
    resolveProc*: proc (displayName: string, range: Range): (WikiLinkResolution, bool) {.closure, gcsafe.}
    nameForIDProc*: proc (id: string): (string, bool) {.closure, gcsafe.}
      ## The target's CURRENT display name for a stable id; `false` if unknown
      ## (the renderer then falls back to the stored label).
    fingerprintProc*: proc (): string {.closure, gcsafe.}
      ## Coarse fingerprint of the resolver's known targets. A different value
      ## triggers a wiki-link restyle, so a rename refreshes link
      ## clickability/display without waiting for the next keystroke.

proc newWikiLinkResolver*(
    resolveProc: proc (displayName: string, range: Range): (WikiLinkResolution, bool) {.closure, gcsafe.} = nil,
    nameForIDProc: proc (id: string): (string, bool) {.closure, gcsafe.} = nil,
    fingerprintProc: proc (): string {.closure, gcsafe.} = nil): WikiLinkResolver =
  WikiLinkResolver(resolveProc: resolveProc, nameForIDProc: nameForIDProc,
                   fingerprintProc: fingerprintProc)

proc resolve*(r: WikiLinkResolver, displayName: string,
              range: Range): (WikiLinkResolution, bool) =
  if r != nil and r.resolveProc != nil: r.resolveProc(displayName, range)
  else: (WikiLinkResolution(), false)

proc nameForID*(r: WikiLinkResolver, id: string): (string, bool) =
  if r != nil and r.nameForIDProc != nil: r.nameForIDProc(id) else: ("", false)

proc fingerprint*(r: WikiLinkResolver): string =
  if r != nil and r.fingerprintProc != nil: r.fingerprintProc() else: "0"

# ---------------------------------------------------------------------------
# Embedded images
# ---------------------------------------------------------------------------

type
  EmbeddedImageRequest* = object
    ## What the engine asks an image provider for.
    name*: string            ## display name (the part before any `|`)
    id*: string              ## explicit identifier from `![[name|id]]`
    hasID*: bool
    requestedWidth*: float   ## explicit width from `![[name|…|width]]`
    hasRequestedWidth*: bool

  EmbeddedImageProvider* = ref object
    ## Loads an image for an `![[…]]` embed or a `![](…)` link. The provider
    ## decides where the image actually lives (filesystem, remote, bundle).
    imageProc*: proc (request: EmbeddedImageRequest): (ImageHandle, bool) {.closure, gcsafe.}
    fingerprintProc*: proc (): string {.closure, gcsafe.}
      ## Returning a different value invalidates the engine's image cache.

proc newEmbeddedImageProvider*(
    imageProc: proc (request: EmbeddedImageRequest): (ImageHandle, bool) {.closure, gcsafe.} = nil,
    fingerprintProc: proc (): string {.closure, gcsafe.} = nil): EmbeddedImageProvider =
  EmbeddedImageProvider(imageProc: imageProc, fingerprintProc: fingerprintProc)

proc image*(p: EmbeddedImageProvider,
            request: EmbeddedImageRequest): (ImageHandle, bool) =
  if p != nil and p.imageProc != nil: p.imageProc(request)
  else: (ImageHandle(), false)

proc fingerprint*(p: EmbeddedImageProvider): string =
  if p != nil and p.fingerprintProc != nil: p.fingerprintProc() else: "0"

# ---------------------------------------------------------------------------
# Syntax highlighting
# ---------------------------------------------------------------------------

type
  HighlightRun* = object
    ## One coloured run of highlighted code, relative to the code string.
    range*: Range
    color*: Color

  SyntaxHighlighter* = ref object
    ## Provides code-block font, background colour, and syntax highlighting.
    codeFontProc*: proc (size: float): FontDesc {.closure, gcsafe.}
      ## Monospace font used for fenced code blocks at the requested size.
    backgroundColorProc*: proc (): Color {.closure, gcsafe.}
      ## Background colour used to fill code-block paragraphs. The engine also
      ## uses this colour to detect which fragments are code blocks when
      ## drawing custom backgrounds.
    highlightProc*: proc (code: string, language: string,
                          hasLanguage: bool): (seq[HighlightRun], bool) {.closure, gcsafe.}
      ## Highlight `code`. Return per-token foreground runs, or `false` when no
      ## highlighting is available for this language.

proc newSyntaxHighlighter*(
    codeFontProc: proc (size: float): FontDesc {.closure, gcsafe.} = nil,
    backgroundColorProc: proc (): Color {.closure, gcsafe.} = nil,
    highlightProc: proc (code: string, language: string,
                         hasLanguage: bool): (seq[HighlightRun], bool) {.closure, gcsafe.} = nil): SyntaxHighlighter =
  SyntaxHighlighter(codeFontProc: codeFontProc,
                    backgroundColorProc: backgroundColorProc,
                    highlightProc: highlightProc)

proc codeFont*(h: SyntaxHighlighter, size: float): FontDesc =
  ## The default supplies a basic monospace font, as
  ## `PlainTextSyntaxHighlighter` did.
  if h != nil and h.codeFontProc != nil: h.codeFontProc(size)
  else: monospacedSystemFont(size)

proc backgroundColor*(h: SyntaxHighlighter): Color =
  ## The default is a transparent background.
  if h != nil and h.backgroundColorProc != nil: h.backgroundColorProc()
  else: withAlpha(textBackgroundColor, 0.0)

proc highlight*(h: SyntaxHighlighter, code: string, language: string,
                hasLanguage: bool): (seq[HighlightRun], bool) =
  if h != nil and h.highlightProc != nil: h.highlightProc(code, language, hasLanguage)
  else: (@[], false)

# ---------------------------------------------------------------------------
# LaTeX
# ---------------------------------------------------------------------------

type
  LatexRenderMode* = enum
    ## The typesetting mode of a LaTeX formula, from its Markdown delimiters.
    lrInline    ## `$ … $`
    lrDisplay   ## `$$ … $$`

  LatexRenderResult* = object
    image*: ImageHandle
    width*: float
    height*: float
    baselineOffset*: float
      ## Distance from the image's bottom edge to its visual baseline. Used to
      ## align inline math with the surrounding text.

  LatexRenderer* = ref object
    ## Renders LaTeX formulas to images. The engine falls back to rendering the
    ## source text when no renderer is supplied.
    renderProc*: proc (latex: string, mode: LatexRenderMode, fontSize: float,
                       theme: MarkdownEditorTheme,
                       appearance: Appearance): (LatexRenderResult, bool) {.closure, gcsafe.}

proc newLatexRenderer*(
    renderProc: proc (latex: string, mode: LatexRenderMode, fontSize: float,
                      theme: MarkdownEditorTheme,
                      appearance: Appearance): (LatexRenderResult, bool) {.closure, gcsafe.} = nil): LatexRenderer =
  LatexRenderer(renderProc: renderProc)

proc render*(r: LatexRenderer, latex: string, mode: LatexRenderMode,
             fontSize: float, theme: MarkdownEditorTheme,
             appearance: Appearance): (LatexRenderResult, bool) =
  if r != nil and r.renderProc != nil:
    r.renderProc(latex, mode, fontSize, theme, appearance)
  else:
    (LatexRenderResult(), false)

# ---------------------------------------------------------------------------
# Event bus
# ---------------------------------------------------------------------------

type
  EditorRequestKind* = enum
    ## Formatting / find commands the host UI can send the editor, and the
    ## notifications the editor sends back. The Swift original routed these
    ## through `NotificationCenter` names; a single enum does the same job
    ## without an ambient broker.
    erApplyBold
    erApplyItalic
    erApplyHeading           ## payload: `level`
    erApplyHighlight
    erApplyStrikethrough
    erApplyInlineCode
    erApplyBlockquote
    erApplyUnorderedList
    erApplyOrderedList
    erApplyLink              ## payload: `text` (the URL)
    erApplyCodeBlock
    erApplyHorizontalRule
    erApplyImage             ## payload: `text` (the URL)
    erFindQuery              ## payload: `text`, `index`
    erFindClearHighlights
    erReplaceCurrent         ## payload: `text`, `replacement`, `index`
    erReplaceAll             ## payload: `text`, `replacement`

  EditorRequest* = object
    kind*: EditorRequestKind
    level*: int
    text*: string
    replacement*: string
    index*: int

  SelectionFlags* = object
    ## Posted by the editor after every selection change, so a host toolbar can
    ## reflect the caret's formatting state.
    isBold*: bool
    isItalic*: bool
    isHighlight*: bool

  EditorBus* = ref object
    ## Optional bridge letting the editor talk to surrounding UI without
    ## hard-coding any names of its own. Embedders that don't need cross-view
    ## commands simply leave the handlers nil.
    selectionDidChange*: proc (flags: SelectionFlags) {.closure, gcsafe.}
    findResults*: proc (count: int) {.closure, gcsafe.}
    directiveCompletionDidChange*: proc (hasContext: bool) {.closure, gcsafe.}

proc newEditorBus*(): EditorBus = EditorBus()

# ---------------------------------------------------------------------------
# Services container
# ---------------------------------------------------------------------------

type
  MarkdownEditorServices* = object
    ## Bundles every external service the engine needs. Held by
    ## `MarkdownEditorConfiguration.services`; the engine reads its
    ## dependencies exclusively from here.
    wikiLinks*: WikiLinkResolver
    images*: EmbeddedImageProvider
    syntaxHighlighter*: SyntaxHighlighter
    latex*: LatexRenderer
    bus*: EditorBus

proc initServices*(wikiLinks: WikiLinkResolver = nil,
                   images: EmbeddedImageProvider = nil,
                   syntaxHighlighter: SyntaxHighlighter = nil,
                   latex: LatexRenderer = nil,
                   bus: EditorBus = nil): MarkdownEditorServices =
  MarkdownEditorServices(wikiLinks: wikiLinks, images: images,
                         syntaxHighlighter: syntaxHighlighter, latex: latex,
                         bus: bus)

let defaultServices* = initServices()
