## configuration.nim
## MarkdownEngine (Nim port)
##
## Every spacing / sizing / behavior knob the engine has, grouped by concern —
## a struct of structs, passed by reference into the styler via the styling
## context. `theme` is its colour sub-field.

import ./utf16text, ./theme, ./extension, ./directive, ./services

# ---------------------------------------------------------------------------
# Markers
# ---------------------------------------------------------------------------

type
  MarkerStyle* = object
    hiddenMarkerFontSize*: float
      ## Font size used for "hidden" inline markers. Effectively invisible at
      ## normal zoom while keeping displayed-range == stored-range.
    inlineCodeMarkerAlpha*: float
      ## Alpha applied to inline-code's secondary marker colour.
    findMatchHighlightAlpha*: float
      ## Alpha applied to non-focused find matches. The focused match is drawn
      ## at full opacity.

func initMarkerStyle*(hiddenMarkerFontSize = 0.1, inlineCodeMarkerAlpha = 0.5,
                      findMatchHighlightAlpha = 0.65): MarkerStyle =
  MarkerStyle(hiddenMarkerFontSize: hiddenMarkerFontSize,
              inlineCodeMarkerAlpha: inlineCodeMarkerAlpha,
              findMatchHighlightAlpha: findMatchHighlightAlpha)

# ---------------------------------------------------------------------------
# Code blocks / inline code
# ---------------------------------------------------------------------------

type
  CodeBlockStyle* = object
    fontSizeScale*: float      ## code font size as a fraction of the base size
    paragraphSpacing*: float   ## vertical spacing above and below the block
    horizontalIndent*: float   ## left/right indent, so code clears the gutter

  InlineCodeStyle* = object
    fontSizeScale*: float      ## inline code reuses the block scale by default

func initCodeBlockStyle*(fontSizeScale = 0.85, paragraphSpacing = 2.0,
                         horizontalIndent = 12.0): CodeBlockStyle =
  CodeBlockStyle(fontSizeScale: fontSizeScale, paragraphSpacing: paragraphSpacing,
                 horizontalIndent: horizontalIndent)

func initInlineCodeStyle*(fontSizeScale = 0.85): InlineCodeStyle =
  InlineCodeStyle(fontSizeScale: fontSizeScale)

# ---------------------------------------------------------------------------
# Lists / task checkboxes
# ---------------------------------------------------------------------------

type
  ListStyle* = object
    helpersEnabled*: bool
      ## Master switch for list editing helpers (auto-continue, auto-indent,
      ## marker conversion). When false, lists are still RENDERED, but the
      ## typing-time conveniences are skipped — and a task item keeps its box.
    autoClosePairsEnabled*: bool
      ## Master switch for auto-closing `()`, `{}`, `[]` while typing.
    indentPerLevel*: float
      ## Indent one nesting level adds to the list item.
    maximumNestingLevel*: int
      ## Maximum nesting level reachable by pressing Tab inside a list.
    extraLineHeight*: float
      ## Extra line height added to give list items room.

  TaskCheckboxStyle* = object
    ## Symbol names used to draw task-list checkboxes (`- [ ]` / `- [x]`). A
    ## name that doesn't resolve falls back to the stock box at draw time, so a
    ## typo degrades to the default look instead of drawing nothing. Tint
    ## colours stay theme-driven.
    uncheckedSymbolName*: string
    checkedSymbolName*: string

func initListStyle*(helpersEnabled = true, autoClosePairsEnabled = true,
                    indentPerLevel = 27.5, maximumNestingLevel = 3,
                    extraLineHeight = 2.0): ListStyle =
  ListStyle(helpersEnabled: helpersEnabled,
            autoClosePairsEnabled: autoClosePairsEnabled,
            indentPerLevel: indentPerLevel,
            maximumNestingLevel: maximumNestingLevel,
            extraLineHeight: extraLineHeight)

func initTaskCheckboxStyle*(uncheckedSymbolName = "square",
                            checkedSymbolName = "checkmark.square.fill"): TaskCheckboxStyle =
  TaskCheckboxStyle(uncheckedSymbolName: uncheckedSymbolName,
                    checkedSymbolName: checkedSymbolName)

# ---------------------------------------------------------------------------
# Thematic breaks
# ---------------------------------------------------------------------------

