## widgets.nim
## MarkdownEngine (Nim port) — UI layer
##
## The chrome around the editor: a scroller, a toolbar of buttons, a find bar,
## a context menu, the directive-completion picker, and the scroll-away header
## band.
##
## The Swift app got all of this from AppKit and SwiftUI — `NSScrollView`'s
## scroller, an `NSMenu`, a hosted header view. SDL draws rectangles, so each
## one is built here from the same primitives the document renderer uses. They
## are deliberately plain: the point of the port is the editor, and chrome that
## competes for attention would be a distraction from it.

import std/[math, unicode]
import ../markdownengine/[color, font, theme]
import ./fontmanager, ./atlas, ./painter

type
  Rect* = object
    x*, y*, w*, h*: float

  Button* = object
    rect*: Rect
    label*: string
    tooltip*: string
    id*: int
    active*: bool
    enabled*: bool

  Scroller* = object
    ## A vertical overlay scroller, autohiding like the policy asks.
    track*: Rect
    knob*: Rect
    visible*: bool
    dragging*: bool
    dragOffset*: float

  MenuItem* = object
    title*: string
    id*: int
    enabled*: bool
    isSeparator*: bool

  ContextMenu* = object
    visible*: bool
    origin*: tuple[x, y: float]
    width*: float
    items*: seq[MenuItem]
    highlighted*: int

  FindBar* = object
    visible*: bool
    rect*: Rect
    query*: string
    replacement*: string
    focusReplace*: bool
    matchCount*: int
    currentMatch*: int

func rect*(x, y, w, h: float): Rect {.inline.} = Rect(x: x, y: y, w: w, h: h)

func contains*(r: Rect, x, y: float): bool {.inline.} =
  x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------

proc drawText*(painter: Painter, atlas: GlyphAtlas, fonts: FontManager,
               text: string, x, baselineY: float, desc: FontDesc, c: Rgba): float =
  ## Draw a string and return the pen's final x.
  var penX = x
  var previous = -1
  for rune in text.runes:
    let cp = int(rune)
    if cp == 0x0A: continue
    if previous >= 0: penX += fonts.kerningBetween(previous, cp, desc)
    let entry = atlas.entryFor(desc, cp)
    if entry.valid: atlas.drawGlyph(entry, penX, baselineY, c)
    penX += fonts.measureCodePoint(cp, desc)
    previous = cp
  penX

proc drawTextCentered*(painter: Painter, atlas: GlyphAtlas, fonts: FontManager,
                       text: string, r: Rect, desc: FontDesc, c: Rgba) =
  let width = fonts.measureString(text, desc)
  let m = fonts.metricsFor(desc)
  let baselineY = painter.snap(r.y + (r.h - (m.ascent + m.descent)) * 0.5 + m.ascent)
  discard painter.drawText(atlas, fonts, text,
                           painter.snap(r.x + (r.w - width) * 0.5), baselineY,
                           desc, c)

# ---------------------------------------------------------------------------
# Buttons
# ---------------------------------------------------------------------------

proc drawButton*(painter: Painter, atlas: GlyphAtlas, fonts: FontManager,
                 button: Button, theme: MarkdownEditorTheme, desc: FontDesc,
                 hovered: bool) =
  let fill =
    if not button.enabled: withAlpha(theme.chromeBorder, 0.25)
    elif button.active: theme.chromeAccent
    elif hovered: withAlpha(theme.chromeText, 0.12)
    else: withAlpha(theme.chromeText, 0.06)
  painter.fillRoundedRect(button.rect.x, button.rect.y, button.rect.w,
                          button.rect.h, 5.0, fill)
  let textColor =
    if not button.enabled: withAlpha(theme.chromeText, 0.35)
    elif button.active: whiteColor
    else: theme.chromeText
  painter.drawTextCentered(atlas, fonts, button.label, button.rect, desc,
                           painter.resolve(textColor))

# ---------------------------------------------------------------------------
# Scroller
# ---------------------------------------------------------------------------

