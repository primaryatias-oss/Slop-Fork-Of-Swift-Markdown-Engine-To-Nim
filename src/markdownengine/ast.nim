## ast.nim
## MarkdownEngine (Nim port)
##
## The semantic document AST. Combines the block-structure pass
## (`block_parser`) with the inline pass (`inline_parser`) into one tree of
## `BlockNode`s, each inline-bearing block carrying its parsed inline children
## in absolute document coordinates. The AST-native styler walks this tree
## instead of consuming flat tokens.
##
## **Invariant:** with `scopedRanges`, inlines are parsed only for blocks
## intersecting the edit — so a keystroke re-parses one block, not the whole
## document (≈ O(edit)).

import std/strutils
import ./ranges, ./utf16text, ./extension, ./inline_parser, ./block_parser

type
  ListItem* = object
    ## One list-item line: marker run, optional GFM checkbox, and indent column
    ## count.
    range*: Range          ## the item's full line (incl. trailing newline)
    marker*: Range
    ordered*: bool
    number*: int           ## ordered start value, e.g. `5.` → 5
    hasNumber*: bool
    checkbox*: Range
    hasCheckbox*: bool
    checked*: bool
    indent*: int
    contentRange*: Range   ## text after the marker (and checkbox)
    inlines*: seq[InlineNode]

  ExtensionBlockNode* = object
    ## An extension-supplied fenced block. `hasCloseFence` is false when the
    ## block is unclosed (it then runs to the end of the document).
    extensionID*: string
    range*: Range
    openFence*: Range      ## opening fence line incl. its newline
    closeFence*: Range
    hasCloseFence*: bool
    contentRange*: Range   ## lines between the fences
    inlines*: seq[InlineNode]

  BlockNodeKind* = enum
    bnParagraph
    bnHeading
    bnBlockquote
    bnList
    bnCodeBlock
    bnBlockLatex
    bnTable
    bnThematicBreak
    bnBlank
    bnExt

  BlockNode* = object
    ## A top-level block in the document AST.
    kind*: BlockNodeKind
    range*: Range
    level*: int                ## heading level
    markers*: seq[Range]       ## heading markers
    inlines*: seq[InlineNode]  ## paragraph / heading / blockquote content
    items*: seq[ListItem]      ## list items
    ext*: ExtensionBlockNode   ## `bnExt` payload

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func inScope(r: Range, scopedRanges: seq[Range], scoped: bool): bool {.inline.} =
  if not scoped: return true
  anyIntersects(scopedRanges, r)

proc parseHeading(t: Utf16Text, r: Range, scoped: bool,
                  registry: ExtensionRegistry): BlockNode =
  ## ATX heading: optional indent, `#`×level, space(s), then inline content.
  let stop = maxRange(r)
  var i = r.location
  while i < stop and (t.charAt(i) == chSpace or t.charAt(i) == chTab): inc i
  let hashStart = i
  var level = 0
  while i < stop and t.charAt(i) == chHash:
    inc level
    inc i

  var contentStart = i
  while contentStart < stop and t.charAt(contentStart) == chSpace: inc contentStart
  # Markers span `#`(s) plus trailing space(s) so the whole syntax collapses on
  # shrink.
  let markers = @[rng(hashStart, contentStart - hashStart)]
  var contentEnd = stop
  while contentEnd > contentStart and isLineBreakUnit(t.charAt(contentEnd - 1)):
    dec contentEnd
  let contentRange = rng(contentStart, contentEnd - contentStart)

  BlockNode(kind: bnHeading, range: r, level: level, markers: markers,
            inlines: if scoped: parseInline(t, contentRange, registry) else: @[])

proc parseListItem(t: Utf16Text, lineRange: Range, scoped: bool,
                   registry: ExtensionRegistry): ListItem =
  ## Parse one list-item line: indent, marker, optional task checkbox, inline
  ## content.
  let stop = maxRange(lineRange)
  var i = lineRange.location
  var indent = 0
  while i < stop and (t.charAt(i) == chSpace or t.charAt(i) == chTab):
    inc i
    inc indent
  let markerStart = i
  var ordered = false
  var number = 0
  var hasNumber = false
  let c = if i < stop: t.charAt(i) else: 0u16
  if c == chDash or c == chAsterisk or c == chPlus:       # - * +
    inc i
  else:                                                   # N. / N)
    var value = 0
    var digits = 0
    while i < stop and isAsciiDigit(t.charAt(i)) and digits < 9:
      value = value * 10 + int(t.charAt(i) - 0x30u16)
      inc i
      inc digits
    ordered = true
    number = value
    hasNumber = true
    if i < stop: inc i                                    # the `.` or `)`
  let marker = rng(markerStart, i - markerStart)
  if i < stop and (t.charAt(i) == chSpace or t.charAt(i) == chTab): inc i
  var checkbox = notFoundRange()
  var hasCheckbox = false
  var checked = false
  if i + 2 < stop and t.charAt(i) == chLBracket and t.charAt(i + 2) == chRBracket:
    let mid = t.charAt(i + 1)
    if mid == chSpace or mid == 0x78u16 or mid == 0x58u16:  # space / x / X
      checkbox = rng(i, 3)
      hasCheckbox = true
      checked = mid == 0x78u16 or mid == 0x58u16
      i += 3
      if i < stop and (t.charAt(i) == chSpace or t.charAt(i) == chTab): inc i
  var contentEnd = stop
  while contentEnd > i and isLineBreakUnit(t.charAt(contentEnd - 1)): dec contentEnd
  let content = rng(i, max(0, contentEnd - i))
  ListItem(range: lineRange, marker: marker, ordered: ordered, number: number,
           hasNumber: hasNumber, checkbox: checkbox, hasCheckbox: hasCheckbox,
           checked: checked, indent: indent, contentRange: content,
           inlines: if scoped: parseInline(t, content, registry) else: @[])