type
  ThematicBreakMark* = object
    ## A centered mark and the size it draws at.
    ##
    ## `scale` is a multiple of the body font size, so a mark keeps its
    ## proportion when the reader changes the editor's font size. Above 1 the
    ## break's line grows to fit, rather than the mark overlapping the
    ## paragraphs around it.
    ##
    ## The mark is centered on its INK, not on its layout box. An asterisk is
    ## drawn high in its em — its optical center sits about a quarter of the
    ## font size above the lowercase center, and that gap grows with the size —
    ## so box-centering would let the mark drift toward the top of the line as
    ## it got bigger. Ink-centering holds it at the optical center of the break
    ## at any scale, in any font, with no per-font tuning.
    text*: string
    scale*: float

  ThematicBreakStyle* = object
    ## How each thematic-break marker draws.
    ##
    ## CommonMark gives `---`, `***` and `___` one meaning and one rendering —
    ## a horizontal rule. The marker character survives into this struct so an
    ## embedder can give one of the three a different look WITHOUT inventing
    ## syntax: a novel-style star divider on `***`, say, while `---` stays a
    ## rule. Every marker still parses as a thematic break and still exports as
    ## `<hr>`, so a document written this way reads correctly elsewhere.
    ##
    ## An absent mark (the default for all three) draws the full-width rule.
    ## The mark is presentation only: the source text is untouched, the caret
    ## still reveals the raw `***`, and copy, export and find all see the
    ## original characters.
    dashMark*: ThematicBreakMark
    hasDashMark*: bool
    asteriskMark*: ThematicBreakMark
    hasAsteriskMark*: bool
    underscoreMark*: ThematicBreakMark
    hasUnderscoreMark*: bool

func mark*(text: string, scale = 1.0): ThematicBreakMark {.inline.} =
  ThematicBreakMark(text: text, scale: max(0.01, scale))

func initThematicBreakStyle*(dashMark = ThematicBreakMark(), hasDashMark = false,
                             asteriskMark = ThematicBreakMark(), hasAsteriskMark = false,
                             underscoreMark = ThematicBreakMark(),
                             hasUnderscoreMark = false): ThematicBreakStyle =
  ThematicBreakStyle(dashMark: dashMark, hasDashMark: hasDashMark,
                     asteriskMark: asteriskMark, hasAsteriskMark: hasAsteriskMark,
                     underscoreMark: underscoreMark,
                     hasUnderscoreMark: hasUnderscoreMark)

func markForMarker*(s: ThematicBreakStyle, marker: uint16): (ThematicBreakMark, bool) =
  ## The mark configured for a marker character, or `false` to draw the rule.
  ## The parser has already proven the character is one of the three, so the
  ## fallthrough is unreachable in practice and draws the rule rather than
  ## guessing.
  case marker
  of chDash: (s.dashMark, s.hasDashMark)
  of chAsterisk: (s.asteriskMark, s.hasAsteriskMark)
  of chUnderscore: (s.underscoreMark, s.hasUnderscoreMark)
  else: (ThematicBreakMark(), false)

# ---------------------------------------------------------------------------
# Headings
# ---------------------------------------------------------------------------

type
  HeadingStyle* = object
    ## Per-level heading metrics. Defaults are loosely based on browser default
    ## heading sizes.
    fontMultipliers*: seq[float]   ## font-size multiplier per level (1…6)
    topSpacingEm*: seq[float]      ## top spacing in `em` units per level (1…6)

func initHeadingStyle*(fontMultipliers = @[2.0, 1.5, 1.17, 1.0, 0.83, 0.67],
                       topSpacingEm = @[0.35, 0.30, 0.25, 0.20, 0.15, 0.10]): HeadingStyle =
  HeadingStyle(fontMultipliers: fontMultipliers, topSpacingEm: topSpacingEm)

func fontMultiplier*(s: HeadingStyle, level: int): float =
  if s.fontMultipliers.len == 0: return 1.0
  s.fontMultipliers[max(1, min(level, s.fontMultipliers.len)) - 1]

func topSpacing*(s: HeadingStyle, level: int): float =
  if s.topSpacingEm.len == 0: return 0.0
  s.topSpacingEm[max(1, min(level, s.topSpacingEm.len)) - 1]

