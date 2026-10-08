## extension.nim
## MarkdownEngine (Nim port)
##
## The extension seam: a construct beyond pure markdown — an inline span
## (`==text==`, `%%text%%`, …) and/or a fenced block (`::: … :::`) — can be
## supplied by an extension instead of being hard-coded into the parser. The
## core stays pure markdown; extensions are opt-in per editor instance via
## `MarkdownEditorConfiguration.extensions`.
##
## Isolation contract: an extension supplies SYNTAX (the delimiters) and
## ATTRIBUTES (how the content looks). It never emits ranges — the parser
## derives content/marker ranges itself, so a buggy extension can restyle its
## own span at worst, never a neighbor. Marker mute/shrink, caret reveal,
## incremental restyle, and copy behavior are handled generically by the
## engine, identical for every extension.
##
## Also holds `ExtensionRegistry`, the precompiled, purely syntactic view the
## parser sees, and `DirectiveRegistry`, which it CARRIES — so the directive
## fingerprint folds into the one grammar fingerprint every parse cache already
## keys on. Registering a directive at runtime therefore invalidates those
## caches with no second key threaded through the pipeline.

import std/[strutils, tables]
import ./utf16text, ./color, ./attributes, ./theme, ./directive

# ---------------------------------------------------------------------------
# Syntax rules
# ---------------------------------------------------------------------------

type
  InlineSyntax* = object
    ## The syntax of a delimited span, mirroring the built-in span scanners:
    ##
    ## * The span opens where `open` matches and closes at the FIRST exact
    ##   `close` match on the same line.
    ## * A lone occurrence of `close`'s first character inside the content
    ##   aborts the match (the candidate stays literal) — `==a=b==` is not a
    ##   span.
    ## * A newline before the close aborts the match (spans are single-line).
    open*: string
    close*: string
    parsesContent*: bool
      ## Whether the content is re-parsed as markdown (container, like
      ## `==bold **inside**==`) or kept opaque (leaf, like a comment).
    requiresNonEmptyContent*: bool
      ## Reject an empty span (`====`). Default `true`.
    rejectsOpenerRun*: bool
      ## Reject when the character before `open` equals `open`'s first
      ## character (the span must not extend a longer delimiter run).
    rejectsCloserRun*: bool
      ## Reject when the character after `close` equals `close`'s last
      ## character. `~~` uses this; `==` does not.

  BlockSyntax* = object
    ## The syntax of a fenced block, mirroring ``` code fences:
    ##
    ## * A line starting with `fence` at column 0 OPENS the block; the rest of
    ##   that line is the info string (e.g. `::: warning`).
    ## * The next line starting with `fence` at column 0 CLOSES it.
    ## * An unclosed block runs to the end of the document.
    fence*: string

func initInlineSyntax*(open, close: string, parsesContent = true,
                       requiresNonEmptyContent = true, rejectsOpenerRun = true,
                       rejectsCloserRun = false): InlineSyntax =
  InlineSyntax(open: open, close: close, parsesContent: parsesContent,
               requiresNonEmptyContent: requiresNonEmptyContent,
               rejectsOpenerRun: rejectsOpenerRun,
               rejectsCloserRun: rejectsCloserRun)

func initBlockSyntax*(fence: string): BlockSyntax =
  BlockSyntax(fence: fence)

# ---------------------------------------------------------------------------
# The extension value type
# ---------------------------------------------------------------------------

type
  MarkdownExtension* = ref object of RootObj
    ## An opt-in construct beyond pure markdown. Register instances via
    ## `MarkdownEditorConfiguration.extensions`; unregistered syntax stays
    ## literal text.
    id*: string
      ## Stable identifier, unique per extension (e.g. `"highlight"`). Used for
      ## dispatch and cache keying — never shown to users.
    inline*: InlineSyntax
    hasInline*: bool
    blockSyntax*: BlockSyntax
    hasBlock*: bool
    contentAttributesProc*: proc (theme: MarkdownEditorTheme): Attrs {.closure, gcsafe.}
      ## Attributes applied to the construct's CONTENT range (between the
      ## markers/fences). Called during styling; must be cheap and synchronous.
    htmlProc*: proc (childrenHTML: string): string {.closure, gcsafe.}
      ## Wrap the rendered inner HTML for the clean-copy path.

