## painter.nim
## MarkdownEngine (Nim port) — UI layer
##
## Thin drawing primitives over the SDL3 renderer, plus the image store.
##
## Two jobs:
##
## * resolve the engine's dynamic `Color` against the current appearance and
##   push it to SDL, so no drawing site ever has to think about light/dark
## * own the textures the engine refers to by `ImageHandle.id`, since the
##   engine deliberately never touches a pixel

import std/[math, streams, strutils, tables]
import ./sdlbridge
import ../markdownengine/[color, attributes]

type
  Painter* = ref object
    renderer*: Renderer
    appearance*: Appearance
    scale*: float
      ## Backing scale, so hairlines land on whole device pixels.
    clipStack: seq[Rect]

  ImageStore* = ref object
    ## `ImageHandle.id` → texture. The engine passes handles around and
    ## reserves space for them; only this side knows what they are.
    textures: Table[int, Texture]
    sizes: Table[int, tuple[w, h: float]]
    nextID: int
    renderer: Renderer

proc newPainter*(renderer: Renderer, appearance = apLight,
                 scale = 1.0): Painter =
  Painter(renderer: renderer, appearance: appearance, scale: scale,
          clipStack: @[])

proc newImageStore*(renderer: Renderer): ImageStore =
  ImageStore(textures: initTable[int, Texture](),
             sizes: initTable[int, tuple[w, h: float]](), nextID: 1,
             renderer: renderer)

# ---------------------------------------------------------------------------
# Colour
# ---------------------------------------------------------------------------

func toBytes*(c: Rgba): tuple[r, g, b, a: uint8] {.inline.} =
  (uint8(clamp(c.r, 0.0, 1.0) * 255.0 + 0.5),
   uint8(clamp(c.g, 0.0, 1.0) * 255.0 + 0.5),
   uint8(clamp(c.b, 0.0, 1.0) * 255.0 + 0.5),
   uint8(clamp(c.a, 0.0, 1.0) * 255.0 + 0.5))

proc resolve*(painter: Painter, c: Color): Rgba {.inline.} =
  resolve(c, painter.appearance)

proc setColor*(painter: Painter, c: Rgba) {.inline.} =
  let (r, g, b, a) = c.toBytes
  discard setRenderDrawColor(painter.renderer, r, g, b, a)

proc setColor*(painter: Painter, c: Color) {.inline.} =
  painter.setColor(painter.resolve(c))

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

proc snap*(painter: Painter, value: float): float {.inline.} =
  ## Round to the nearest device pixel — what keeps a 1pt rule from blurring
  ## across two rows.
  if painter.scale <= 0: return value
  round(value * painter.scale) / painter.scale

proc fillRect*(painter: Painter, x, y, w, h: float, c: Rgba) =
  if w <= 0 or h <= 0 or c.a <= 0: return
  painter.setColor(c)
  var rect = FRect(x: cfloat(x), y: cfloat(y), w: cfloat(w), h: cfloat(h))
  discard renderFillRect(painter.renderer, addr rect)

proc fillRect*(painter: Painter, x, y, w, h: float, c: Color) {.inline.} =
  painter.fillRect(x, y, w, h, painter.resolve(c))

proc strokeRect*(painter: Painter, x, y, w, h: float, c: Rgba,
                 thickness = 1.0) =
  if w <= 0 or h <= 0 or c.a <= 0: return
  let t = max(1.0 / max(painter.scale, 1.0), thickness)
  painter.fillRect(x, y, w, t, c)
  painter.fillRect(x, y + h - t, w, t, c)
  painter.fillRect(x, y + t, t, h - 2 * t, c)
  painter.fillRect(x + w - t, y + t, t, h - 2 * t, c)

proc strokeRect*(painter: Painter, x, y, w, h: float, c: Color,
                 thickness = 1.0) {.inline.} =
  painter.strokeRect(x, y, w, h, painter.resolve(c), thickness)

proc hLine*(painter: Painter, x, y, w: float, c: Rgba, thickness = 1.0) {.inline.} =
  painter.fillRect(x, painter.snap(y), w, max(1.0 / max(painter.scale, 1.0), thickness), c)

proc vLine*(painter: Painter, x, y, h: float, c: Rgba, thickness = 1.0) {.inline.} =
  painter.fillRect(painter.snap(x), y, max(1.0 / max(painter.scale, 1.0), thickness), h, c)