# ---------------------------------------------------------------------------
# Images / LaTeX / blockquote / links / paragraphs
# ---------------------------------------------------------------------------

type
  ImageEmbedStyle* = object
    minimumWidth*: float          ## minimum display width for an embed
    fallbackMaxWidth*: float      ## fallback when no container width is usable
    unreasonableMaxWidth*: float  ## sanity bound — wider containers are invalid
    paragraphSpacing*: float      ## spacing above/below the image paragraph
    imageGap*: float              ## gap between source line and rendered image

  BlockLatexStyle* = object
    paragraphSpacingBefore*: float
    paragraphSpacing*: float
    singleLetterPaddingBottom*: float
      ## Extra bottom padding for single-letter formulas, to avoid clipping.

  InlineLatexStyle* = object
    ## Reserved for future inline-LaTeX tuning; inline LaTeX inherits its font
    ## size from the surrounding heading context.
    reserved*: bool

  BlockquoteStyle* = object
    extraLineHeight*: float
      ## Extra height added to the default line height for blockquote lines.

  LinkStyle* = object
    activeLinkAlpha*: float
      ## Foreground alpha for the visible label of an ACTIVE markdown link.
    incompleteLinkAlpha*: float
      ## Foreground alpha for "incomplete" link content (`[text]`, no target).

  ParagraphSpacingStyle* = object
    spacingFactor*: float
      ## Extra paragraph spacing as a fraction of the default line height.
    lineHeightExtraSpacing*: float
      ## Extra height added to the default paragraph line height.

func initImageEmbedStyle*(minimumWidth = 50.0, fallbackMaxWidth = 650.0,
                          unreasonableMaxWidth = 1_000_000.0,
                          paragraphSpacing = 8.0, imageGap = 8.0): ImageEmbedStyle =
  ImageEmbedStyle(minimumWidth: minimumWidth, fallbackMaxWidth: fallbackMaxWidth,
                  unreasonableMaxWidth: unreasonableMaxWidth,
                  paragraphSpacing: paragraphSpacing, imageGap: imageGap)

func initBlockLatexStyle*(paragraphSpacingBefore = 16.0, paragraphSpacing = 20.0,
                          singleLetterPaddingBottom = 1.0): BlockLatexStyle =
  BlockLatexStyle(paragraphSpacingBefore: paragraphSpacingBefore,
                  paragraphSpacing: paragraphSpacing,
                  singleLetterPaddingBottom: singleLetterPaddingBottom)

func initBlockquoteStyle*(extraLineHeight = 0.0): BlockquoteStyle =
  BlockquoteStyle(extraLineHeight: extraLineHeight)

func initLinkStyle*(activeLinkAlpha = 0.55, incompleteLinkAlpha = 0.7): LinkStyle =
  LinkStyle(activeLinkAlpha: activeLinkAlpha, incompleteLinkAlpha: incompleteLinkAlpha)

func initParagraphSpacingStyle*(spacingFactor = 0.3,
                                lineHeightExtraSpacing = 2.0): ParagraphSpacingStyle =
  ParagraphSpacingStyle(spacingFactor: spacingFactor,
                        lineHeightExtraSpacing: lineHeightExtraSpacing)

# ---------------------------------------------------------------------------
# Scrolling / viewport policies
# ---------------------------------------------------------------------------

type
  OverscrollPolicy* = object
    ## The empty space below the last line, so typing at the bottom of a long
    ## document stays comfortable instead of pinning to the viewport edge.
    percent*: float                   ## desired overscroll as a viewport fraction
    maxPoints*: float
    minPoints*: float
    activationStartFraction*: float   ## viewport fraction where it starts ramping
    activationRangeFraction*: float   ## viewport fraction over which it ramps in

  DragSelectionPolicy* = object
    ## Tuning for the auto-scroll boost while dragging a selection past the
    ## visible viewport edges.
    movementThreshold*: float
    edgeTriggerDistance*: float
    scrollStepPerTick*: float
    ticksPerSecond*: float

  SafeAreaInsets* = object
    ## Reserves space on the scroll view for overlays (e.g. a translucent
    ## toolbar to scroll underneath).
    top*, leading*, trailing*, bottom*: float

  ScrollersPolicy* = object
    hasVerticalScroller*: bool
    hasHorizontalScroller*: bool
    autohidesScrollers*: bool

  TextInsets* = object
    horizontal*: float
    vertical*: float

  SpellCheckingPolicy* = object
    ## Initial state for the "Spelling and Grammar" toggles.
    continuousSpellChecking*: bool
    grammarChecking*: bool
    automaticSpellingCorrection*: bool
    automaticQuoteSubstitution*: bool

  HeightBehavior* = enum
    ## How the editor resolves its own height.
    hbScrolls
      ## The editor scrolls internally within the height it is given. The
      ## default.
    hbFitsContent
      ## The editor grows to fit its content and reports that height back, so
      ## an enclosing scroll view scrolls instead of a nested one. Internal
      ## scrolling and bottom-overscroll slack are disabled in this mode.

