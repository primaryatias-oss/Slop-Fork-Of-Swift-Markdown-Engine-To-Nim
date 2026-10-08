## color.nim
## MarkdownEngine (Nim port)
##
## The `NSColor` stand-in. macOS dynamic system colors resolve differently in
## light and dark mode, and the Swift engine relied on that heavily — the theme
## is "just" a bag of dynamic colors and light/dark switching came for free.
##
## A `Color` here therefore carries BOTH resolutions and is resolved against an
## `Appearance` at draw time. That reproduces the behavior the Swift code got
## from AppKit, including the gotcha its own comments call out: applying an
## alpha to a dynamic color must not freeze it to one appearance, so
## `withAlpha` scales both halves.

import std/strutils

type
  Appearance* = enum
    apLight
    apDark

  Rgba* = object
    r*, g*, b*, a*: float   ## 0…1, straight (non-premultiplied) alpha

  Color* = object
    ## A dynamic color: one resolution per appearance.
    light*: Rgba
    dark*: Rgba

func rgba*(r, g, b: float, a: float = 1.0): Rgba {.inline.} =
  Rgba(r: r, g: g, b: b, a: a)

func grayLevel*(v: float, a: float = 1.0): Rgba {.inline.} =
  Rgba(r: v, g: v, b: v, a: a)

func hexRgba*(hex: int, a: float = 1.0): Rgba {.inline.} =
  Rgba(r: float((hex shr 16) and 0xFF) / 255.0,
       g: float((hex shr 8) and 0xFF) / 255.0,
       b: float(hex and 0xFF) / 255.0,
       a: a)

func staticColor*(c: Rgba): Color {.inline.} =
  Color(light: c, dark: c)

func dynamicColor*(light, dark: Rgba): Color {.inline.} =
  Color(light: light, dark: dark)

func color*(r, g, b: float, a: float = 1.0): Color {.inline.} =
  staticColor(rgba(r, g, b, a))

func hexColor*(hex: int, a: float = 1.0): Color {.inline.} =
  staticColor(hexRgba(hex, a))

func hexColor*(lightHex, darkHex: int, a: float = 1.0): Color {.inline.} =
  dynamicColor(hexRgba(lightHex, a), hexRgba(darkHex, a))

func resolve*(c: Color, appearance: Appearance): Rgba {.inline.} =
  if appearance == apDark: c.dark else: c.light

func withAlpha*(c: Color, alpha: float): Color {.inline.} =
  ## `withAlphaComponent`, applied to BOTH resolutions. Doing it to a resolved
  ## color is the bug the Swift sources warn about twice (table renderer and
  ## `ContainerExtension`): it pins a dynamic color to one appearance.
  Color(light: Rgba(r: c.light.r, g: c.light.g, b: c.light.b, a: alpha),
        dark: Rgba(r: c.dark.r, g: c.dark.g, b: c.dark.b, a: alpha))

func withAlpha*(c: Rgba, alpha: float): Rgba {.inline.} =
  Rgba(r: c.r, g: c.g, b: c.b, a: alpha)

func scalingAlpha*(c: Color, factor: float): Color {.inline.} =
  Color(light: withAlpha(c.light, c.light.a * factor),
        dark: withAlpha(c.dark, c.dark.a * factor))

func isClear*(c: Color): bool {.inline.} =
  c.light.a <= 0.0001 and c.dark.a <= 0.0001

func `==`*(a, b: Rgba): bool {.inline.} =
  a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a

func `==`*(a, b: Color): bool {.inline.} =
  a.light == b.light and a.dark == b.dark

