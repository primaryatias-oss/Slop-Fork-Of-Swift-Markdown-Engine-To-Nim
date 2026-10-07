## html_to_markdown.nim
## MarkdownEngine (Nim port)
##
## A lenient HTML→Markdown converter for the editor's smart-paste path.
##
## Real-world clipboard HTML (from browsers, chat UIs, word processors, note
## apps) is messy: inline styles, stray `<span>`/`<div>`/`<meta>` wrappers,
## mixed-case tags, and sometimes unclosed elements. This converter does NOT
## assume well-formed XML — it runs a tolerant tag scanner with a small nesting
## stack, unwraps unknown/styling-only tags, decodes entities, and collapses
## insignificant whitespace. It prefers robustness over completeness.
##
## Returns `false` when the input has no convertible structure (no tags), so
## the caller can fall back to the plain-text flavour.

import std/[strutils, tables, unicode]

type
  HNode = ref object
    name: string            ## "" for a text node, "#root" for the root
    attrs: Table[string, string]
    children: seq[HNode]
    text: string

func isText(n: HNode): bool {.inline.} = n.name.len == 0

const voidElements = ["br", "hr", "img", "input", "meta", "link", "source",
                      "col", "area", "base", "wbr", "embed", "param", "track"]

const blockElements = ["p", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5",
                       "h6", "table", "blockquote", "pre", "hr"]

proc newHNode(name: string, text = ""): HNode =
  HNode(name: name, attrs: initTable[string, string](), children: @[], text: text)

func htmlTrimmed(s: string): string {.inline.} =
  strip(s, chars = {' ', '\t', '\n', '\r', '\v', '\f'})

# ---------------------------------------------------------------------------
# Entities
# ---------------------------------------------------------------------------

const namedEntities = {
  "nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&",
  "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
  "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·", "copy": "©",
  "reg": "®", "trade": "™", "deg": "°", "times": "×", "divide": "÷"
}.toTable

func findSemicolon(s: string, start, limit: int): int =
  ## Index of the next `;` within `limit` characters, or -1 if a stray `&`/`<`
  ## (which cannot appear inside a well-formed reference) is hit first.
  var j = start
  let stop = min(s.len, start + limit)
  while j < stop:
    if s[j] == ';': return j
    if s[j] == '&' or s[j] == '<': return -1
    inc j
  -1

proc decodeHTMLEntities*(s: string): string =
  ## Decodes named entities plus numeric (`&#NNN;`) and hex (`&#xHH;`)
  ## character references. Malformed or unknown references are left verbatim.
  if not s.contains('&'): return s
  var i = 0
  while i < s.len:
    if s[i] != '&':
      result.add s[i]
      inc i
      continue
    let semi = findSemicolon(s, i + 1, 32)
    if semi < 0:
      result.add s[i]
      inc i
      continue
    let entity = s[i + 1 ..< semi]
    var decoded = false
    if entity.startsWith("#"):
      let numPart = entity[1 .. ^1]
      var value = -1
      try:
        if numPart.len > 0 and (numPart[0] == 'x' or numPart[0] == 'X'):
          value = parseHexInt(numPart[1 .. ^1])
        else:
          value = parseInt(numPart)
      except ValueError, IndexDefect:
        value = -1
      if value > 0 and value <= 0x10FFFF:
        result.add $Rune(value)
        i = semi + 1
        decoded = true
    else:
      let lower = entity.toLowerAscii
      if namedEntities.hasKey(entity):
        result.add namedEntities[entity]
        i = semi + 1
        decoded = true
      elif namedEntities.hasKey(lower):
        result.add namedEntities[lower]
        i = semi + 1
        decoded = true
    if not decoded:
      result.add s[i]
      inc i

# ---------------------------------------------------------------------------
# Lenient parse
# ---------------------------------------------------------------------------

func tagName(body: string): string =
  ## Leading tag name (letters/digits until whitespace or `/`), lowercased.
  for ch in body:
    if ch in {' ', '\t', '\n', '\r', '/'}: break
    result.add ch
  result = result.toLowerAscii