func initOverscrollPolicy*(percent = 0.5, maxPoints = 450.0, minPoints = 40.0,
                           activationStartFraction = 0.15,
                           activationRangeFraction = 0.85): OverscrollPolicy =
  OverscrollPolicy(percent: percent, maxPoints: maxPoints, minPoints: minPoints,
                   activationStartFraction: activationStartFraction,
                   activationRangeFraction: activationRangeFraction)

func initDragSelectionPolicy*(movementThreshold = 5.0, edgeTriggerDistance = 5.0,
                              scrollStepPerTick = 12.0,
                              ticksPerSecond = 60.0): DragSelectionPolicy =
  DragSelectionPolicy(movementThreshold: movementThreshold,
                      edgeTriggerDistance: edgeTriggerDistance,
                      scrollStepPerTick: scrollStepPerTick,
                      ticksPerSecond: ticksPerSecond)

func initSafeAreaInsets*(top = 0.0, leading = 0.0, trailing = 0.0,
                         bottom = 0.0): SafeAreaInsets =
  SafeAreaInsets(top: top, leading: leading, trailing: trailing, bottom: bottom)

func initScrollersPolicy*(hasVerticalScroller = true,
                          hasHorizontalScroller = false,
                          autohidesScrollers = true): ScrollersPolicy =
  ScrollersPolicy(hasVerticalScroller: hasVerticalScroller,
                  hasHorizontalScroller: hasHorizontalScroller,
                  autohidesScrollers: autohidesScrollers)

func initTextInsets*(horizontal = 0.0, vertical = 0.0): TextInsets =
  TextInsets(horizontal: horizontal, vertical: vertical)

func initSpellCheckingPolicy*(continuousSpellChecking = false,
                              grammarChecking = false,
                              automaticSpellingCorrection = false,
                              automaticQuoteSubstitution = false): SpellCheckingPolicy =
  SpellCheckingPolicy(continuousSpellChecking: continuousSpellChecking,
                      grammarChecking: grammarChecking,
                      automaticSpellingCorrection: automaticSpellingCorrection,
                      automaticQuoteSubstitution: automaticQuoteSubstitution)

func wantsVerticalScroller*(h: HeightBehavior, scrollers: ScrollersPolicy): bool =
  ## In `hbFitsContent` the editor never scrolls internally, so the vertical
  ## scroller is always hidden regardless of the policy.
  case h
  of hbFitsContent: false
  of hbScrolls: scrollers.hasVerticalScroller

# ---------------------------------------------------------------------------
# The configuration
# ---------------------------------------------------------------------------

type
  MarkdownEditorConfiguration* = object
    theme*: MarkdownEditorTheme
    services*: MarkdownEditorServices
    markers*: MarkerStyle
    codeBlock*: CodeBlockStyle
    inlineCode*: InlineCodeStyle
    lists*: ListStyle
    taskCheckbox*: TaskCheckboxStyle
    headings*: HeadingStyle
    imageEmbed*: ImageEmbedStyle
    blockLatex*: BlockLatexStyle
    inlineLatex*: InlineLatexStyle
    blockquote*: BlockquoteStyle
    thematicBreak*: ThematicBreakStyle
    link*: LinkStyle
    paragraph*: ParagraphSpacingStyle
    overscroll*: OverscrollPolicy
    dragSelection*: DragSelectionPolicy
    safeAreaInsets*: SafeAreaInsets
    scrollers*: ScrollersPolicy
    textInsets*: TextInsets
    readingWidth*: float
      ## Opt-in fixed-width centered column; 0 means full width.
    hasReadingWidth*: bool
    rendersTablesDuringLiveResize*: bool
    spellChecking*: SpellCheckingPolicy
    heightBehavior*: HeightBehavior
    rawSourceMode*: bool
      ## Show the markdown source verbatim: no marker shrink, no decoration.
    extensions*: seq[MarkdownExtension]
    cursorFollowsSpanInk*: bool
    directives*: seq[MarkdownDirective]
    directiveSettings*: DirectiveRegistrySettings
    fontName*: string
      ## Base font family key. Added by the port: AppKit read the font off the
      ## text view, which SDL has no equivalent of.
    fontSize*: float

