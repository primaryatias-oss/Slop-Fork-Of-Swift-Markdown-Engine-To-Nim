## test_directives.nim
## The directive seam: parsing, argument coercion, composition and styling.
##
## Ported from `DirectiveParserTests.swift`, `DirectiveArgumentTests.swift`,
## `DirectiveCompositionTests.swift`, `DirectiveStylingTests.swift`,
## `DirectiveGlyphTests.swift` and `DirectiveHTMLTests.swift`.

import std/[unittest, sequtils]
import markdownengine
import ./directive_fixtures

let parserRegistry = initRegistry(@[], initDirectiveRegistry(@[
  sizedDirective(), tintDirective(), markerDirective(),
  wildthinkDirective(), opaqueDirective(), eitherDirective()]))

proc directiveNodes(text: string,
                    registry = parserRegistry): seq[InlineNode] =
  ## Every directive node in the parse, flattened. Directives project as
  ## extension-shaped nodes under the reserved id namespace.
  var found: seq[InlineNode] = @[]
  proc walk(nodes: seq[InlineNode]) =
    for node in nodes:
      if node.isDirectiveNode: found.add node
      walk(node.children)
  walk(parseInline(text, registry))
  found

proc ids(text: string, registry = parserRegistry): seq[string] =
  for node in directiveNodes(text, registry):
    let (id, ok) = directiveIDForNodeID(node.extensionID)
    if ok: result.add id

proc bodyOf(text: string): string =
  let nodes = directiveNodes(text)
  if nodes.len == 0: return ""
  initText(text).substring(nodes[0].contentRange)

suite "directives — recognition":

  test "a registered container directive parses":
    check ids("@font(size: 18){hello}") == @["font"]
    check bodyOf("@font(size: 18){hello}") == "hello"

  test "a registered self-contained directive parses":
    check ids("text @marker more") == @["marker"]

  test "without a registered directive, the name stays literal":
    check ids("@unknown(size: 18){hello}").len == 0
    check ids("@font(size: 18){hello}", emptyRegistry()).len == 0

  test "the whole call is claimed, markers plus body":
    let text = "@font(size: 18){hello}"
    let t = initText(text)
    let node = directiveNodes(text)[0]
    check node.range == rng(0, t.len)
    check t.substring(node.markers[0]) == "@font(size: 18){"
    check t.substring(node.markers[1]) == "}"

  test "a self-contained call carries no markers — it renders literally":
    check directiveNodes("@marker")[0].markers.len == 0

suite "directives — boundary rule":

  test "a directive must open at a boundary, not mid-word":
    check ids("a@marker").len == 0
    check ids("word@font(size: 18){x}").len == 0

  test "an email address never opens a directive":
    # `wildthink` IS registered — only the boundary rule saves this.
    check ids("mail jason@example.com now").len == 0

  test "a marker run stays literal":
    check ids("@@marker").len == 0

  test "punctuation and line starts are valid boundaries":
    check ids("(@marker)") == @["marker"]
    check ids("line one\n@marker") == @["marker"]
    check ids("> @marker") == @["marker"]

  test "markup delimiters are boundaries — a directive can abut emphasis":
    # An allow-list of "opening punctuation" silently dropped every one of
    # these, because the preceding character is a markup delimiter. Only word
    # characters may reject.
    check ids("*@font(size: 18){x}*") == @["font"]
    check ids("**@font(size: 18){x}**") == @["font"]
    check ids("_@font(size: 18){x}_") == @["font"]
    check ids("- @marker") == @["marker"]
    check ids("1. @marker") == @["marker"]
    check ids("#@marker") == @["marker"]

  test "a digit is a word character, so it rejects":
    check ids("v2@marker").len == 0

  test "an escaped marker stays literal":
    check ids("\\@marker").len == 0

suite "directives — form enforcement":

  test "a container call without a body stays literal":
    check ids("@font(size: 18)").len == 0

  test "a self-contained call with a body stays literal":
    check ids("@marker{x}").len == 0

  test "an either-form directive accepts both shapes":
    check ids("@note") == @["note"]
    check ids("@note{body}") == @["note"]

suite "directives — delimiter scanning":

  test "braces nest inside a body":
    check bodyOf("@font(size: 18){a {b} c}") == "a {b} c"

  test "parens nest inside an argument list":
    check bodyOf("@font(size: max(18, 20)){x}") == "x"

  test "the scanner treats an escaped brace as body text, not a closer":
    let t = initText("@font(size: 18){a \\} b}")
    let (match, ok) = matchDirective(t, t.len, 0,
                                     initDirectiveRegistry(@[sizedDirective()]))
    check ok
    check t.substring(match.bodyRange) == "a \\} b"

  test "in the full parse an interior escape keeps the call literal":
    # The escape pass claims `\}` before the link-family pass runs, and a
    # candidate overlapping a claimed span is rejected. Directives inherit
    # that rule verbatim: `[a \* b](url)` and `==a \* b==` are rejected the
    # same way. The scanner still measures the body correctly (above), so the
    # day escapes stop pre-claiming, directives need no change.
    check ids("@font(size: 18){a \\} b}").len == 0

  test "a brace inside a quoted argument does not open a body":
    check bodyOf("@font(family: \"a{b\"){x}") == "x"

  test "an unbalanced call stays literal":
    check ids("@font(size: 18{hello}").len == 0
    check ids("@font(size: 18){hello").len == 0

  test "a directive never spans a line break":
    check ids("@font(size: 18){a\nb}").len == 0
    check ids("@font(size:\n18){a}").len == 0

