## sdlbridge.nim
## MarkdownEngine (Nim port) — UI layer
##
## Re-exports the vendored SDL3 bindings with one name withheld.
##
## SDL3 declares a `Color` of its own, and so does the engine
## (`markdownengine/color.nim`, which carries a light AND a dark resolution so
## the theme keeps working across appearances). Every UI module needs both
## modules, so one of the two names has to give; withholding SDL's — the
## engine never hands SDL a colour struct, only bytes — keeps `Color` meaning
## the engine's type everywhere in this layer.
##
## Import this instead of `sdl3` from UI code.

import sdl3
export sdl3 except Color

type SdlColor* = sdl3.Color
  ## SDL's own RGBA struct, under a name that cannot collide.