proc fillRoundedRect*(painter: Painter, x, y, w, h, radius: float, c: Rgba) =
  ## A filled rounded rectangle, assembled from spans. SDL has no path API, and
  ## a per-row span fill is both exact and cheap at the sizes used here
  ## (checkbox boxes, chrome buttons, scroller knobs).
  if w <= 0 or h <= 0 or c.a <= 0: return
  let r = min(radius, min(w, h) * 0.5)
  if r <= 0.5:
    painter.fillRect(x, y, w, h, c)
    return
  painter.setColor(c)
  painter.fillRect(x, y + r, w, h - 2 * r, c)
  let steps = max(2, int(ceil(r)))
  for i in 0 ..< steps:
    let fy = (float(i) + 0.5) / float(steps) * r
    let dx = r - sqrt(max(0.0, r * r - (r - fy) * (r - fy)))
    let rowY = float(i) / float(steps) * r
    let rowH = r / float(steps) + 0.5
    painter.fillRect(x + dx, y + rowY, w - 2 * dx, rowH, c)
    painter.fillRect(x + dx, y + h - rowY - rowH, w - 2 * dx, rowH, c)

proc fillRoundedRect*(painter: Painter, x, y, w, h, radius: float,
                      c: Color) {.inline.} =
  painter.fillRoundedRect(x, y, w, h, radius, painter.resolve(c))

proc drawCheckGlyph*(painter: Painter, x, y, size: float, c: Rgba) =
  ## A checkmark drawn as two thick strokes. The Swift original asked the
  ## system for an SF Symbol; there is no symbol library here, so the two
  ## checkbox glyphs are drawn directly — which also keeps them crisp at any
  ## size instead of scaling a bitmap.
  let thickness = max(1.5, size * 0.14)
  let shortArmX = x + size * 0.22
  let shortArmY = y + size * 0.52
  let elbowX = x + size * 0.42
  let elbowY = y + size * 0.72
  let longArmX = x + size * 0.80
  let longArmY = y + size * 0.26
  painter.setColor(c)

  proc stroke(x0, y0, x1, y1: float) =
    let dx = x1 - x0
    let dy = y1 - y0
    let steps = max(2, int(ceil(max(abs(dx), abs(dy)) * 2)))
    for i in 0 .. steps:
      let t = float(i) / float(steps)
      var dot = FRect(x: cfloat(x0 + dx * t - thickness * 0.5),
                      y: cfloat(y0 + dy * t - thickness * 0.5),
                      w: cfloat(thickness), h: cfloat(thickness))
      discard renderFillRect(painter.renderer, addr dot)

  stroke(shortArmX, shortArmY, elbowX, elbowY)
  stroke(elbowX, elbowY, longArmX, longArmY)

# ---------------------------------------------------------------------------
# Clipping
# ---------------------------------------------------------------------------

proc pushClip*(painter: Painter, x, y, w, h: float) =
  ## Intersect with the current clip, so nested clips behave.
  var rect = Rect(x: cint(floor(x)), y: cint(floor(y)),
                  w: cint(ceil(max(0.0, w))), h: cint(ceil(max(0.0, h))))
  if painter.clipStack.len > 0:
    let current = painter.clipStack[^1]
    let lo = max(rect.x, current.x)
    let top = max(rect.y, current.y)
    let right = min(rect.x + rect.w, current.x + current.w)
    let bottom = min(rect.y + rect.h, current.y + current.h)
    rect = Rect(x: lo, y: top, w: max(cint(0), right - lo),
                h: max(cint(0), bottom - top))
  painter.clipStack.add rect
  discard setRenderClipRect(painter.renderer, addr rect)

proc popClip*(painter: Painter) =
  if painter.clipStack.len > 0:
    painter.clipStack.setLen(painter.clipStack.len - 1)
  if painter.clipStack.len > 0:
    var rect = painter.clipStack[^1]
    discard setRenderClipRect(painter.renderer, addr rect)
  else:
    discard setRenderClipRect(painter.renderer, nil)

template withClip*(painter: Painter, x, y, w, h: float, body: untyped) =
  painter.pushClip(x, y, w, h)
  try:
    body
  finally:
    painter.popClip()

# ---------------------------------------------------------------------------
# Image store
# ---------------------------------------------------------------------------

proc registerTexture*(store: ImageStore, texture: Texture,
                      width, height: float): ImageHandle =
  ## Hand the engine a handle for a texture this side owns.
  let id = store.nextID
  inc store.nextID
  store.textures[id] = texture
  store.sizes[id] = (width, height)
  ImageHandle(id: id, width: width, height: height, baselineOffset: 0)

proc texture*(store: ImageStore, handle: ImageHandle): Texture =
  store.textures.getOrDefault(handle.id, nil)

proc naturalSize*(store: ImageStore, handle: ImageHandle): tuple[w, h: float] =
  store.sizes.getOrDefault(handle.id, (0.0, 0.0))