proc parseAttrs(body, name: string): Table[string, string] =
  ## Hand scan for `([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*("[^"]*"|'[^']*'|[^\s>]+))?`.
  result = initTable[string, string]()
  if body.len <= name.len: return
  let rest = body[name.len .. ^1]
  var i = 0
  while i < rest.len:
    while i < rest.len and rest[i] in {' ', '\t', '\n', '\r', '/'}: inc i
    if i >= rest.len: break
    if not (rest[i].isAlphaAscii or rest[i] == '_' or rest[i] == ':'):
      inc i
      continue
    let keyStart = i
    while i < rest.len and (rest[i].isAlphaNumeric or rest[i] in {'-', '_', ':', '.'}):
      inc i
    let key = rest[keyStart ..< i].toLowerAscii
    while i < rest.len and rest[i] in {' ', '\t', '\n', '\r'}: inc i
    var value = ""
    if i < rest.len and rest[i] == '=':
      inc i
      while i < rest.len and rest[i] in {' ', '\t', '\n', '\r'}: inc i
      if i < rest.len and (rest[i] == '"' or rest[i] == '\''):
        let quote = rest[i]
        inc i
        let valueStart = i
        while i < rest.len and rest[i] != quote: inc i
        value = rest[valueStart ..< i]
        if i < rest.len: inc i
      else:
        let valueStart = i
        while i < rest.len and rest[i] notin {' ', '\t', '\n', '\r', '>'}: inc i
        value = rest[valueStart ..< i]
    result[key] = decodeHTMLEntities(value)

proc parseHTML(html: string, sawTag: var bool): HNode =
  let root = newHNode("#root")
  var stack = @[root]
  let n = html.len
  var i = 0

  template top(): HNode = stack[^1]
  proc appendText(stack: var seq[HNode], s: string) =
    if s.len > 0: stack[^1].children.add newHNode("", s)

  while i < n:
    if html[i] == '<':
      # HTML comment: skip through "-->"
      if i + 4 <= n and html[i ..< min(n, i + 4)] == "<!--":
        var j = i + 4
        while j + 2 < n and not (html[j] == '-' and html[j + 1] == '-' and
                                 html[j + 2] == '>'):
          inc j
        i = if j + 2 < n: j + 3 else: n
        continue
      # Doctype / processing instruction: skip to ">"
      if i + 1 < n and (html[i + 1] == '!' or html[i + 1] == '?'):
        var j = i + 1
        while j < n and html[j] != '>': inc j
        i = if j < n: j + 1 else: n
        continue
      # Generic tag: read to the next ">"
      var j = i + 1
      while j < n and html[j] != '>': inc j
      if j >= n:
        # Unclosed "<": treat the remainder as literal text.
        stack.appendText(decodeHTMLEntities(html[i ..< n]))
        break
      let inner = html[i + 1 ..< j]
      i = j + 1
      sawTag = true

      if inner.startsWith("/"):
        let name = tagName(inner[1 .. ^1])
        var idx = -1
        for k in countdown(stack.len - 1, 0):
          if stack[k].name == name:
            idx = k
            break
        if idx >= 1: stack.setLen(idx)
      else:
        let selfClose = inner.endsWith("/")
        let body = if selfClose: inner[0 ..< inner.len - 1] else: inner
        let name = tagName(body)
        let node = newHNode(name)
        node.attrs = parseAttrs(body, name)
        top().children.add node
        if not selfClose and name notin voidElements:
          stack.add node
    else:
      var j = i
      while j < n and html[j] != '<': inc j
      stack.appendText(decodeHTMLEntities(html[i ..< j]))
      i = j
  root

# ---------------------------------------------------------------------------
# Tree helpers
# ---------------------------------------------------------------------------

proc containsBlock(node: HNode): bool =
  ## True when `node`'s subtree holds a block element, i.e. `node` wraps
  ## structure rather than a run of inline text.
  for child in node.children:
    if child.name in blockElements or containsBlock(child): return true
  false

proc findCheckbox(node: HNode): HNode =
  for child in node.children:
    if child.name == "input" and
       child.attrs.getOrDefault("type", "").toLowerAscii == "checkbox":
      return child
    let found = findCheckbox(child)
    if found != nil: return found
  nil

proc isChecked(input: HNode): bool =
  if not input.attrs.hasKey("checked"): return false
  let value = input.attrs["checked"].toLowerAscii
  value.len == 0 or value == "checked" or value == "true"

proc firstDescendant(node: HNode, name: string): HNode =
  for child in node.children:
    if child.name == name: return child
    let found = firstDescendant(child, name)
    if found != nil: return found
  nil

proc descendants(node: HNode, name: string): seq[HNode] =
  for child in node.children:
    if child.name == name: result.add child
    result.add descendants(child, name)

proc rawText(node: HNode): string =
  ## Concatenates the raw (un-collapsed) text of a node's subtree — used for
  ## code spans and fenced blocks where whitespace is significant.
  if node.isText: return node.text
  for child in node.children: result.add rawText(child)

