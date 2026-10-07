## screenshot.nim
## MarkdownEngine (Nim port) — UI layer
##
## Capture the rendered frame to a file.
##
## Useful on its own (documenting the editor, filing a visual regression), and
## necessary for the headless smoke test: a frame that draws nothing still
## "succeeds", so the only honest check is to look at the pixels.
##
## PNG needs a DEFLATE stream, and there is no compressor in the Nim standard
## library. DEFLATE's *stored* block type is uncompressed by design, though, so
## a valid zlib stream can be built from stored blocks plus an Adler-32 — which
## is what `writePng` does. The file is larger than a compressed one and every
## decoder reads it. BMP goes through SDL3's own `SDL_SaveBMP`.

import std/[streams, strutils]
import ./sdlbridge

# ---------------------------------------------------------------------------
# PNG
# ---------------------------------------------------------------------------

func crc32(data: openArray[uint8], seed = 0xFFFFFFFF'u32): uint32 =
  var table: array[256, uint32]
  for i in 0 ..< 256:
    var c = uint32(i)
    for _ in 0 ..< 8:
      c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
    table[i] = c
  var crc = seed
  for b in data:
    crc = table[(crc xor uint32(b)) and 0xFF] xor (crc shr 8)
  crc xor 0xFFFFFFFF'u32

func adler32(data: openArray[uint8]): uint32 =
  var a = 1'u32
  var b = 0'u32
  for byteValue in data:
    a = (a + uint32(byteValue)) mod 65521'u32
    b = (b + a) mod 65521'u32
  (b shl 16) or a

proc putBE32(s: Stream, value: uint32) =
  s.write(uint8((value shr 24) and 0xFF))
  s.write(uint8((value shr 16) and 0xFF))
  s.write(uint8((value shr 8) and 0xFF))
  s.write(uint8(value and 0xFF))

proc writeChunk(s: Stream, kind: string, payload: openArray[uint8]) =
  s.putBE32(uint32(payload.len))
  var framed = newSeq[uint8](4 + payload.len)
  for i in 0 ..< 4: framed[i] = uint8(kind[i])
  for i in 0 ..< payload.len: framed[4 + i] = payload[i]
  for b in framed: s.write(b)
  s.putBE32(crc32(framed))

proc writePng*(path: string, width, height: int,
               rgba: openArray[uint8]): bool =
  ## Write 8-bit RGBA pixels as a PNG.
  if width <= 0 or height <= 0: return false
  if rgba.len < width * height * 4: return false

  # Filter type 0 (none) per scanline, which is what makes the stored-block
  # trick viable: no filtering means no decode-side surprises.
  var raw = newSeqOfCap[uint8](height * (1 + width * 4))
  for y in 0 ..< height:
    raw.add 0'u8
    let rowStart = y * width * 4
    for i in 0 ..< width * 4:
      raw.add rgba[rowStart + i]

  var compressed: seq[uint8] = @[]
  compressed.add 0x78'u8
  compressed.add 0x01'u8
  const maxBlock = 65535
  var offset = 0
  while true:
    let size = min(maxBlock, raw.len - offset)
    let isLast = offset + size >= raw.len
    compressed.add(if isLast: 0x01'u8 else: 0x00'u8)
    compressed.add uint8(size and 0xFF)
    compressed.add uint8((size shr 8) and 0xFF)
    let inverted = not uint16(size)
    compressed.add uint8(inverted and 0xFF)
    compressed.add uint8((inverted shr 8) and 0xFF)
    for i in 0 ..< size: compressed.add raw[offset + i]
    offset += size
    if isLast: break
  let checksum = adler32(raw)
  compressed.add uint8((checksum shr 24) and 0xFF)
  compressed.add uint8((checksum shr 16) and 0xFF)
  compressed.add uint8((checksum shr 8) and 0xFF)
  compressed.add uint8(checksum and 0xFF)

  var stream = newFileStream(path, fmWrite)
  if stream == nil: return false
  defer: stream.close()

  for b in [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]: stream.write(b)

  var ihdr: seq[uint8] = @[]
  for shift in [24, 16, 8, 0]: ihdr.add uint8((uint32(width) shr shift) and 0xFF)
  for shift in [24, 16, 8, 0]: ihdr.add uint8((uint32(height) shr shift) and 0xFF)
  ihdr.add 8'u8      # bit depth
  ihdr.add 6'u8      # colour type: truecolour with alpha
  ihdr.add 0'u8      # compression: deflate
  ihdr.add 0'u8      # filter: adaptive
  ihdr.add 0'u8      # interlace: none
  stream.writeChunk("IHDR", ihdr)
  stream.writeChunk("IDAT", compressed)
  stream.writeChunk("IEND", [])
  true

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

proc captureFrame*(renderer: Renderer, path: string): bool =
  ## Read the renderer's current target back and write it out. `.png` goes
  ## through the encoder above; anything else through SDL's BMP writer.
  let surface = renderReadPixels(renderer, nil)
  if surface == nil: return false
  defer: destroySurface(surface)

  if not path.toLowerAscii.endsWith(".png"):
    return saveBMP(surface, path.cstring)

  let converted = convertSurface(surface, PIXELFORMAT_RGBA32)
  if converted == nil: return false
  defer: destroySurface(converted)
  let width = int(converted.w)
  let height = int(converted.h)
  let pitch = int(converted.pitch)
  if converted.pixels == nil: return false
  var rgba = newSeq[uint8](width * height * 4)
  for y in 0 ..< height:
    for i in 0 ..< width * 4:
      rgba[y * width * 4 + i] = converted.pixels[y * pitch + i]
  writePng(path, width, height, rgba)
