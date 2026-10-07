## html_renderer.nim
## MarkdownEngine (Nim port)
##
## A clean Markdown → HTML fragment renderer.
##
## The editor's storage holds RAW markdown styled in place (syntax markers
## merely coloured, thematic breaks drawn by the renderer, tables as artefacts),
## so a naive copy serialises junk. This walks the semantic AST and emits a
## clean HTML fragment — a sequence of block elements, no `<html>`/`<body>`
## wrapper — that the copy path wraps and puts on the clipboard.

import std/[strutils, tables]
import ./ranges, ./utf16text, ./extension, ./directive, ./directive_scanner
import ./inline_parser, ./ast, ./table as tbl

type
  Env = object
    ## Extension and directive lookup threaded through the render walk.
    registry: ExtensionRegistry
    byID: Table[string, MarkdownExtension]
    directivesByID: Table[string, MarkdownDirective]

func directiveFor(env: Env, nodeID: string): (MarkdownDirective, bool) =
  ## The directive behind an AST node id, or `false` when the node is an
  ## ordinary extension span.
  let (id, isDirective) = directiveIDForNodeID(nodeID)
  if not isDirective: return (nil, false)
  if env.directivesByID.hasKey(id): (env.directivesByID[id], true)
  else: (nil, false)

func escapeHTML*(s: string): string =
  result = newStringOfCap(s.len)
  for ch in s:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add ch

# ---------------------------------------------------------------------------
# Autolinking
# ---------------------------------------------------------------------------

import ./ast_styler as styler_detect

proc escapeAndAutolink(s: string): string =
  ## Escape a text run, wrapping bare URLs/emails in anchors.
  ##
  ## The editor's styler linkifies these with the same detector, but rich-paste
  ## consumers take the clipboard's HTML flavour verbatim and never run their
  ## own link detection on it — without a real `<a>`, a URL that is clickable
  ## in the editor pastes as dead text. Code spans never reach this path (they
  ## are their own inline node), matching the styler's in-code exclusion.
  let t = initText(s)
  let matches = styler_detect.detectUrls(t, t.fullRange)
  if matches.len == 0: return escapeHTML(s)
  var cursor = 0
  for match in matches:
    result.add escapeHTML(t.substring(rng(cursor, match.location - cursor)))
    let href = styler_detect.urlFromDetected(t, match)
    result.add "<a href=\"" & escapeHTML(href) & "\">" &
               escapeHTML(t.substring(match)) & "</a>"
    cursor = maxRange(match)
  result.add escapeHTML(t.substring(rng(cursor, t.len - cursor)))

# ---------------------------------------------------------------------------
# Inlines
# ---------------------------------------------------------------------------

proc renderInlines(nodes: seq[InlineNode], t: Utf16Text, env: Env,
                   linkable = true): string

proc directiveHTML(directive: MarkdownDirective, node: InlineNode,
                   bodyHTML: string, t: Utf16Text): string =
  ## Arguments are recovered from the prefix marker, exactly as the styler
  ## does, so HTML and on-screen styling can never disagree about what was
  ## passed.
  let prefix = if node.markers.len > 0: node.markers[0] else: node.range
  let (argRange, hasArgs) = argumentsRangeInPrefix(t, prefix)
  let arguments = parseArguments(t, argRange, hasArgs, directive.syntax.parameters)
  directive.html(arguments, bodyHTML)

proc renderInline(node: InlineNode, t: Utf16Text, env: Env,
                  linkable: bool): string =
  case node.kind
  of inText:
    let s = t.substring(node.range)
    if linkable: escapeAndAutolink(s) else: escapeHTML(s)

  of inCode:
    "<code>" & escapeHTML(t.substring(node.contentRange)) & "</code>"

  of inEmphasis:
    let inner = renderInlines(node.children, t, env, linkable)
    case node.emphasis
    of ekItalic: "<em>" & inner & "</em>"
    of ekBold: "<strong>" & inner & "</strong>"
    of ekBoldItalic: "<strong><em>" & inner & "</em></strong>"

  of inLink:
    # `linkable` is false inside an explicit link's title text, where wrapping
    # a URL-shaped run in its own anchor would nest `<a>` inside `<a>`.
    "<a href=\"" & escapeHTML(t.substring(node.urlRange)) & "\">" &
      renderInlines(node.children, t, env, false) & "</a>"

  of inImage:
    "<img src=\"" & escapeHTML(t.substring(node.urlRange)) & "\" alt=\"" &
      escapeHTML(t.substring(node.contentRange)) & "\">"

  of inWikiLink:
    escapeHTML(t.substring(node.contentRange))

  of inImageEmbed:
    let target = escapeHTML(t.substring(node.contentRange))
    "<img src=\"" & target & "\" alt=\"" & target & "\">"

  of inExt:
    # A self-contained directive has no body; a container's body is its content
    # range.
    let (directive, isDirective) = env.directiveFor(node.extensionID)
    if isDirective:
      let inner =
        if node.markers.len == 0: ""
        elif node.children.len == 0: escapeHTML(t.substring(node.contentRange))
        else: renderInlines(node.children, t, env)
      directiveHTML(directive, node, inner, t)
    elif not env.byID.hasKey(node.extensionID):
      escapeHTML(t.substring(node.range))          # unknown id → literal
    else:
      let inner =
        if node.children.len == 0: escapeHTML(t.substring(node.contentRange))
        else: renderInlines(node.children, t, env, linkable)
      env.byID[node.extensionID].html(inner)

  of inInlineLatex:
    escapeHTML(t.substring(node.range))

  of inEscape:
    escapeHTML(t.substring(node.contentRange))