# ---------------------------------------------------------------------------
# Whitespace / escaping
# ---------------------------------------------------------------------------

func collapseWhitespace(s: string): string =
  ## Collapses runs of insignificant whitespace to a single space, preserving a
  ## single leading/trailing space so inline runs stay separated.
  var pendingSpace = false
  for ch in s:
    if ch in {' ', '\t', '\n', '\r', '\v', '\f'}:
      pendingSpace = true
      continue
    if pendingSpace:
      result.add ' '
      pendingSpace = false
    result.add ch
  if pendingSpace: result.add ' '

func escapeMarkdown(s: string): string =
  ## Backslash-escapes markdown-significant characters in a TEXT node so pasted
  ## literal text does not re-parse as markdown. Conservative: only a leading
  ## block marker at the start of the run, plus inline emphasis/code/link
  ## delimiters, are escaped. Code spans and fences bypass this (they use
  ## `rawText`).
  if s.len == 0: return s
  var i = 0

  # Leading block marker (treat the run's start as a potential line start).
  if s[0] == '#':
    var hashes = 0
    while hashes < s.len and hashes < 6 and s[hashes] == '#': inc hashes
    if hashes < s.len and s[hashes] == ' ':
      result.add "\\#"
      i = 1
  elif s[0] == '>':
    result.add "\\>"
    i = 1
  elif s[0] == '-' or s[0] == '*' or s[0] == '+':
    if s.len > 1 and s[1] == ' ':
      result.add '\\'
      result.add s[0]
      i = 1
  elif s[0].isDigit:
    var d = 0
    while d < s.len and s[d].isDigit: inc d
    if d < s.len and (s[d] == '.' or s[d] == ')') and
       (d + 1 == s.len or s[d + 1] == ' '):
      for k in 0 ..< d: result.add s[k]
      result.add '\\'
      result.add s[d]
      i = d + 1

  # Inline delimiters, anywhere in the run.
  while i < s.len:
    case s[i]
    of '*', '_', '`', '[', ']':
      result.add '\\'
      result.add s[i]
    else:
      result.add s[i]
    inc i

func formatLinkDestination(href: string): string =
  ## Angle-wraps a destination when it contains whitespace or unbalanced
  ## parentheses, which would otherwise break the `(dest)` syntax; leaves clean
  ## destinations bare.
  var hasWhitespace = false
  for ch in href:
    if ch in {' ', '\t', '\n', '\r'}:
      hasWhitespace = true
      break
  var depth = 0
  var balanced = true
  for ch in href:
    if ch == '(':
      inc depth
    elif ch == ')':
      dec depth
      if depth < 0:
        balanced = false
        break
  if depth != 0: balanced = false
  if not hasWhitespace and balanced: return href
  "<" & href.replace("<", "%3C").replace(">", "%3E") & ">"

func indentLines(s, prefix: string): string =
  var lines: seq[string] = @[]
  for line in s.split('\n'):
    lines.add(if line.len == 0: "" else: prefix & line)
  lines.join("\n")

# ---------------------------------------------------------------------------
# Inline rendering
# ---------------------------------------------------------------------------

proc renderInlineNode(node: HNode): string

proc renderInlineChildren(children: seq[HNode]): string =
  for child in children: result.add renderInlineNode(child)

proc renderInlineNode(node: HNode): string =
  if node.isText: return escapeMarkdown(collapseWhitespace(node.text))
  case node.name
  of "strong", "b": "**" & renderInlineChildren(node.children) & "**"
  of "em", "i": "*" & renderInlineChildren(node.children) & "*"
  of "del", "s", "strike": "~~" & renderInlineChildren(node.children) & "~~"
  of "mark": "==" & renderInlineChildren(node.children) & "=="
  of "code": "`" & rawText(node) & "`"
  of "br": "  \n"                       # CommonMark hard break
  of "a":
    let inner = renderInlineChildren(node.children)
    let href = node.attrs.getOrDefault("href", "")
    if href.len == 0: inner
    else: "[" & inner & "](" & formatLinkDestination(href) & ")"
  of "input": ""                        # checkboxes handled at list-item level
  of "head", "style", "script", "title": ""
                                        # metadata / code-for-the-browser —
                                        # unwrapping would leak CSS/JS as text
  else:
    # Unknown / styling-only tags (span, font, sup, …) → unwrap.
    renderInlineChildren(node.children)

# ---------------------------------------------------------------------------
# Block rendering
# ---------------------------------------------------------------------------

