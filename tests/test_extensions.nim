## test_extensions.nim
## The block half of the extension seam: fenced extension blocks
## (`::: … :::`) parse, style, render and splice incrementally — and stay
## literal text without a registered extension.
##
## Ported from `BlockExtensionTests.swift`. (The inline half lives in
## `test_inline_parser.nim`, alongside the built-in spans it competes with.)

import std/[unittest, sequtils, strformat, strutils]
import markdownengine

let registry = initRegistry(@[newContainerExtension()])

proc kinds(text: string, r = emptyRegistry()): seq[BlockKind] =
  computeBlocks(initText(text), r).mapIt(it.kind)

proc extIDs(text: string, r = emptyRegistry()): seq[string] =
  for b in computeBlocks(initText(text), r):
    if b.kind == bkExt: result.add b.extensionID

suite "block extensions — recognition":

  test "without a registered extension the fence lines stay a paragraph":
    check kinds("::: note\nBody\n:::") == @[bkParagraph]

  test "a closed fenced block parses as one ext block":
    let text = "before\n\n::: note\nBody\n:::\nafter"
    check kinds(text, registry) ==
      @[bkParagraph, bkBlank, bkExt, bkParagraph]
    check extIDs(text, registry) == @[containerExtensionID]

  test "an unclosed fence runs to the end of the document":
    check kinds("::: note\nBody one\nBody two", registry) == @[bkExt]

  test "an extension fence interrupts a paragraph":
    check kinds("prose line\n::: note\nBody\n:::", registry) ==
      @[bkParagraph, bkExt]

  test "a fence inside a code block stays code — built-ins win":
    check kinds("```\n::: not a callout\n```", registry) == @[bkFencedCode]

  test "blocks still tile the document with an ext block present":
    let text = "# H\n\n::: note\nBody\n:::\n\n- item\n"
    var cursor = 0
    for b in computeBlocks(initText(text), registry):
      checkpoint(&"gap before {b.kind}")
      check b.range.location == cursor
      cursor = maxRange(b.range)
    check cursor == utf16Len(text)

suite "block extensions — AST geometry":

  test "the node carries fences, content and inline-parsed children":
    let text = "::: note\nBody with **bold**\n:::"
    let t = initText(text)
    let nodes = parseDocument(t, registry = registry)
    check nodes.len == 1
    check nodes[0].kind == bnExt
    let node = nodes[0].ext
    check node.extensionID == containerExtensionID
    check t.substring(node.openFence) == "::: note\n"
    check node.hasCloseFence
    check t.substring(node.closeFence) == ":::"
    check t.substring(node.contentRange) == "Body with **bold**\n"
    check node.inlines.anyIt(it.kind == inEmphasis)

  test "an unclosed block has no close fence and content to the end":
    let t = initText("::: note\nBody")
    let nodes = parseDocument(t, registry = registry)
    check nodes[0].kind == bnExt
    check not nodes[0].ext.hasCloseFence
    check t.substring(nodes[0].ext.contentRange) == "Body"

  test "the fence and content split agrees with tiling on U+2028":
    # A line separator terminates a line, so the block's first "line" ends
    # there — the fence split must agree instead of swallowing the next
    # physical line into the fence.
    let text = ":::note\u{2028}body\n:::"
    let t = initText(text)
    let nodes = parseDocument(t, registry = registry)
    check nodes[0].kind == bnExt
    check t.substring(nodes[0].ext.openFence) == ":::note\u{2028}"
    check t.substring(nodes[0].ext.contentRange) == "body\n"