proc newExtension*(id: string,
                   inline = InlineSyntax(), hasInline = false,
                   blockSyntax = BlockSyntax(), hasBlock = false,
                   contentAttributesProc: proc (theme: MarkdownEditorTheme): Attrs {.closure, gcsafe.} = nil,
                   htmlProc: proc (childrenHTML: string): string {.closure, gcsafe.} = nil): MarkdownExtension =
  MarkdownExtension(id: id, inline: inline, hasInline: hasInline,
                    blockSyntax: blockSyntax, hasBlock: hasBlock,
                    contentAttributesProc: contentAttributesProc,
                    htmlProc: htmlProc)

proc contentAttributes*(e: MarkdownExtension, theme: MarkdownEditorTheme): Attrs =
  if e.contentAttributesProc != nil: e.contentAttributesProc(theme) else: @[]

proc html*(e: MarkdownExtension, childrenHTML: string): string =
  if e.htmlProc != nil: e.htmlProc(childrenHTML) else: childrenHTML

# ---------------------------------------------------------------------------
# Bundled extensions
# ---------------------------------------------------------------------------

const
  highlightExtensionID* = "highlight"
  strikethroughExtensionID* = "strikethrough"
  containerExtensionID* = "container"

proc newHighlightExtension*(): MarkdownExtension =
  ## `==text==` highlight (Obsidian/CriticMarkup flavor). Not registered by
  ## default.
  ##
  ## Uses `akMarkdownBlockBackground`, not `akBackgroundColor`: the fill covers
  ## the whole line box, so a highlight that wraps over several lines reads as
  ## one block instead of a band per line.
  newExtension(
    id = highlightExtensionID,
    inline = initInlineSyntax("==", "=="), hasInline = true,
    contentAttributesProc = proc (theme: MarkdownEditorTheme): Attrs {.closure, gcsafe.} =
      @[(akMarkdownBlockBackground, av(theme.highlightColor))],
    htmlProc = proc (childrenHTML: string): string {.closure, gcsafe.} =
      "<mark>" & childrenHTML & "</mark>")

proc newStrikethroughExtension*(): MarkdownExtension =
  ## `~~text~~` strikethrough (GFM flavor). Matches the formerly built-in
  ## semantics exactly, including the stricter GFM-ish run handling: `~~a~~~`
  ## stays literal, unlike highlight's tolerant `==abc===`.
  newExtension(
    id = strikethroughExtensionID,
    inline = initInlineSyntax("~~", "~~", rejectsCloserRun = true), hasInline = true,
    contentAttributesProc = proc (theme: MarkdownEditorTheme): Attrs {.closure, gcsafe.} =
      @[(akStrikethroughStyle, av(ulSingle)),
        (akStrikethroughColor, av(theme.strikethroughColor))],
    htmlProc = proc (childrenHTML: string): string {.closure, gcsafe.} =
      "<del>" & childrenHTML & "</del>")

proc newContainerExtension*(backgroundColor = withAlpha(systemBlue, 0.12)): MarkdownExtension =
  ## `:::` fenced container. The fence lines hide while the caret is outside
  ## the block and reveal muted while editing (mirroring code fences); the body
  ## keeps full inline styling plus the container background. An unclosed
  ## container runs to the end of the document.
  let fill = backgroundColor
  newExtension(
    id = containerExtensionID,
    blockSyntax = initBlockSyntax(":::"), hasBlock = true,
    contentAttributesProc = proc (theme: MarkdownEditorTheme): Attrs {.closure, gcsafe.} =
      @[(akBackgroundColor, av(fill))],
    htmlProc = proc (childrenHTML: string): string {.closure, gcsafe.} =
      "<blockquote>" & childrenHTML & "</blockquote>")