proc renderInlines(nodes: seq[InlineNode], t: Utf16Text, env: Env,
                   linkable = true): string =
  for node in nodes:
    result.add renderInline(node, t, env, linkable)

# ---------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------

func stripQuoteMarkers(line: string): string =
  ## Drop leading indent (≤3 spaces/tabs) then one-or-more `>` each with an
  ## optional trailing space, matching the block styler's marker scan.
  var i = 0
  var indent = 0
  while i < line.len and (line[i] == ' ' or line[i] == '\t') and indent < 3:
    inc i
    inc indent
  while i < line.len and line[i] == '>':
    inc i
    if i < line.len and (line[i] == ' ' or line[i] == '\t'): inc i
  line[i .. ^1]

proc renderBlockquote(r: Range, t: Utf16Text, env: Env): string =
  ## Blockquote inlines are parsed over the block range INCLUDING the `> `
  ## markers, so strip the markers per line and re-parse the content clean.
  var kept: seq[string] = @[]
  for line in t.substring(r).split('\n'):
    let stripped = stripQuoteMarkers(line)
    if stripped.len > 0: kept.add stripped
  let joined = kept.join("\n")
  let sub = initText(joined)
  "<blockquote>" & renderInlines(parseInline(joined, env.registry), sub, env) &
    "</blockquote>"

func isFenceLine(line: string): bool {.inline.} =
  ## The parser only produces column-0 backtick fences, so match that contract
  ## when stripping the closing fence line.
  line.startsWith("```")

func fenceLanguage(line: string): string =
  ## Language info-string from an opening fence line (chars after the
  ## backticks).
  var i = 0
  while i < line.len and line[i] == '`': inc i
  trimWhitespace(line[i .. ^1])

proc renderCodeBlock(r: Range, t: Utf16Text): string =
  ## Fenced code: drop the opening ```lang / closing ``` fence lines, escape
  ## the body.
  var lines = t.substring(r).split('\n')
  if lines.len > 0 and lines[^1] == "":
    lines.setLen(lines.len - 1)                  # trailing-newline artifact

  let language = fenceLanguage(if lines.len > 0: lines[0] else: "")
  var body = if lines.len > 1: lines[1 .. ^1] else: @[]
  if body.len > 0 and isFenceLine(body[^1]):
    body.setLen(body.len - 1)

  let escaped = escapeHTML(body.join("\n"))
  if language.len > 0:
    "<pre><code class=\"language-" & escapeHTML(language) & "\">" & escaped &
      "</code></pre>"
  else:
    "<pre><code>" & escaped & "</code></pre>"

proc renderTableBlock(r: Range, t: Utf16Text): string =
  let raw = t.substring(r)
  let (parsed, ok) = parseTableSource(raw)
  if not ok:
    return "<pre>" & escapeHTML(strip(raw, chars = {'\n', '\r'})) & "</pre>"
  var head = ""
  for cell in parsed.header: head.add "<th>" & escapeHTML(cell) & "</th>"
  var body = ""
  for row in parsed.rows:
    body.add "<tr>"
    for cell in row: body.add "<td>" & escapeHTML(cell) & "</td>"
    body.add "</tr>"
  "<table><thead><tr>" & head & "</tr></thead><tbody>" & body & "</tbody></table>"

proc renderListItem(item: ListItem, t: Utf16Text, env: Env): string =
  let content = renderInlines(item.inlines, t, env)
  if item.hasCheckbox:
    # GFM task markup so markdown consumers restore `- [ ]` on paste. Rich
    # targets get this stripped to a plain bullet by the clipboard writer.
    let box = if item.checked: "<input type=\"checkbox\" checked disabled> "
              else: "<input type=\"checkbox\" disabled> "
    "<li>" & box & content & "</li>"
  else:
    "<li>" & content & "</li>"