proc initConfiguration*(
    theme = defaultTheme,
    services = defaultServices,
    markers = initMarkerStyle(),
    codeBlock = initCodeBlockStyle(),
    inlineCode = initInlineCodeStyle(),
    lists = initListStyle(),
    taskCheckbox = initTaskCheckboxStyle(),
    headings = initHeadingStyle(),
    imageEmbed = initImageEmbedStyle(),
    blockLatex = initBlockLatexStyle(),
    inlineLatex = InlineLatexStyle(),
    blockquote = initBlockquoteStyle(),
    thematicBreak = initThematicBreakStyle(),
    link = initLinkStyle(),
    paragraph = initParagraphSpacingStyle(),
    overscroll = initOverscrollPolicy(),
    dragSelection = initDragSelectionPolicy(),
    safeAreaInsets = initSafeAreaInsets(),
    scrollers = initScrollersPolicy(),
    textInsets = initTextInsets(),
    readingWidth = 0.0,
    hasReadingWidth = false,
    rendersTablesDuringLiveResize = true,
    spellChecking = initSpellCheckingPolicy(),
    heightBehavior = hbScrolls,
    rawSourceMode = false,
    extensions: seq[MarkdownExtension] = @[],
    cursorFollowsSpanInk = false,
    directives: seq[MarkdownDirective] = @[],
    directiveSettings = defaultDirectiveSettings,
    fontName = "sans",
    fontSize = 15.0): MarkdownEditorConfiguration =
  MarkdownEditorConfiguration(
    theme: theme, services: services, markers: markers, codeBlock: codeBlock,
    inlineCode: inlineCode, lists: lists, taskCheckbox: taskCheckbox,
    headings: headings, imageEmbed: imageEmbed, blockLatex: blockLatex,
    inlineLatex: inlineLatex, blockquote: blockquote,
    thematicBreak: thematicBreak, link: link, paragraph: paragraph,
    overscroll: overscroll, dragSelection: dragSelection,
    safeAreaInsets: safeAreaInsets, scrollers: scrollers, textInsets: textInsets,
    readingWidth: readingWidth, hasReadingWidth: hasReadingWidth,
    rendersTablesDuringLiveResize: rendersTablesDuringLiveResize,
    spellChecking: spellChecking, heightBehavior: heightBehavior,
    rawSourceMode: rawSourceMode, extensions: extensions,
    cursorFollowsSpanInk: cursorFollowsSpanInk, directives: directives,
    directiveSettings: directiveSettings, fontName: fontName, fontSize: fontSize)

proc defaultConfiguration*(): MarkdownEditorConfiguration =
  initConfiguration()

# ---------------------------------------------------------------------------
# Derived registries / lookups
# ---------------------------------------------------------------------------

proc directiveRegistry*(c: MarkdownEditorConfiguration): DirectiveRegistry =
  ## The parser-facing directive registry derived from `directives`.
  initDirectiveRegistry(c.directives, c.directiveSettings)

proc extensionRegistry*(c: MarkdownEditorConfiguration): ExtensionRegistry =
  ## The parser-facing registry derived from `extensions` and `directives`.
  initRegistry(c.extensions, c.directiveRegistry())

proc extensionByID*(c: MarkdownEditorConfiguration,
                    id: string): (MarkdownExtension, bool) =
  ## Styler-facing lookup: extension behaviour by id.
  for e in c.extensions:
    if e.id == id: return (e, true)
  (nil, false)

proc directiveByID*(c: MarkdownEditorConfiguration,
                    id: string): (MarkdownDirective, bool) =
  ## Styler-facing lookup: directive behaviour by id.
  for d in c.directives:
    if d.id == id: return (d, true)
  (nil, false)