proc renderBlocks(children: seq[HNode]): string
proc renderBlock(node: HNode): (string, bool)
proc renderList(node: HNode, ordered: bool, depth: int): string

proc renderPre(node: HNode): string =
  var source = firstDescendant(node, "code")
  if source == nil: source = node
  var language = ""
  if source.attrs.hasKey("class"):
    for token in source.attrs["class"].split(' '):
      if token.startsWith("language-"):
        language = token["language-".len .. ^1]
        break
  var code = rawText(source)
  if code.startsWith("\n"): code = code[1 .. ^1]
  if code.endsWith("\n"): code = code[0 ..< code.len - 1]
  "```" & language & "\n" & code & "\n```"

proc renderTable(node: HNode): string =
  var rows: seq[seq[string]] = @[]
  for tr in descendants(node, "tr"):
    var cells: seq[string] = @[]
    for cell in tr.children:
      if cell.name == "td" or cell.name == "th":
        cells.add htmlTrimmed(renderInlineChildren(cell.children))
          .replace("|", "\\|").replace("\n", " ")
    if cells.len > 0: rows.add cells
  if rows.len == 0: return ""

  var columns = 0
  for row in rows: columns = max(columns, row.len)
  if columns == 0: return ""

  proc pad(row: seq[string]): seq[string] =
    result = row
    for _ in row.len ..< columns: result.add ""

  var lines: seq[string] = @[]
  lines.add "| " & pad(rows[0]).join(" | ") & " |"
  var separator = "|"
  for _ in 0 ..< columns: separator.add "---|"
  lines.add separator
  for i in 1 ..< rows.len:
    lines.add "| " & pad(rows[i]).join(" | ") & " |"
  lines.join("\n")

proc renderListItem(li: HNode, ordered: bool, number, depth: int): string =
  # One TAB per nesting level — the editor's native indent unit; two spaces
  # would parse as a level but render barely indented.
  let indent = repeat('\t', depth)

  var marker: string
  let box = findCheckbox(li)
  if box != nil:
    marker = if isChecked(box): "- [x] " else: "- [ ] "
  else:
    marker = if ordered: $number & ". " else: "- "

  # Walk the item's children, keeping the leading inline run as the head line,
  # block children (paragraphs, etc.) as indented continuation blocks, and
  # lists as nested lists. A `<div>` is a transparent wrapper.
  var head = ""
  var headSet = false
  var blocks: seq[string] = @[]       # non-list continuation blocks
  var nestedLists: seq[string] = @[]  # already carry their depth+1 indent
  var inlineRun: seq[HNode] = @[]

  proc flushInline() =
    if inlineRun.len == 0: return
    let rendered = htmlTrimmed(renderInlineChildren(inlineRun))
    inlineRun.setLen(0)
    if rendered.len == 0: return
    if not headSet:
      head = rendered
      headSet = true
    else:
      blocks.add rendered

  proc walk(children: seq[HNode]) =
    for child in children:
      case child.name
      of "ul", "ol":
        flushInline()
        let sub = renderList(child, child.name == "ol", depth + 1)
        if sub.len > 0: nestedLists.add sub
      of "div":
        walk(child.children)
      of "p", "blockquote", "pre", "table", "hr",
         "h1", "h2", "h3", "h4", "h5", "h6":
        flushInline()
        let (rendered, ok) = renderBlock(child)
        if ok and rendered.len > 0: blocks.add rendered
      else:
        # Same rule as `renderBlock`: an unknown wrapper around block content
        # is transparent, like a `<div>`.
        if containsBlock(child): walk(child.children)
        else: inlineRun.add child
  walk(li.children)
  flushInline()
  if not headSet and blocks.len > 0:
    head = blocks[0]
    blocks.delete(0)
    headSet = true

  # Chat UIs render task lists as literal "[ ] text" in plain `<li>`s; the text
  # escaping turned that into "\[ \] ", which never re-renders as a checkbox.
  # Reclaim the escaped prefix as a real task marker.
  if box == nil and not ordered:
    if head.startsWith("\\[ \\] "):
      marker = "- [ ] "
      head = head[6 .. ^1]
    elif head.startsWith("\\[x\\] ") or head.startsWith("\\[X\\] "):
      marker = "- [x] "
      head = head[6 .. ^1]

  # Continuation lines align under the item's text (past the marker).
  let contIndent = indent & repeat(' ', marker.len)

  # First line: marker + head; re-indent any embedded (hard-break) newline so
  # the continuation stays inside the item.
  let headLines = head.split('\n')
  result = indent & marker & (if headLines.len > 0: headLines[0] else: "")
  for k in 1 ..< headLines.len:
    result.add "\n" & (if headLines[k].len == 0: "" else: contIndent & headLines[k])
  for blk in blocks:
    result.add "\n\n" & indentLines(blk, contIndent)
  for nested in nestedLists:
    result.add "\n" & nested