proc renderListLevel(items: seq[ListItem], index: var int, indent: int,
                     t: Utf16Text, env: Env): string =
  ## One nesting level, consuming items until one is shallower than `indent`.
  ##
  ## `ListItem.indent` counts raw leading space/tab CHARACTERS, not levels, so
  ## depth is read as a stack (deeper pushes, shallower pops) instead of divided
  ## by a fixed unit — a tab-indented, a 2-space and a 4-space list then all
  ## nest the same way.
  var pieces: seq[string] = @[]
  var currentOrdered = false
  var haveOrdered = false
  var buffer: seq[string] = @[]

  proc flush() =
    if not haveOrdered or buffer.len == 0: return
    let tag = if currentOrdered: "ol" else: "ul"
    pieces.add "<" & tag & ">\n" & buffer.join("\n") & "\n</" & tag & ">"
    buffer.setLen(0)

  while index < items.len:
    let item = items[index]
    if item.indent < indent: break
    if item.indent > indent:
      let sub = renderListLevel(items, index, item.indent, t, env)
      # The sublist belongs INSIDE the item it hangs under, before that item's
      # `</li>`. A deeper item with nothing above it (a document opening on an
      # indented bullet) stands alone.
      if buffer.len > 0 and buffer[^1].endsWith("</li>"):
        buffer[^1] = buffer[^1][0 ..< buffer[^1].len - 5] & "\n" & sub & "\n</li>"
      else:
        flush()
        pieces.add sub
      continue
    if not haveOrdered or currentOrdered != item.ordered:
      flush()
      currentOrdered = item.ordered
      haveOrdered = true
    buffer.add renderListItem(item, t, env)
    inc index
  flush()
  pieces.join("\n")

proc renderList(items: seq[ListItem], t: Utf16Text, env: Env): string =
  ## Emit `<ul>`/`<ol>` groups, switching container when ordered-ness flips and
  ## opening a nested list inside the preceding `<li>` when an item is indented
  ## deeper.
  var index = 0
  # The shallowest item is the outer level: starting at the FIRST item's indent
  # dropped every shallower item after it (a copy opening on a sub-item).
  var minIndent = 0
  if items.len > 0:
    minIndent = items[0].indent
    for item in items: minIndent = min(minIndent, item.indent)
  renderListLevel(items, index, minIndent, t, env)

proc renderBlock(node: BlockNode, t: Utf16Text, env: Env): (string, bool) =
  case node.kind
  of bnHeading:
    let l = min(max(node.level, 1), 6)
    ("<h" & $l & ">" & renderInlines(node.inlines, t, env) & "</h" & $l & ">", true)

  of bnParagraph:
    ("<p>" & renderInlines(node.inlines, t, env) & "</p>", true)

  of bnBlockquote:
    (renderBlockquote(node.range, t, env), true)

  of bnList:
    (renderList(node.items, t, env), true)

  of bnCodeBlock:
    (renderCodeBlock(node.range, t), true)

  of bnBlockLatex:
    ("<pre>" & escapeHTML(strip(t.substring(node.range), chars = {'\n', '\r'})) &
       "</pre>", true)

  of bnTable:
    (renderTableBlock(node.range, t), true)

  of bnThematicBreak:
    ("<hr>", true)

  of bnBlank:
    ("", false)

  of bnExt:
    if not env.byID.hasKey(node.ext.extensionID):
      ("<p>" & escapeHTML(strip(t.substring(node.ext.range), chars = {'\n', '\r'})) &
         "</p>", true)
    else:
      # Content lines are separate lines of one block — keep them as `<br>`
      # breaks so multi-line bodies don't collapse to one line.
      let inner = strip(renderInlines(node.ext.inlines, t, env),
                        chars = {'\n', '\r'}).replace("\n", "<br>\n")
      (env.byID[node.ext.extensionID].html(inner), true)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc renderHTML*(markdown: string, extensions: seq[MarkdownExtension] = @[],
                 directives: seq[MarkdownDirective] = @[],
                 directiveSettings = defaultDirectiveSettings): string =
  ## Render `markdown` to an HTML fragment (block elements joined by newlines).
  ## Extensions render their spans (e.g. `<mark>` for highlight); an
  ## unregistered extension's syntax stays literal text.
  let t = initText(markdown)
  var env = Env(registry: initRegistry(extensions,
                                       initDirectiveRegistry(directives, directiveSettings)),
                byID: initTable[string, MarkdownExtension](),
                directivesByID: initTable[string, MarkdownDirective]())
  for ext in extensions: env.byID[ext.id] = ext
  for d in directives: env.directivesByID[d.id] = d

  var pieces: seq[string] = @[]
  for node in parseDocument(t, registry = env.registry):
    let (html, emit) = renderBlock(node, t, env)
    if emit: pieces.add html
  pieces.join("\n")