proc layoutScroller*(scroller: var Scroller, viewX, viewY, viewW, viewH,
                     contentHeight, scrollY: float, autohide: bool) =
  const width = 11.0
  const inset = 2.0
  scroller.track = rect(viewX + viewW - width - inset, viewY + inset, width,
                        max(0.0, viewH - inset * 2))
  if contentHeight <= viewH + 0.5:
    scroller.visible = not autohide
    scroller.knob = rect(scroller.track.x, scroller.track.y, width,
                         scroller.track.h)
    return
  scroller.visible = true
  let visibleFraction = clamp(viewH / contentHeight, 0.0, 1.0)
  let knobHeight = max(28.0, scroller.track.h * visibleFraction)
  let travel = max(1.0, contentHeight - viewH)
  let progress = clamp(scrollY / travel, 0.0, 1.0)
  scroller.knob = rect(scroller.track.x,
                       scroller.track.y + (scroller.track.h - knobHeight) * progress,
                       width, knobHeight)

proc drawScroller*(painter: Painter, scroller: Scroller,
                   theme: MarkdownEditorTheme, hovered: bool) =
  if not scroller.visible: return
  if hovered or scroller.dragging:
    painter.fillRoundedRect(scroller.track.x, scroller.track.y,
                            scroller.track.w, scroller.track.h, 5.5,
                            withAlpha(theme.chromeText, 0.06))
  let knobColor = if scroller.dragging: theme.chromeText
                  elif hovered: withAlpha(theme.scrollerKnob, 0.55)
                  else: theme.scrollerKnob
  let inset = 2.0
  painter.fillRoundedRect(scroller.knob.x + inset, scroller.knob.y,
                          scroller.knob.w - inset * 2, scroller.knob.h,
                          (scroller.knob.w - inset * 2) * 0.5, knobColor)

proc scrollForKnobY*(scroller: Scroller, knobY, contentHeight,
                     viewH: float): float =
  ## Invert the knob's position back to a scroll offset.
  let travel = max(1.0, scroller.track.h - scroller.knob.h)
  let progress = clamp((knobY - scroller.track.y) / travel, 0.0, 1.0)
  progress * max(0.0, contentHeight - viewH)

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------

const
  menuRowHeight* = 24.0
  menuSeparatorHeight* = 9.0
  menuPaddingY* = 5.0
  menuPaddingX* = 12.0

proc menuHeight*(menu: ContextMenu): float =
  result = menuPaddingY * 2
  for item in menu.items:
    result += (if item.isSeparator: menuSeparatorHeight else: menuRowHeight)

proc menuItemAt*(menu: ContextMenu, x, y: float): int =
  ## Index of the item under the point, or -1.
  if not menu.visible: return -1
  if x < menu.origin.x or x > menu.origin.x + menu.width: return -1
  var cursor = menu.origin.y + menuPaddingY
  for index, item in menu.items:
    let height = if item.isSeparator: menuSeparatorHeight else: menuRowHeight
    if y >= cursor and y < cursor + height:
      return if item.isSeparator or not item.enabled: -1 else: index
    cursor += height
  -1

proc drawContextMenu*(painter: Painter, atlas: GlyphAtlas, fonts: FontManager,
                      menu: ContextMenu, theme: MarkdownEditorTheme,
                      desc: FontDesc) =
  if not menu.visible: return
  let height = menu.menuHeight()
  # A soft drop shadow, so the menu reads as floating above the document.
  painter.fillRoundedRect(menu.origin.x + 1.0, menu.origin.y + 2.0, menu.width,
                          height, 7.0, Rgba(r: 0, g: 0, b: 0, a: 0.18))
  painter.fillRoundedRect(menu.origin.x, menu.origin.y, menu.width, height, 7.0,
                          theme.chromeBackground)
  painter.strokeRect(menu.origin.x, menu.origin.y, menu.width, height,
                     painter.resolve(theme.chromeBorder))

  var cursor = menu.origin.y + menuPaddingY
  for index, item in menu.items:
    if item.isSeparator:
      painter.hLine(menu.origin.x + menuPaddingX * 0.5,
                    cursor + menuSeparatorHeight * 0.5,
                    menu.width - menuPaddingX, painter.resolve(theme.chromeBorder))
      cursor += menuSeparatorHeight
      continue
    if index == menu.highlighted and item.enabled:
      painter.fillRoundedRect(menu.origin.x + 4.0, cursor,
                              menu.width - 8.0, menuRowHeight, 4.0,
                              theme.chromeAccent)
    let textColor =
      if not item.enabled: withAlpha(theme.chromeText, 0.35)
      elif index == menu.highlighted: whiteColor
      else: theme.chromeText
    let m = fonts.metricsFor(desc)
    let baselineY = painter.snap(cursor + (menuRowHeight -
                                 (m.ascent + m.descent)) * 0.5 + m.ascent)
    discard painter.drawText(atlas, fonts, item.title,
                             menu.origin.x + menuPaddingX, baselineY, desc,
                             painter.resolve(textColor))
    cursor += menuRowHeight