proc decodePnm(path: string): (seq[uint8], int, int, bool) =
  ## Minimal binary PPM/PGM (`P5`/`P6`) decoder.
  ##
  ## There is no inflate in the Nim standard library, so PNG and JPEG cannot be
  ## decoded here at all. SDL3's own `SDL_LoadBMP` covers BMP; this adds the
  ## one other uncompressed raster format that is trivial to read, so an
  ## embedder has a dependency-free way to hand the editor real pixels. Every
  ## other format falls back to the labelled placeholder the renderer draws.
  var stream = newFileStream(path, fmRead)
  if stream == nil: return (@[], 0, 0, false)
  defer: stream.close()

  proc nextToken(s: FileStream): string =
    var token = ""
    while not s.atEnd:
      let ch = s.readChar()
      if ch == '#':
        while not s.atEnd and s.readChar() != '\n': discard
        continue
      if ch in {' ', '\t', '\n', '\r'}:
        if token.len > 0: return token
        continue
      token.add ch
    token

  let magic = nextToken(stream)
  if magic != "P6" and magic != "P5": return (@[], 0, 0, false)
  var width, height, maxValue: int
  try:
    width = parseInt(nextToken(stream))
    height = parseInt(nextToken(stream))
    maxValue = parseInt(nextToken(stream))
  except ValueError:
    return (@[], 0, 0, false)
  if width <= 0 or height <= 0 or maxValue <= 0 or maxValue > 255:
    return (@[], 0, 0, false)
  if width * height > 64_000_000: return (@[], 0, 0, false)

  let channels = if magic == "P6": 3 else: 1
  let raw = stream.readStr(width * height * channels)
  if raw.len < width * height * channels: return (@[], 0, 0, false)
  var pixels = newSeq[uint8](width * height * 4)
  for i in 0 ..< width * height:
    if channels == 3:
      pixels[i * 4 + 0] = uint8(raw[i * 3 + 0])
      pixels[i * 4 + 1] = uint8(raw[i * 3 + 1])
      pixels[i * 4 + 2] = uint8(raw[i * 3 + 2])
    else:
      let grey = uint8(raw[i])
      pixels[i * 4 + 0] = grey
      pixels[i * 4 + 1] = grey
      pixels[i * 4 + 2] = grey
    pixels[i * 4 + 3] = 255
  (pixels, width, height, true)

proc loadImageFile*(store: ImageStore, path: string): (ImageHandle, bool) =
  ## Load an image the engine can then refer to by handle. BMP goes through
  ## SDL3 itself; PPM/PGM through the decoder above. Anything else is reported
  ## as unavailable, and the renderer draws a labelled placeholder.
  let lowered = path.toLowerAscii
  if lowered.endsWith(".bmp"):
    let surface = loadBMP(path.cstring)
    if surface == nil: return (ImageHandle(), false)
    let texture = createTextureFromSurface(store.renderer, surface)
    let width = float(surface.w)
    let height = float(surface.h)
    destroySurface(surface)
    if texture == nil: return (ImageHandle(), false)
    discard setTextureBlendMode(texture, BLENDMODE_BLEND)
    discard setTextureScaleMode(texture, SCALEMODE_LINEAR)
    return (store.registerTexture(texture, width, height), true)

  if lowered.endsWith(".ppm") or lowered.endsWith(".pgm") or
     lowered.endsWith(".pnm"):
    var (pixels, width, height, ok) = decodePnm(path)
    if not ok: return (ImageHandle(), false)
    let texture = createTexture(store.renderer, PIXELFORMAT_RGBA32,
                                TEXTUREACCESS_STATIC, cint(width), cint(height))
    if texture == nil: return (ImageHandle(), false)
    discard updateTexture(texture, nil, cast[ptr uint8](addr pixels[0]),
                          cint(width * 4))
    discard setTextureBlendMode(texture, BLENDMODE_BLEND)
    discard setTextureScaleMode(texture, SCALEMODE_LINEAR)
    return (store.registerTexture(texture, float(width), float(height)), true)

  (ImageHandle(), false)

proc drawImage*(painter: Painter, store: ImageStore, handle: ImageHandle,
                x, y, w, h: float): bool =
  let texture = store.texture(handle)
  if texture == nil: return false
  var dst = FRect(x: cfloat(x), y: cfloat(y), w: cfloat(w), h: cfloat(h))
  renderTexture(painter.renderer, texture, nil, addr dst)

proc destroy*(store: ImageStore) =
  for texture in store.textures.values:
    if texture != nil: destroyTexture(texture)
  store.textures.clear()
  store.sizes.clear()
