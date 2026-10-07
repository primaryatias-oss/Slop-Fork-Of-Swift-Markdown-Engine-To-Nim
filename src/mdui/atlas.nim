## atlas.nim
## MarkdownEngine (Nim port) — UI layer
##
## A glyph atlas on an SDL3 texture.
##
## Uploading one texture per glyph would mean thousands of tiny textures and a
## state change per character. Instead every rasterized glyph is packed into a
## shared RGBA texture with a shelf packer, and drawing a run is a sequence of
## `renderTexture` calls out of that one texture, tinted per run with
## `setTextureColorMod`.
##
## Glyph coverage is 8-bit, so each glyph is stored as white with the coverage
## in the alpha channel; the colour comes from the tint. That means one atlas
## entry serves every colour the same glyph is ever drawn in — which matters
## here, because the styler paints the same characters in body, muted, link and
## clear colours as the caret moves.

import std/tables
import ./sdlbridge
import ../markdownengine/[color, font]
import ./fontmanager, ./truetype

type
  AtlasEntry* = object
    ## Where a glyph lives in the atlas, plus the offsets to blit it by.
    page*: int
    u*, v*: int
    width*, height*: int
    left*, top*: int
    valid*: bool

  AtlasPage = object
    texture: Texture
    shelfY: int        ## top of the current shelf
    shelfHeight: int   ## tallest glyph on the current shelf
    penX: int          ## next free x on the current shelf

  GlyphAtlas* = ref object
    renderer: Renderer
    fonts: FontManager
    pages: seq[AtlasPage]
    entries: Table[string, AtlasEntry]
    pageSize: int
    uploadCount*: int

const atlasPadding = 1
  ## One transparent pixel between glyphs, so bilinear sampling at a fractional
  ## position never bleeds a neighbour's ink into the glyph.

proc newGlyphAtlas*(renderer: Renderer, fonts: FontManager,
                    pageSize = 1024): GlyphAtlas =
  GlyphAtlas(renderer: renderer, fonts: fonts, pages: @[],
             entries: initTable[string, AtlasEntry](), pageSize: pageSize,
             uploadCount: 0)

proc addPage(atlas: GlyphAtlas): int =
  let texture = createTexture(atlas.renderer, PIXELFORMAT_RGBA32,
                              TEXTUREACCESS_STATIC,
                              cint(atlas.pageSize), cint(atlas.pageSize))
  if texture == nil:
    return -1
  discard setTextureBlendMode(texture, BLENDMODE_BLEND)
  # Linear filtering: glyphs are blitted at integer positions, but a page is
  # also sampled when the view is on a fractional-scale display.
  discard setTextureScaleMode(texture, SCALEMODE_LINEAR)
  # Start fully transparent so unpacked regions never show.
  var blank = newSeq[uint8](atlas.pageSize * atlas.pageSize * 4)
  discard updateTexture(texture, nil, cast[ptr uint8](addr blank[0]),
                        cint(atlas.pageSize * 4))
  atlas.pages.add AtlasPage(texture: texture, shelfY: 0, shelfHeight: 0, penX: 0)
  atlas.pages.len - 1

proc reserve(atlas: GlyphAtlas, width, height: int): (int, int, int, bool) =
  ## Find room for a `width * height` glyph; `(page, u, v, ok)`.
  if width <= 0 or height <= 0: return (0, 0, 0, false)
  if width + atlasPadding * 2 > atlas.pageSize or
     height + atlasPadding * 2 > atlas.pageSize:
    return (0, 0, 0, false)      # a glyph larger than a page: drawn directly
  if atlas.pages.len == 0:
    if atlas.addPage() < 0: return (0, 0, 0, false)

  let pageIndex = atlas.pages.len - 1
  template page: untyped = atlas.pages[pageIndex]
  let needWidth = width + atlasPadding
  let needHeight = height + atlasPadding

  if page.penX + needWidth > atlas.pageSize:
    # Next shelf.
    page.shelfY += page.shelfHeight + atlasPadding
    page.shelfHeight = 0
    page.penX = 0
  if page.shelfY + needHeight > atlas.pageSize:
    # Page full: start a new one. Old pages stay valid, so nothing re-uploads.
    let fresh = atlas.addPage()
    if fresh < 0: return (0, 0, 0, false)
    return atlas.reserve(width, height)

  let u = page.penX
  let v = page.shelfY
  page.penX += needWidth
  page.shelfHeight = max(page.shelfHeight, height)
  (pageIndex, u, v, true)