proc menuWidthFor*(fonts: FontManager, items: seq[MenuItem],
                   desc: FontDesc): float =
  var widest = 120.0
  for item in items:
    if item.isSeparator: continue
    widest = max(widest, fonts.measureString(item.title, desc) + menuPaddingX * 2)
  ceil(widest)

# ---------------------------------------------------------------------------
# Find bar
# ---------------------------------------------------------------------------

proc drawFindBar*(painter: Painter, atlas: GlyphAtlas, fonts: FontManager,
                  bar: FindBar, theme: MarkdownEditorTheme, desc: FontDesc,
                  caretOn: bool) =
  if not bar.visible: return
  painter.fillRect(bar.rect.x, bar.rect.y, bar.rect.w, bar.rect.h,
                   theme.chromeBackground)
  painter.hLine(bar.rect.x, bar.rect.y + bar.rect.h - 1.0, bar.rect.w,
                painter.resolve(theme.chromeBorder))

  let m = fonts.metricsFor(desc)
  let fieldHeight = 22.0
  let fieldY = bar.rect.y + (bar.rect.h - fieldHeight) * 0.5
  let baselineY = painter.snap(fieldY + (fieldHeight - (m.ascent + m.descent)) *
                              0.5 + m.ascent)

  proc field(label, value: string, x, width: float, focused: bool) =
    painter.fillRoundedRect(x, fieldY, width, fieldHeight, 4.0,
                            withAlpha(theme.chromeText, 0.07))
    if focused:
      painter.strokeRect(x, fieldY, width, fieldHeight,
                         painter.resolve(theme.chromeAccent))
    painter.withClip(x + 1.0, fieldY, width - 2.0, fieldHeight):
      let shown = if value.len > 0: value else: label
      let tint = if value.len > 0: theme.chromeText
                 else: withAlpha(theme.chromeText, 0.4)
      let penX = painter.drawText(atlas, fonts, shown, x + 6.0, baselineY, desc,
                                  painter.resolve(tint))
      if focused and caretOn:
        let caretX = if value.len > 0: penX else: x + 6.0
        painter.fillRect(painter.snap(caretX), fieldY + 4.0, 1.5,
                         fieldHeight - 8.0, theme.chromeText)

  let halfWidth = max(120.0, (bar.rect.w - 220.0) * 0.5)
  field("Find", bar.query, bar.rect.x + 12.0, halfWidth, not bar.focusReplace)
  field("Replace", bar.replacement, bar.rect.x + 12.0 + halfWidth + 8.0,
        halfWidth, bar.focusReplace)

  let status = if bar.query.len == 0: ""
               elif bar.matchCount == 0: "no matches"
               else: $(bar.currentMatch + 1) & " of " & $bar.matchCount
  if status.len > 0:
    discard painter.drawText(atlas, fonts, status,
                             bar.rect.x + 12.0 + (halfWidth + 8.0) * 2, baselineY,
                             desc, painter.resolve(withAlpha(theme.chromeText, 0.6)))

# ---------------------------------------------------------------------------
# Directive completion picker
# ---------------------------------------------------------------------------