func blend*(dst, src: Rgba): Rgba =
  ## Source-over composite, straight alpha.
  if src.a >= 1.0: return src
  if src.a <= 0.0: return dst
  let outA = src.a + dst.a * (1.0 - src.a)
  if outA <= 0.0: return Rgba(r: 0, g: 0, b: 0, a: 0)
  Rgba(r: (src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / outA,
       g: (src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / outA,
       b: (src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / outA,
       a: outA)

func mix*(a, b: Rgba, t: float): Rgba {.inline.} =
  Rgba(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t,
       b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)

func luminance*(c: Rgba): float {.inline.} =
  0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

# ---------------------------------------------------------------------------
# The AppKit palette the engine's defaults name
# ---------------------------------------------------------------------------

const
  clearColor* = Color(light: Rgba(r: 0, g: 0, b: 0, a: 0),
                      dark: Rgba(r: 0, g: 0, b: 0, a: 0))
  blackColor* = Color(light: Rgba(r: 0, g: 0, b: 0, a: 1),
                      dark: Rgba(r: 0, g: 0, b: 0, a: 1))
  whiteColor* = Color(light: Rgba(r: 1, g: 1, b: 1, a: 1),
                      dark: Rgba(r: 1, g: 1, b: 1, a: 1))

  labelColor* = Color(light: Rgba(r: 0, g: 0, b: 0, a: 0.85),
                      dark: Rgba(r: 1, g: 1, b: 1, a: 0.85))
  secondaryLabelColor* = Color(light: Rgba(r: 0, g: 0, b: 0, a: 0.50),
                               dark: Rgba(r: 1, g: 1, b: 1, a: 0.55))
  tertiaryLabelColor* = Color(light: Rgba(r: 0, g: 0, b: 0, a: 0.26),
                              dark: Rgba(r: 1, g: 1, b: 1, a: 0.25))
  quaternaryLabelColor* = Color(light: Rgba(r: 0, g: 0, b: 0, a: 0.10),
                                dark: Rgba(r: 1, g: 1, b: 1, a: 0.10))
  grayColor* = Color(light: Rgba(r: 0.5, g: 0.5, b: 0.5, a: 1),
                     dark: Rgba(r: 0.5, g: 0.5, b: 0.5, a: 1))

  linkColor* = Color(light: Rgba(r: 0.0, g: 0.408, b: 0.855, a: 1),
                     dark: Rgba(r: 0.255, g: 0.612, b: 1.0, a: 1))
  separatorColor* = Color(light: Rgba(r: 0, g: 0, b: 0, a: 0.12),
                          dark: Rgba(r: 1, g: 1, b: 1, a: 0.14))
  textBackgroundColor* = Color(light: Rgba(r: 1, g: 1, b: 1, a: 1),
                               dark: Rgba(r: 0.118, g: 0.118, b: 0.125, a: 1))
  windowBackgroundColor* = Color(light: Rgba(r: 0.929, g: 0.929, b: 0.937, a: 1),
                                 dark: Rgba(r: 0.165, g: 0.165, b: 0.173, a: 1))
  controlBackgroundColor* = Color(light: Rgba(r: 1, g: 1, b: 1, a: 1),
                                  dark: Rgba(r: 0.133, g: 0.133, b: 0.141, a: 1))
  selectedTextBackgroundColor* = Color(light: Rgba(r: 0.698, g: 0.843, b: 1.0, a: 1),
                                       dark: Rgba(r: 0.188, g: 0.333, b: 0.549, a: 1))

  systemRed* = Color(light: Rgba(r: 1.0, g: 0.231, b: 0.188, a: 1),
                     dark: Rgba(r: 1.0, g: 0.271, b: 0.227, a: 1))
  systemOrange* = Color(light: Rgba(r: 1.0, g: 0.584, b: 0.0, a: 1),
                        dark: Rgba(r: 1.0, g: 0.624, b: 0.039, a: 1))
  systemYellow* = Color(light: Rgba(r: 1.0, g: 0.8, b: 0.0, a: 1),
                        dark: Rgba(r: 1.0, g: 0.839, b: 0.039, a: 1))
  systemGreen* = Color(light: Rgba(r: 0.157, g: 0.804, b: 0.255, a: 1),
                       dark: Rgba(r: 0.196, g: 0.843, b: 0.294, a: 1))
  systemMint* = Color(light: Rgba(r: 0.0, g: 0.78, b: 0.745, a: 1),
                      dark: Rgba(r: 0.4, g: 0.831, b: 0.812, a: 1))
  systemTeal* = Color(light: Rgba(r: 0.349, g: 0.678, b: 0.769, a: 1),
                      dark: Rgba(r: 0.416, g: 0.769, b: 0.863, a: 1))
  systemCyan* = Color(light: Rgba(r: 0.333, g: 0.745, b: 0.941, a: 1),
                      dark: Rgba(r: 0.353, g: 0.784, b: 0.961, a: 1))
  systemBlue* = Color(light: Rgba(r: 0.0, g: 0.478, b: 1.0, a: 1),
                      dark: Rgba(r: 0.039, g: 0.518, b: 1.0, a: 1))
  systemIndigo* = Color(light: Rgba(r: 0.345, g: 0.337, b: 0.839, a: 1),
                        dark: Rgba(r: 0.369, g: 0.361, b: 0.902, a: 1))
  systemPurple* = Color(light: Rgba(r: 0.686, g: 0.322, b: 0.871, a: 1),
                        dark: Rgba(r: 0.749, g: 0.353, b: 0.949, a: 1))
  systemPink* = Color(light: Rgba(r: 1.0, g: 0.176, b: 0.333, a: 1),
                      dark: Rgba(r: 1.0, g: 0.216, b: 0.373, a: 1))
  systemBrown* = Color(light: Rgba(r: 0.635, g: 0.518, b: 0.369, a: 1),
                       dark: Rgba(r: 0.675, g: 0.557, b: 0.408, a: 1))
  systemGray* = Color(light: Rgba(r: 0.557, g: 0.557, b: 0.576, a: 1),
                      dark: Rgba(r: 0.596, g: 0.596, b: 0.616, a: 1))

func namedSystemColor*(name: string): (Color, bool) =
  ## `NSColor(named:)` over the standard palette — used by `@color(red){…}`.
  ## The second element is `false` when the name is unknown, which the
  ## directive turns into "leave the body alone rather than guessing".
  case toLowerAscii(name)
  of "red": (systemRed, true)
  of "orange": (systemOrange, true)
  of "yellow": (systemYellow, true)
  of "green": (systemGreen, true)
  of "mint": (systemMint, true)
  of "teal": (systemTeal, true)
  of "cyan": (systemCyan, true)
  of "blue": (systemBlue, true)
  of "indigo": (systemIndigo, true)
  of "purple": (systemPurple, true)
  of "pink": (systemPink, true)
  of "brown": (systemBrown, true)
  of "gray", "grey": (systemGray, true)
  of "black": (blackColor, true)
  of "white": (whiteColor, true)
  of "label": (labelColor, true)
  of "secondary", "secondarylabel": (secondaryLabelColor, true)
  of "link": (linkColor, true)
  else: (labelColor, false)