# ---------------------------------------------------------------------------
# Directive registry (parser-facing)
# ---------------------------------------------------------------------------

const
  directiveIDPrefix* = "directive."
    ## Directive nodes are represented in the AST as extension-shaped nodes
    ## (`InlineNode.ext`) whose id carries this prefix. That gives directives
    ## the whole downstream pipeline — marker shrink, caret reveal, token
    ## projection, incremental restyle, rich copy — with no new node kind.

func directiveNodeID*(directiveID: string): string {.inline.} =
  directiveIDPrefix & directiveID

func directiveIDForNodeID*(nodeID: string): (string, bool) =
  ## The directive id for an AST id; `false` when the node isn't a directive.
  if nodeID.startsWith(directiveIDPrefix):
    (nodeID[directiveIDPrefix.len .. ^1], true)
  else:
    ("", false)

type
  DirectiveEntry* = object
    id*: string
    name*: string
    marker*: uint16
    form*: DirectiveForm
    parsesBody*: bool

  DirectiveRegistry* = object
    ## Precompiled directive rules. Built once per parse entry from the
    ## configuration, exactly like `ExtensionRegistry`.
    byMarker*: Table[uint16, Table[string, DirectiveEntry]]
      ## marker → name → entry. Two-level so the scanner rejects a non-marker
      ## character in a single table probe — the common case on every character
      ## of every parse.
    fingerprint*: string
      ## Stable fingerprint for cache keying ("" when empty). Two registries
      ## with the same fingerprint produce identical parses for identical text.

proc emptyDirectiveRegistry*(): DirectiveRegistry =
  DirectiveRegistry(byMarker: initTable[uint16, Table[string, DirectiveEntry]](),
                    fingerprint: "")

func isEmpty*(r: DirectiveRegistry): bool {.inline.} =
  r.byMarker.len == 0

func framed(s: string): string {.inline.} =
  ## Length-prefixed so a concatenation of free-text fields is injective: a
  ## name containing the separator cannot alias another registry.
  $utf16Len(s) & "." & s

proc initDirectiveRegistry*(directives: seq[MarkdownDirective],
                            settings = defaultDirectiveSettings): DirectiveRegistry =
  if directives.len == 0:
    return emptyDirectiveRegistry()
  var table = initTable[uint16, Table[string, DirectiveEntry]]()
  for d in directives:
    let syntax = d.syntax
    if syntax.name.len == 0: continue
    let marker = if syntax.marker != 0: syntax.marker else: settings.defaultMarker
    if marker == 0: continue
    if not table.hasKey(marker):
      table[marker] = initTable[string, DirectiveEntry]()
    # First registration wins, matching extension precedence.
    if table[marker].hasKey(syntax.name): continue
    table[marker][syntax.name] = DirectiveEntry(
      id: d.id, name: syntax.name, marker: marker, form: syntax.form,
      parsesBody: syntax.parsesBody)

  # Only fields that change the PARSE participate — presentation-only edits
  # (colours, completion prose) must not invalidate parse caches.
  var parts: seq[string] = @[]
  for d in directives:
    let syntax = d.syntax
    let markerText = utf16ToString([if syntax.marker != 0: syntax.marker
                                    else: settings.defaultMarker])
    parts.add [framed(d.id), framed(syntax.name), framed(markerText),
               $syntax.form, $syntax.parsesBody].join(",")
  DirectiveRegistry(byMarker: table, fingerprint: parts.join("|"))

proc entry*(r: DirectiveRegistry, marker: uint16, name: string): (DirectiveEntry, bool) =
  if r.byMarker.hasKey(marker) and r.byMarker[marker].hasKey(name):
    (r.byMarker[marker][name], true)
  else:
    (DirectiveEntry(), false)