proc renderList(node: HNode, ordered: bool, depth: int): string =
  var items: seq[string] = @[]
  var number = 0
  if ordered and node.attrs.hasKey("start"):
    try:
      number = parseInt(node.attrs["start"]) - 1
    except ValueError:
      number = 0
  for child in node.children:
    case child.name
    of "li":
      inc number
      items.add renderListItem(child, ordered, number, depth)
    of "ul", "ol":
      # Some engines indent a bullet by hanging the sublist BESIDE the `<li>`
      # instead of inside it. Invalid per spec, drawn correctly by every
      # browser, so only a reader loses it: ignoring a non-`<li>` child dropped
      # every item the sublist held.
      let sub = renderList(child, child.name == "ol", depth + 1)
      if sub.len > 0: items.add sub
    else:
      discard
  items.join("\n")

proc renderBlock(node: HNode): (string, bool) =
  ## Renders a block-level element, or returns `false` when `node` is not a
  ## block (so the caller folds it into the surrounding inline paragraph).
  case node.name
  of "h1", "h2", "h3", "h4", "h5", "h6":
    var level = 1
    try:
      level = parseInt(node.name[1 .. ^1])
    except ValueError:
      level = 1
    (repeat('#', level) & " " & htmlTrimmed(renderInlineChildren(node.children)), true)
  of "p":
    (htmlTrimmed(renderInlineChildren(node.children)), true)
  of "hr":
    ("----", true)
  of "ul":
    (renderList(node, false, 0), true)
  of "ol":
    (renderList(node, true, 0), true)
  of "blockquote":
    var lines: seq[string] = @[]
    for line in renderBlocks(node.children).split('\n'):
      lines.add(if line.len == 0: ">" else: "> " & line)
    (lines.join("\n"), true)
  of "pre":
    (renderPre(node), true)
  of "table":
    (renderTable(node), true)
  of "div":
    (renderBlocks(node.children), true)
  of "html", "body":
    # Some sources put a full document on the clipboard; without these cases
    # the wrapper falls into the inline unwrap and glues every block's text
    # into one run.
    (renderBlocks(node.children), true)
  of "head", "style", "script", "title":
    ("", true)        # metadata / code-for-the-browser — never content
  else:
    # Any other element — a web component, a `<section>`, even a `<span>` — is
    # a transparent wrapper when it holds block content. Folding it into the
    # inline run would unwrap the table or list inside as well and glue all of
    # its text into one line.
    if containsBlock(node): (renderBlocks(node.children), true)
    else: ("", false)

proc renderBlocks(children: seq[HNode]): string =
  var blocks: seq[string] = @[]
  var inlineBuffer = ""
  # Consecutive bare `<li>` siblings (some engines strip the ul/ol wrapper on
  # within-list copies) — collected into ONE tight list, not blank-line spaced.
  var looseItems: seq[string] = @[]

  proc flushInline() =
    let trimmed = htmlTrimmed(inlineBuffer)
    if trimmed.len > 0: blocks.add trimmed
    inlineBuffer = ""

  proc flushItems() =
    if looseItems.len > 0:
      blocks.add looseItems.join("\n")
      looseItems.setLen(0)

  for child in children:
    if child.isText:
      # Whitespace between bare `<li>` siblings must not split the run.
      if looseItems.len > 0 and htmlTrimmed(child.text).len == 0:
        continue
      flushItems()
      inlineBuffer.add renderInlineNode(child)
      continue
    if child.name == "li":
      flushInline()
      looseItems.add renderListItem(child, false, 1, 0)
      continue
    flushItems()
    let (rendered, isBlock) = renderBlock(child)
    if isBlock:
      flushInline()
      if rendered.len > 0: blocks.add rendered
    else:
      inlineBuffer.add renderInlineNode(child)
  flushInline()
  flushItems()
  blocks.join("\n\n")

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc markdownFromHTML*(html: string): (string, bool) =
  ## `false` when the input has no convertible structure, so the caller can
  ## fall back to the plain-text flavour.
  var sawTag = false
  let root = parseHTML(html, sawTag)
  if not sawTag: return ("", false)
  let rendered = htmlTrimmed(renderBlocks(root.children))
  if rendered.len == 0: ("", false) else: (rendered, true)