suite "directives — precedence":

  test "a directive inside a code span never fires":
    check ids("`@font(size: 18){x}`").len == 0

  test "a directive inside inline LaTeX never fires":
    check ids("$@font(size: 18){x}$").len == 0

  test "a directive inside a link's text still parses":
    check ids("[see @font(size: 18){this}](url)") == @["font"]

suite "directives — body parsing":

  test "a container body is re-parsed as markdown":
    check directiveNodes("@font(size: 18){**bold**}")[0].children
      .anyIt(it.kind == inEmphasis)

  test "an opaque directive keeps its body unparsed":
    check directiveNodes("@raw{**bold**}")[0].children.len == 0

  test "directives nest":
    check ids("@font(size: 18){@color(red){x}}") == @["font", "color"]

suite "directives — markers":

  test "an alternate marker can be registered":
    let registry = initRegistry(@[], initDirectiveRegistry(@[backslashDirective()]))
    check ids("\\bigger{x}", registry) == @["bigger"]
    # The default marker is inert for a directive that overrode it.
    check ids("@bigger{x}", registry).len == 0

  test "a multi-scalar marker is rejected at registration, not half-matched":
    # Marker dispatch is one table probe per character on the parse hot path,
    # which requires a single UTF-16 code unit. An emoji marker must drop out
    # at registration rather than matching a lone surrogate.
    let rocketUnits = toUtf16("\u{1F680}")
    check rocketUnits.len == 2                 # a surrogate pair
    let emojiDirective = newDirective(
      initDirectiveSyntax("rocket", dfSelfContained, marker = rocketUnits[0]))
    # The port cannot express a multi-unit marker in the first place: the
    # field is a single `uint16`. What the Swift rejected at registration is
    # unrepresentable here, so the check is that a LONE surrogate still does
    # not match the full emoji.
    let registry = initRegistry(@[], initDirectiveRegistry(@[emojiDirective]))
    check ids("\u{1F680}rocket", registry).len == 0

  test "markers coexist":
    let registry = initRegistry(@[], initDirectiveRegistry(
      @[sizedDirective(), backslashDirective()]))
    check ids("@font(size: 18){a} and \\bigger{b}", registry) ==
      @["font", "bigger"]

suite "directives — token projection":

  test "a directive projects a token, so caret reveal and copy see it":
    let tokens = parseTokens(initText("@font(size: 18){hello}"), parserRegistry)
    check tokens.anyIt(it.kind == tkExtensionSpan and
                       it.extensionID == directiveNodeID("font"))

suite "directives — grammar fingerprint":

  test "registering a directive changes the grammar fingerprint":
    let without = initRegistry(@[newHighlightExtension()])
    let with = initRegistry(@[newHighlightExtension()],
                            initDirectiveRegistry(@[sizedDirective()]))
    check without.fingerprint != with.fingerprint

  test "an equal directive set produces an equal fingerprint":
    let a = initRegistry(@[], initDirectiveRegistry(@[sizedDirective()]))
    let b = initRegistry(@[], initDirectiveRegistry(@[sizedDirective()]))
    check a.fingerprint == b.fingerprint

  test "changing the marker changes the fingerprint":
    let atSign = initDirectiveRegistry(@[sizedDirective()],
      DirectiveRegistrySettings(defaultMarker: uint16(ord('@'))))
    let slash = initDirectiveRegistry(@[sizedDirective()],
      DirectiveRegistrySettings(defaultMarker: uint16(ord('/'))))
    check atSign.fingerprint != slash.fingerprint

  test "a directive-only registry is not empty":
    let registry = initRegistry(@[], initDirectiveRegistry(@[sizedDirective()]))
    check not registry.isEmpty
    check registry.fingerprint.len > 0

suite "directives — pre-claimed spans in a body (known limitation)":
  # A body holding a span claimed by an EARLIER pass rejects the whole
  # directive. Pinned deliberately: this is the documented limitation, and the
  # follow-up that lifts it should flip these, not delete them.

  test "a code span in the body keeps the whole directive literal":
    var cfg = initConfiguration()
    cfg.directives = @[sizedDirective()]
    let nodes = parseInline("@font(size: 18){a `b` c}", cfg.extensionRegistry())
    check not nodes.anyIt(it.kind == inExt)

  test "a backslash escape in the body keeps the whole directive literal":
    var cfg = initConfiguration()
    cfg.directives = @[sizedDirective()]
    let nodes = parseInline(r"@font(size: 18){a \* c}", cfg.extensionRegistry())
    check not nodes.anyIt(it.kind == inExt)

  test "inline math, links and emphasis all compose inside a body":
    # The limitation is specific to spans claimed BEFORE this pass. Anything
    # claimed in the same pass or later composes normally, so the rejection
    # rule is narrower than "no other construct in a body".
    var cfg = initConfiguration()
    cfg.directives = @[sizedDirective()]
    let registry = cfg.extensionRegistry()
    for source in ["@font(size: 18){a $x^2$ c}",
                   "@font(size: 18){a [l](u) c}",
                   "@font(size: 18){a *b* c}"]:
      checkpoint(source)
      check parseInline(source, registry).anyIt(it.kind == inExt)