proc drawCompletionPicker*(painter: Painter, atlas: GlyphAtlas,
                           fonts: FontManager, titles, subtitles: seq[string],
                           highlighted: int, x, y: float,
                           theme: MarkdownEditorTheme, desc: FontDesc,
                           smallDesc: FontDesc) =
  ## The engine ships no picker UI — it publishes the completion context and
  ## the host draws it. This is the demo app's picker, kept here so the editor
  ## stays free of chrome.
  if titles.len == 0: return
  const rowHeight = 32.0
  let rows = min(titles.len, 8)
  var width = 220.0
  for i in 0 ..< rows:
    width = max(width, fonts.measureString(titles[i], desc) + 32.0)
    if i < subtitles.len:
      width = max(width, fonts.measureString(subtitles[i], smallDesc) + 32.0)
  let height = float(rows) * rowHeight + 8.0

  painter.fillRoundedRect(x + 1.0, y + 2.0, width, height, 7.0,
                          Rgba(r: 0, g: 0, b: 0, a: 0.18))
  painter.fillRoundedRect(x, y, width, height, 7.0, theme.chromeBackground)
  painter.strokeRect(x, y, width, height, painter.resolve(theme.chromeBorder))

  let m = fonts.metricsFor(desc)
  let sm = fonts.metricsFor(smallDesc)
  for i in 0 ..< rows:
    let rowY = y + 4.0 + float(i) * rowHeight
    if i == highlighted:
      painter.fillRoundedRect(x + 4.0, rowY, width - 8.0, rowHeight, 4.0,
                              theme.chromeAccent)
    let titleColor = if i == highlighted: whiteColor else: theme.chromeText
    discard painter.drawText(atlas, fonts, titles[i], x + 12.0,
                             painter.snap(rowY + m.ascent + 2.0), desc,
                             painter.resolve(titleColor))
    if i < subtitles.len and subtitles[i].len > 0:
      let subtitleColor = if i == highlighted: withAlpha(whiteColor, 0.8)
                          else: withAlpha(theme.chromeText, 0.55)
      discard painter.drawText(atlas, fonts, subtitles[i], x + 12.0,
                               painter.snap(rowY + rowHeight - sm.descent - 3.0),
                               smallDesc, painter.resolve(subtitleColor))

# ---------------------------------------------------------------------------
# Scroll-away header
# ---------------------------------------------------------------------------

type
  ScrollingHeader* = object
    ## Host content above the document: it scrolls with the content and
    ## collapses to a pinned top row, which is what
    ## `ScrollingHeaderController` managed.
    title*: string
    subtitle*: string
    bandHeight*: float
    collapsedHeight*: float

func headerCollapseProgress*(header: ScrollingHeader, scrollY: float): float =
  ## 0 = fully expanded, 1 = collapsed to the pinned row.
  let travel = max(1.0, header.bandHeight - header.collapsedHeight)
  clamp(scrollY / travel, 0.0, 1.0)

proc drawScrollingHeader*(painter: Painter, atlas: GlyphAtlas,
                          fonts: FontManager, header: ScrollingHeader,
                          x, y, width, scrollY: float,
                          theme: MarkdownEditorTheme, titleDesc,
                          subtitleDesc: FontDesc) =
  if header.bandHeight <= 0: return
  let progress = header.headerCollapseProgress(scrollY)
  let height = header.bandHeight - (header.bandHeight - header.collapsedHeight) * progress
  painter.withClip(x, y, width, height):
    painter.fillRect(x, y, width, height, theme.chromeBackground)
    let titleSize = titleDesc.size * (1.0 - 0.38 * progress)
    let scaledTitle = titleDesc.withSize(max(11.0, titleSize))
    let m = fonts.metricsFor(scaledTitle)
    # The title slides up and shrinks as the band collapses, ending pinned on
    # the collapsed row's baseline.
    let titleBaseline = painter.snap(y + height - m.descent -
                                     (1.0 - progress) * 22.0 - 8.0)
    discard painter.drawText(atlas, fonts, header.title, x + 20.0, titleBaseline,
                             scaledTitle, painter.resolve(theme.chromeText))
    if header.subtitle.len > 0 and progress < 0.85:
      let sm = fonts.metricsFor(subtitleDesc)
      let alpha = clamp(1.0 - progress / 0.85, 0.0, 1.0)
      discard painter.drawText(atlas, fonts, header.subtitle, x + 20.0,
                               painter.snap(titleBaseline + sm.ascent + 6.0),
                               subtitleDesc,
                               painter.resolve(withAlpha(theme.chromeText, 0.55 * alpha)))
  painter.hLine(x, y + height - 1.0, width,
                painter.resolve(withAlpha(theme.chromeBorder,
                                          0.35 + 0.65 * progress)))