# ---------------------------------------------------------------------------
# Extension registry (parser-facing)
# ---------------------------------------------------------------------------

type
  ExtensionEntry* = object
    id*: string
    open*: seq[uint16]
    close*: seq[uint16]
    syntax*: InlineSyntax

  ExtensionBlockEntry* = object
    id*: string
    fence*: string
    fenceChars*: seq[uint16]

  ExtensionRegistry* = object
    ## Precompiled, purely syntactic view of the registered extensions — the
    ## only thing the parser sees.
    entries*: seq[ExtensionEntry]
      ## Inline span rules, in registration order.
    blockEntries*: seq[ExtensionBlockEntry]
      ## Fenced block rules, in registration order.
    directives*: DirectiveRegistry
    fingerprint*: string
      ## One grammar fingerprint covering both seams. A directive-free registry
      ## keeps the fingerprint it had before directives existed, so no existing
      ## document re-parses.

proc emptyRegistry*(): ExtensionRegistry =
  ExtensionRegistry(entries: @[], blockEntries: @[],
                    directives: emptyDirectiveRegistry(), fingerprint: "")

func isEmpty*(r: ExtensionRegistry): bool {.inline.} =
  r.entries.len == 0 and r.blockEntries.len == 0 and r.directives.isEmpty

proc initRegistry*(extensions: seq[MarkdownExtension],
                   directives = emptyDirectiveRegistry()): ExtensionRegistry =
  # Directives alone are a non-empty grammar: only bail out when BOTH halves
  # are empty, or a directive-only configuration would parse as pure markdown.
  if extensions.len == 0 and directives.isEmpty:
    return emptyRegistry()

  var entries: seq[ExtensionEntry] = @[]
  var blockEntries: seq[ExtensionBlockEntry] = @[]
  for e in extensions:
    if e.hasInline:
      entries.add ExtensionEntry(id: e.id, open: toUtf16(e.inline.open),
                                 close: toUtf16(e.inline.close), syntax: e.inline)
    if e.hasBlock and e.blockSyntax.fence.len > 0:
      blockEntries.add ExtensionBlockEntry(id: e.id, fence: e.blockSyntax.fence,
                                           fenceChars: toUtf16(e.blockSyntax.fence))

  # Every syntax field participates: registries that differ in ANY flag must
  # never share cached parse results.
  var extParts: seq[string] = @[]
  for e in extensions:
    var parts = @[framed(e.id)]
    if e.hasInline:
      parts.add ["i", framed(e.inline.open), framed(e.inline.close),
                 $e.inline.parsesContent, $e.inline.requiresNonEmptyContent,
                 $e.inline.rejectsOpenerRun, $e.inline.rejectsCloserRun]
    if e.hasBlock:
      parts.add ["b", framed(e.blockSyntax.fence)]
    extParts.add parts.join(",")
  let extensionFingerprint = extParts.join("|")

  ExtensionRegistry(
    entries: entries, blockEntries: blockEntries, directives: directives,
    fingerprint: if directives.isEmpty: extensionFingerprint
                 else: extensionFingerprint & "~" & directives.fingerprint)

func blockEntryOpening*(r: ExtensionRegistry, line: string): (ExtensionBlockEntry, bool) =
  ## The first registered block rule whose fence opens `line` (column 0).
  ## Registration order is precedence, matching the inline rules.
  for e in r.blockEntries:
    if line.startsWith(e.fence): return (e, true)
  (ExtensionBlockEntry(), false)

func blockEntryFor*(r: ExtensionRegistry, id: string): (ExtensionBlockEntry, bool) =
  for e in r.blockEntries:
    if e.id == id: return (e, true)
  (ExtensionBlockEntry(), false)

func fenceCharsList*(r: ExtensionRegistry): seq[seq[uint16]] =
  for e in r.blockEntries: result.add e.fenceChars