proc parseList(t: Utf16Text, r: Range, scopedRanges: seq[Range], scoped: bool,
               registry: ExtensionRegistry): BlockNode =
  ## Split a list block into physical items. Scoped passes derive their lines
  ## directly from the normalized scopes instead of walking the whole block.
  var lineRanges: seq[Range] = @[]
  if scoped:
    for scope in scopedRanges:
      let hit = intersection(scope, r)
      if hit.length <= 0: continue
      let expanded = intersection(t.lineRange(hit), r)
      var cursor = expanded.location
      let stop = maxRange(expanded)
      while cursor < stop:
        let line = intersection(t.lineRange(caretAt(cursor)), r)
        if line.length > 0 and (lineRanges.len == 0 or lineRanges[^1] != line):
          lineRanges.add line
        let next = maxRange(line)
        if next <= cursor: break
        cursor = next
  else:
    var cursor = r.location
    let stop = maxRange(r)
    while cursor < stop:
      let line = t.lineRange(caretAt(cursor))
      if line.length <= 0: break
      lineRanges.add line
      cursor = maxRange(line)

  var items = newSeqOfCap[ListItem](lineRanges.len)
  for line in lineRanges:
    items.add parseListItem(t, line, true, registry)
  BlockNode(kind: bnList, range: r, items: items)

proc parseExtensionBlock(t: Utf16Text, id: string, r: Range, scoped: bool,
                         registry: ExtensionRegistry): BlockNode =
  ## Split an extension fenced block into open fence line, optional closing
  ## fence line, and the content between; inlines parse over the content.
  let (entry, found) = registry.blockEntryFor(id)
  let fence = if found: entry.fence else: ""
  let stop = maxRange(r)
  # Opening fence line including its terminator — via `lineRange`, the same
  # primitive the block parser tiles with, so the fence/content split agrees on
  # EVERY line terminator (\n, \r\n, U+2028, …).
  let openLine = t.lineRange(caretAt(r.location))
  let openEnd = min(maxRange(openLine), stop)
  let openFence = rng(r.location, openEnd - r.location)

  # Closing fence: the block's last line, when it starts with the fence and is
  # not the opening line itself.
  var closeFence = notFoundRange()
  var hasCloseFence = false
  if openEnd < stop:
    let lastLine = t.lineRange(caretAt(stop - 1))
    if lastLine.location >= openEnd and fence.len > 0 and
       t.substring(lastLine).startsWith(fence):
      closeFence = lastLine
      hasCloseFence = true

  let contentEnd = if hasCloseFence: closeFence.location else: stop
  let contentRange = rng(openEnd, max(0, contentEnd - openEnd))
  BlockNode(kind: bnExt, range: r, ext: ExtensionBlockNode(
    extensionID: id, range: r, openFence: openFence, closeFence: closeFence,
    hasCloseFence: hasCloseFence, contentRange: contentRange,
    inlines: if scoped and contentRange.length > 0:
               parseInline(t, contentRange, registry)
             else: @[]))

