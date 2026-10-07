## theme.nim
## MarkdownEngine (Nim port)
##
## Color palette consumed by the editor engine.
##
## Every color the engine puts on screen is read from here, so a single
## override is enough to retheme the whole editor. The defaults reproduce a
## system-native look using the dynamic system colors from `color.nim`, so
## light/dark switching keeps working without extra code.

import ./color

type
  MarkdownEditorTheme* = object
    # Text colors
    bodyText*: Color
      ## Plain body text and the typing caret.
    mutedText*: Color
      ## De-emphasized text and most syntax markers.
    disabledText*: Color
      ## Content to deemphasize further than `mutedText` — e.g. broken
      ## wiki-links.
    headingMarker*: Color
      ## Heading marker glyphs (`#`, `##`, …).

    # Links
    link*: Color
      ## Hyperlinks that resolve to a URL.
    incompleteLink*: Color
      ## Incomplete `[text]` patterns (no URL yet).

    # Find / search highlights
    findMatchHighlight*: Color
    findCurrentMatchHighlight*: Color

    # LaTeX
    latexLightModeText*: Color
    latexDarkModeText*: Color

    # Inline decorations
    strikethroughColor*: Color
    highlightColor*: Color

    # Surfaces the port needs explicitly: AppKit read these off the window,
    # SDL has no such ambient source, so they live in the theme.
    editorBackground*: Color
    selectionBackground*: Color
    caret*: Color
    blockquoteBar*: Color
    tableGrid*: Color
    tableHeaderBackground*: Color
    checkboxBorder*: Color
    checkboxFill*: Color
    checkboxGlyph*: Color
    scrollerKnob*: Color
    thematicBreakRule*: Color
    chromeBackground*: Color
    chromeBorder*: Color
    chromeText*: Color
    chromeAccent*: Color

func initTheme*(
    bodyText = labelColor,
    mutedText = secondaryLabelColor,
    disabledText = tertiaryLabelColor,
    headingMarker = grayColor,
    link = linkColor,
    incompleteLink = systemBlue,
    findMatchHighlight = systemYellow,
    findCurrentMatchHighlight = systemYellow,
    latexLightModeText = blackColor,
    latexDarkModeText = whiteColor,
    strikethroughColor = labelColor,
    highlightColor = withAlpha(systemOrange, 0.4),
    editorBackground = textBackgroundColor,
    selectionBackground = selectedTextBackgroundColor,
    caret = labelColor,
    blockquoteBar = quaternaryLabelColor,
    tableGrid = separatorColor,
    tableHeaderBackground = Color(light: Rgba(r: 0, g: 0, b: 0, a: 0.04),
                                  dark: Rgba(r: 1, g: 1, b: 1, a: 0.06)),
    checkboxBorder = secondaryLabelColor,
    checkboxFill = systemBlue,
    checkboxGlyph = whiteColor,
    scrollerKnob = Color(light: Rgba(r: 0, g: 0, b: 0, a: 0.28),
                         dark: Rgba(r: 1, g: 1, b: 1, a: 0.30)),
    thematicBreakRule = separatorColor,
    chromeBackground = windowBackgroundColor,
    chromeBorder = separatorColor,
    chromeText = labelColor,
    chromeAccent = systemBlue): MarkdownEditorTheme =
  MarkdownEditorTheme(
    bodyText: bodyText, mutedText: mutedText, disabledText: disabledText,
    headingMarker: headingMarker, link: link, incompleteLink: incompleteLink,
    findMatchHighlight: findMatchHighlight,
    findCurrentMatchHighlight: findCurrentMatchHighlight,
    latexLightModeText: latexLightModeText,
    latexDarkModeText: latexDarkModeText,
    strikethroughColor: strikethroughColor, highlightColor: highlightColor,
    editorBackground: editorBackground, selectionBackground: selectionBackground,
    caret: caret, blockquoteBar: blockquoteBar, tableGrid: tableGrid,
    tableHeaderBackground: tableHeaderBackground,
    checkboxBorder: checkboxBorder, checkboxFill: checkboxFill,
    checkboxGlyph: checkboxGlyph, scrollerKnob: scrollerKnob,
    thematicBreakRule: thematicBreakRule, chromeBackground: chromeBackground,
    chromeBorder: chromeBorder, chromeText: chromeText, chromeAccent: chromeAccent)

let defaultTheme* = initTheme()
  ## System-native palette. Also what the engine uses when no theme is supplied.

func latexTextColor*(theme: MarkdownEditorTheme, appearance: Appearance): Color =
  if appearance == apDark: theme.latexDarkModeText else: theme.latexLightModeText