proc upload(atlas: GlyphAtlas, page, u, v: int, bitmap: GlyphBitmap): bool =
  ## Expand 8-bit coverage into white-with-alpha RGBA and push the region.
  if bitmap.width <= 0 or bitmap.height <= 0: return false
  var pixels = newSeq[uint8](bitmap.width * bitmap.height * 4)
  for i in 0 ..< bitmap.width * bitmap.height:
    let alpha = bitmap.coverage[i]
    pixels[i * 4 + 0] = 255
    pixels[i * 4 + 1] = 255
    pixels[i * 4 + 2] = 255
    pixels[i * 4 + 3] = alpha
  var region = Rect(x: cint(u), y: cint(v), w: cint(bitmap.width),
                    h: cint(bitmap.height))
  inc atlas.uploadCount
  updateTexture(atlas.pages[page].texture, addr region,
                cast[ptr uint8](addr pixels[0]), cint(bitmap.width * 4))

proc entryFor*(atlas: GlyphAtlas, desc: FontDesc,
               codePoint: int): AtlasEntry =
  ## The atlas entry for one scalar, rasterizing and packing it on first use.
  let key = atlas.fonts.glyphCacheKeyString(desc, codePoint)
  if key.len == 0: return AtlasEntry(valid: false)
  atlas.entries.withValue(key, hit):
    return hit[]

  let (bitmap, hasInk) = atlas.fonts.glyphBitmap(desc, codePoint)
  if not hasInk:
    # A blank glyph (space) is a valid cache entry with no ink, so it is never
    # rasterized again.
    let empty = AtlasEntry(valid: false)
    atlas.entries[key] = empty
    return empty

  let (page, u, v, ok) = atlas.reserve(bitmap.width, bitmap.height)
  if not ok or not atlas.upload(page, u, v, bitmap):
    let failed = AtlasEntry(valid: false)
    atlas.entries[key] = failed
    return failed

  let entry = AtlasEntry(page: page, u: u, v: v, width: bitmap.width,
                         height: bitmap.height, left: bitmap.left,
                         top: bitmap.top, valid: true)
  atlas.entries[key] = entry
  entry

proc drawGlyph*(atlas: GlyphAtlas, entry: AtlasEntry, penX, baselineY: float,
                tint: Rgba) =
  ## Blit one glyph with its pen position at `(penX, baselineY)`.
  if not entry.valid: return
  if entry.page < 0 or entry.page >= atlas.pages.len: return
  let texture = atlas.pages[entry.page].texture
  discard setTextureColorMod(texture, uint8(tint.r * 255.0 + 0.5),
                             uint8(tint.g * 255.0 + 0.5),
                             uint8(tint.b * 255.0 + 0.5))
  discard setTextureAlphaMod(texture, uint8(clamp(tint.a, 0.0, 1.0) * 255.0 + 0.5))
  var src = FRect(x: cfloat(entry.u), y: cfloat(entry.v),
                  w: cfloat(entry.width), h: cfloat(entry.height))
  var dst = FRect(x: cfloat(penX + float(entry.left)),
                  y: cfloat(baselineY + float(entry.top)),
                  w: cfloat(entry.width), h: cfloat(entry.height))
  discard renderTexture(atlas.renderer, texture, addr src, addr dst)

proc destroy*(atlas: GlyphAtlas) =
  for page in atlas.pages:
    if page.texture != nil: destroyTexture(page.texture)
  atlas.pages = @[]
  atlas.entries.clear()