suite "block extensions — styling":

  test "content gets the extension attributes, fences hide when inactive":
    var cfg = initConfiguration()
    cfg.extensions = @[newContainerExtension()]
    let text = "::: note\nBody\n:::"
    let t = initText(text)
    let attrs = styleAttributes(t, cfg, caretLocation = -1, containerWidth = 600.0)
    let contentPos = t.rangeOf("Body").location
    check attrs.anyIt(it[0].contains(contentPos) and
                      (it[1].has(akBackgroundColor) or
                       it[1].has(akMarkdownBlockBackground)))
    check attrs.anyIt(it[0].contains(0) and
                      it[1].colorOf(akForegroundColor, systemRed) == clearColor)

  test "fences reveal muted while the caret is inside the block":
    var cfg = initConfiguration()
    cfg.extensions = @[newContainerExtension()]
    let attrs = styleAttributes(initText("::: note\nBody\n:::"), cfg,
                                caretLocation = 12, containerWidth = 600.0)
    check attrs.anyIt(it[0].contains(0) and
                      it[1].colorOf(akForegroundColor, systemRed) ==
                        defaultTheme.mutedText)

suite "block extensions — HTML and tokens":

  test "HTML wraps the content; unregistered stays literal":
    let source = "::: note\nBody with **bold**\n:::"
    let with = renderHTML(source, extensions = @[newContainerExtension()])
    check "<blockquote>" in with
    check "<strong>bold</strong>" in with
    check "<blockquote>" notin renderHTML(source)

  test "the block projects one extensionBlock token with fence markers":
    let text = "::: note\nBody\n:::"
    let t = initText(text)
    let tokens = parseTokens(t, registry)
    let blocks = tokens.filterIt(it.kind == tkExtensionBlock)
    check blocks.len == 1
    check blocks[0].extensionID == containerExtensionID
    check blocks[0].range == rng(0, t.len)
    check blocks[0].markerRanges.len == 2
    check t.substring(blocks[0].contentRange) == "Body\n"

suite "block extensions — incremental parity":

  test "an interior edit splices to the same blocks as a full parse":
    # The edit sits mid-line, more than three characters from both line ends,
    # so nothing but the content line is inside the delimiter guard's window
    # and the splice path must engage.
    let old = toUtf16("before\n\n::: note\nBody middle content here\n:::\n\nafter")
    let new = toUtf16("before\n\n::: note\nBody middleX content here\n:::\n\nafter")
    let oldBlocks = computeBlocks(initText(old), registry)
    let (diff, ok) = scanDiff(old, new)
    check ok
    let (spliced, _, reused) = incrementalParse(old, oldBlocks, new,
                                                initText(new), diff, registry)
    check reused
    check spliced == computeBlocks(initText(new), registry)

  test "an edit touching a fence line bails to the full reparse":
    # Typing the closing fence: the splice must refuse, because extension
    # fences pair at a distance exactly like ```.
    let old = toUtf16("::: note\nBody\n::")
    let new = toUtf16("::: note\nBody\n:::")
    let oldBlocks = computeBlocks(initText(old), registry)
    let (diff, ok) = scanDiff(old, new)
    check ok
    let (_, _, reused) = incrementalParse(old, oldBlocks, new,
                                          initText(new), diff, registry)
    check not reused
    # And the full parse is correct either way.
    check kinds($initText(new), registry) == @[bkExt]

  test "joining two paragraphs never produces two adjacent paragraph blocks":
    # Deleting the separator between two paragraphs left them as two adjacent
    # `bkParagraph` blocks, where a full parse always merges them. Either the
    # splice matches the full parse or it falls back. Registry-free: the bug
    # class is independent of extensions.
    let old = toUtf16("ab \n\nc")
    let new = toUtf16("ab\nc")
    let oldBlocks = computeBlocks(initText(old))
    let (diff, ok) = scanDiff(old, new)
    check ok
    let (spliced, _, reused) = incrementalParse(old, oldBlocks, new,
                                                initText(new), diff)
    if reused:
      check spliced == computeBlocks(initText(new))
    check computeBlocks(initText(new)).mapIt(it.kind) == @[bkParagraph]

  test "the delimiter guard only knows a fence that was registered":
    let buf = toUtf16("::: note")
    check not hasBlockDelimiter(buf, 0, buf.len)
    check hasBlockDelimiter(buf, 0, buf.len, @[toUtf16(":::")])

  test "a registered block extension contributes its fence to the guard":
    check registry.fenceCharsList().anyIt(it == toUtf16(":::"))