proc nodeFor(b: Block, t: Utf16Text, scopedRanges: seq[Range], hasScope: bool,
             registry: ExtensionRegistry): BlockNode =
  let scoped = inScope(b.range, scopedRanges, hasScope)
  case b.kind
  of bkParagraph:
    BlockNode(kind: bnParagraph, range: b.range,
              inlines: if scoped: parseInline(t, b.range, registry) else: @[])
  of bkHeading:
    parseHeading(t, b.range, scoped, registry)
  of bkBlockquote:
    BlockNode(kind: bnBlockquote, range: b.range,
              inlines: if scoped: parseInline(t, b.range, registry) else: @[])
  of bkList:
    parseList(t, b.range, scopedRanges, hasScope, registry)
  of bkFencedCode:
    BlockNode(kind: bnCodeBlock, range: b.range)
  of bkBlockLatex:
    BlockNode(kind: bnBlockLatex, range: b.range)
  of bkTable:
    BlockNode(kind: bnTable, range: b.range)
  of bkThematicBreak:
    BlockNode(kind: bnThematicBreak, range: b.range)
  of bkBlank:
    BlockNode(kind: bnBlank, range: b.range)
  of bkExt:
    parseExtensionBlock(t, b.extensionID, b.range, scoped, registry)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc parseDocument*(t: Utf16Text, scopedRanges: seq[Range] = @[],
                    hasScope = false, precomputedBlocks: seq[Block] = @[],
                    hasPrecomputed = false,
                    registry = emptyRegistry()): seq[BlockNode] =
  ## Build the document AST; `scopedRanges` parses inlines only for
  ## intersecting blocks. `precomputedBlocks` (the keystroke's own parse state,
  ## handed down by the restyle) skips the block parse — whose cache "hit"
  ## still re-extracts and memcmps the full document buffer — entirely.
  let blocks = if hasPrecomputed: precomputedBlocks
               else: parseBlocks(t, registry)
  let normalized = if hasScope: normalizeScopes(scopedRanges, t.len) else: @[]

  if not hasScope:
    result = newSeqOfCap[BlockNode](blocks.len)
    for b in blocks:
      result.add nodeFor(b, t, @[], false, registry)
    return result

  # Scoped mode: skip building BlockNodes for blocks outside the edit. Blocks
  # tile the document in order, so one sweep over sorted candidate ranges
  # replaces scanning every candidate per block (which went quadratic in
  # formula-rich documents with dozens of candidates).
  var ci = 0
  for b in blocks:
    while ci < normalized.len and maxRange(normalized[ci]) <= b.range.location:
      inc ci
    if ci >= normalized.len: break
    var intersections: seq[Range] = @[]
    var si = ci
    while si < normalized.len and normalized[si].location < maxRange(b.range):
      intersections.add normalized[si]
      inc si
    if intersections.len > 0:
      result.add nodeFor(b, t, intersections, true, registry)

proc parseDocument*(text: string, registry = emptyRegistry()): seq[BlockNode] {.inline.} =
  parseDocument(initText(text), registry = registry)

# ---------------------------------------------------------------------------
# Walks the styler and the HTML renderer share
# ---------------------------------------------------------------------------

iterator inlineBearingBlocks*(blocks: seq[BlockNode]): BlockNode =
  for b in blocks:
    case b.kind
    of bnParagraph, bnHeading, bnBlockquote, bnList, bnExt: yield b
    else: discard

proc walkInlines*(nodes: seq[InlineNode], visit: proc (n: InlineNode) {.closure.}) =
  ## Depth-first pre-order walk over an inline tree.
  for n in nodes:
    visit(n)
    walkInlines(n.children, visit)

proc collectCodeRanges*(blocks: seq[BlockNode]): seq[Range] =
  ## Code spans and fenced blocks — what the AST-agnostic text passes use for
  ## their "skip inside code" checks.
  var acc: seq[Range] = @[]
  proc walk(nodes: seq[InlineNode]) =
    for node in nodes:
      case node.kind
      of inCode: acc.add node.range
      of inEmphasis, inLink, inExt: walk(node.children)
      else: discard
  for b in blocks:
    case b.kind
    of bnCodeBlock: acc.add b.range
    of bnParagraph, bnHeading, bnBlockquote: walk(b.inlines)
    of bnList:
      for item in b.items: walk(item.inlines)
    of bnExt: walk(b.ext.inlines)
    else: discard
  acc

proc collectLinkRanges*(blocks: seq[BlockNode]): seq[Range] =
  ## Full ranges of markdown links `[text](url)` and wiki links `[[…]]`. The
  ## auto-link pass skips URLs inside these, so a link's own `(url)` isn't
  ## independently linkified into a second, competing link region overlapping
  ## the link (which offsets the click edit-zone and makes the raw URL
  ## navigable).
  var acc: seq[Range] = @[]
  proc walk(nodes: seq[InlineNode]) =
    for node in nodes:
      case node.kind
      of inLink:
        acc.add node.range
        walk(node.children)
      of inWikiLink:
        acc.add node.range
      of inEmphasis, inExt:
        walk(node.children)
      else: discard
  for b in blocks:
    case b.kind
    of bnParagraph, bnHeading, bnBlockquote: walk(b.inlines)
    of bnList:
      for item in b.items: walk(item.inlines)
    of bnExt: walk(b.ext.inlines)
    else: discard
  acc

proc collectCheckboxRanges*(blocks: seq[BlockNode]): seq[Range] =
  ## Checkbox boxes (`[ ]`/`[x]`), excluded so the incomplete-link pass doesn't
  ## repaint their brackets.
  for b in blocks:
    if b.kind == bnList:
      for item in b.items:
        if item.hasCheckbox: result.add item.checkbox

func isInRanges*(r: Range, ranges: seq[Range]): bool =
  for other in ranges:
    if intersects(other, r): return true
  false
