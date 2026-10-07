## test_editor.nim
## The editor: formatting actions, typing helpers, undo, find and the
## selection-driven restyle.
##
## Ported from `FormattingActionTests.swift`, `ListHandlerCodeContextTests.swift`,
## `BlockquotePasteTests.swift`, `PasteStructureGuardTests.swift`,
## `PerDocumentUndoTests.swift`, `FindHighlightRestoreTests.swift`,
## `ScrollMemoryTests.swift`, `BottomOverscrollPolicyTests.swift` and the
## coordinator half of `OrderedListDisplayNumberingTests.swift`.
##
## The Swift drove all of this through an `NSTextView` and its coordinator;
## here the same behaviour lives on `mdui/editor`, which owns the storage,
## the selection and the undo stack directly. The assertions are the Swift's.

import std/[unittest, strutils, strformat]
import markdownengine
import mdui/[fontmanager, textstorage, editor]

let fonts = newFontManager()

proc newTestEditor(text = "", selection = caretAt(0)): Editor =
  var cfg = initConfiguration()
  # Formatting toggles resolve `==`/`~~` spans through extension tokens, so
  # the test editor registers both, the way a real embedder would.
  cfg.extensions = @[newHighlightExtension(), newStrikethroughExtension()]
  result = newEditor(fonts, cfg)
  result.setViewport(0, 0, 800, 600)
  result.setDocument(text)
  result.setSelection(selection)

proc request(kind: EditorRequestKind, text = "", level = 0): EditorRequest =
  EditorRequest(kind: kind, text: text, level: level)

suite "formatting actions — inline toggles":

  test "bold wraps the selection and keeps it selected":
    let e = newTestEditor("hello world", rng(0, 5))
    e.applyRequest(request(erApplyBold))
    check e.displayText == "**hello** world"
    check e.selection == rng(2, 5)

  test "bold with a caret wraps the word under it":
    let e = newTestEditor("hello world", caretAt(1))
    e.applyRequest(request(erApplyBold))
    check e.displayText == "**hello** world"

  test "bold preserves the caret's offset within the word":
    let e = newTestEditor("hello world", caretAt(2))
    e.applyRequest(request(erApplyBold))
    check e.displayText == "**hello** world"
    check e.selection.location == 4

  test "bold between words inserts an empty pair":
    let e = newTestEditor("hello  world", caretAt(6))
    e.applyRequest(request(erApplyBold))
    check e.displayText == "hello **** world"
    check e.selection.location == 8

  test "bold toggles off from a selection inside the markers":
    let e = newTestEditor("aa **bb** cc", rng(5, 2))
    e.applyRequest(request(erApplyBold))
    check e.displayText == "aa bb cc"

  test "bold toggles off from a caret inside the span":
    let e = newTestEditor("aa **bold** cc", caretAt(7))
    e.applyRequest(request(erApplyBold))
    check e.displayText == "aa bold cc"
    check e.selection.location == 3

  test "bold on bold-italic leaves italic":
    let e = newTestEditor("***both***", rng(4, 4))
    e.applyRequest(request(erApplyBold))
    check e.displayText == "*both*"

  test "strikethrough wraps and toggles":
    let e = newTestEditor("hello world", rng(6, 5))
    e.applyRequest(request(erApplyStrikethrough))
    check e.displayText == "hello ~~world~~"
    check e.selection == rng(8, 5)

    let f = newTestEditor("hello world", caretAt(7))
    f.applyRequest(request(erApplyStrikethrough))
    check f.displayText == "hello ~~world~~"

    let g = newTestEditor("~~text~~", rng(2, 4))
    g.applyRequest(request(erApplyStrikethrough))
    check g.displayText == "text"

  test "inline code wraps and toggles":
    let e = newTestEditor("var x = 1", rng(4, 5))
    e.applyRequest(request(erApplyInlineCode))
    check e.displayText == "var `x = 1`"

    let f = newTestEditor("call `fn()` here", rng(6, 4))
    f.applyRequest(request(erApplyInlineCode))
    check f.displayText == "call fn() here"

  test "italic and highlight use the same toggle":
    let e = newTestEditor("word", rng(0, 4))
    e.applyRequest(request(erApplyItalic))
    check e.displayText == "*word*"

    let f = newTestEditor("word", rng(0, 4))
    f.applyRequest(request(erApplyHighlight))
    check f.displayText == "==word=="

suite "formatting actions — block level":

  test "a blockquote prefix is added and removed":
    let e = newTestEditor("a quote line\n", caretAt(3))
    e.applyRequest(request(erApplyBlockquote))
    check e.displayText == "> a quote line\n"

    let f = newTestEditor("> a quote\n", caretAt(4))
    f.applyRequest(request(erApplyBlockquote))
    check f.displayText == "a quote\n"

  test "a list prefix is added and removed":
    let e = newTestEditor("item\n", caretAt(0))
    e.applyRequest(request(erApplyUnorderedList))
    check e.displayText == "- item\n"
    e.applyRequest(request(erApplyUnorderedList))
    check e.displayText == "item\n"

  test "heading levels cycle rather than stack":
    let e = newTestEditor("Title\n", caretAt(0))
    e.applyRequest(request(erApplyHeading, level = 1))
    check e.displayText == "# Title\n"
    e.applyRequest(request(erApplyHeading, level = 3))
    check e.displayText == "### Title\n"
    e.applyRequest(request(erApplyHeading, level = 0))
    check e.displayText == "Title\n"

  test "a link wraps the selection and carries the URL":
    let e = newTestEditor("click here", rng(0, 5))
    e.applyRequest(request(erApplyLink, text = "https://example.com"))
    check e.displayText == "[click](https://example.com) here"

  test "a link with no selection inserts empty brackets":
    let e = newTestEditor("text", caretAt(4))
    e.applyRequest(request(erApplyLink, text = "https://a.b"))
    check e.displayText == "text[](https://a.b)"
    check e.selection.location == 5

  test "an image inserts its own markup":
    let e = newTestEditor("text", caretAt(4))
    e.applyRequest(request(erApplyImage, text = "img.png"))
    check e.displayText == "text![](img.png)"

  test "a code block opens on its own lines":
    let e = newTestEditor("a b", caretAt(1))
    e.applyRequest(request(erApplyCodeBlock))
    check e.displayText == "a\n```\n\n```\n b"
    check e.selection.location == 6

  test "a horizontal rule goes on its own line":
    let e = newTestEditor("line\n", caretAt(5))
    e.applyRequest(request(erApplyHorizontalRule))
    check e.displayText == "line\n---\n"

    let f = newTestEditor("a b", caretAt(1))
    f.applyRequest(request(erApplyHorizontalRule))
    check f.displayText == "a\n---\n b"

suite "typing helpers":

  test "Enter continues a bullet list":
    let e = newTestEditor("- item", caretAt(6))
    e.insertText("\n")
    check e.displayText == "- item\n- "

  test "Enter on an empty item ends the list":
    let e = newTestEditor("- item\n- ", caretAt(9))
    e.insertText("\n")
    check e.displayText == "- item\n"

  test "Enter continues an ordered list, incrementing":
    let e = newTestEditor("1. one", caretAt(6))
    e.insertText("\n")
    check e.displayText == "1. one\n2. "

  test "Enter continues a task list with an unchecked box":
    let e = newTestEditor("- [x] done", caretAt(10))
    e.insertText("\n")
    check e.displayText == "- [x] done\n- [ ] "

  test "Enter inside a fenced code block does not continue a list":
    # A `- ` inside code is code, not a list; the helper must look at the
    # block context, not just at the line.
    let e = newTestEditor("```\n- item\n```", caretAt(10))
    e.insertText("\n")
    check e.displayText == "```\n- item\n\n```"

  test "Enter continues a blockquote":
    let e = newTestEditor("> quoted", caretAt(8))
    e.insertText("\n")
    check e.displayText == "> quoted\n> "

  test "typing coalesces into one undo step":
    let e = newTestEditor("", caretAt(0))
    for ch in "hello":
      e.insertText($ch)
    check e.displayText == "hello"
    e.undo()
    check e.displayText == ""

suite "undo and redo":

  test "undo restores both the text and the selection":
    let e = newTestEditor("hello", caretAt(5))
    e.insertText(" world")
    check e.displayText == "hello world"
    e.undo()
    check e.displayText == "hello"
    check e.selection == caretAt(5)
    e.redo()
    check e.displayText == "hello world"

  test "a formatting action is one undo step":
    let e = newTestEditor("hello world", rng(0, 5))
    e.applyRequest(request(erApplyBold))
    check e.displayText == "**hello** world"
    e.undo()
    check e.displayText == "hello world"

  test "undo past the start of the stack is a no-op":
    let e = newTestEditor("text", caretAt(0))
    e.undo()
    e.undo()
    check e.displayText == "text"

  test "a new edit clears the redo stack":
    let e = newTestEditor("a", caretAt(1))
    e.insertText("b")
    e.undo()
    e.insertText("c")
    e.redo()
    check e.displayText == "ac"

  test "loading a document clears the undo history":
    # Undo is per document: an undo after a switch must not resurrect text
    # from the document before it.
    let e = newTestEditor("first", caretAt(5))
    e.insertText("!")
    e.setDocument("second")
    e.undo()
    check e.displayText == "second"

suite "deletion and caret movement":

  test "backspace deletes the character before the caret":
    let e = newTestEditor("abc", caretAt(3))
    e.deleteBackward()
    check e.displayText == "ab"

  test "backspace over a selection deletes the selection":
    let e = newTestEditor("abcdef", rng(1, 3))
    e.deleteBackward()
    check e.displayText == "aef"

  test "forward delete removes the character after the caret":
    let e = newTestEditor("abc", caretAt(0))
    e.deleteForward()
    check e.displayText == "bc"

  test "word delete removes a whole word":
    let e = newTestEditor("one two", caretAt(7))
    e.deleteWordBackward()
    check e.displayText == "one "

  test "backspace never splits a surrogate pair":
    let e = newTestEditor("a\u{1F600}", caretAt(3))
    e.deleteBackward()
    check e.displayText == "a"

  test "caret movement is by code point, not by UTF-16 unit":
    let e = newTestEditor("a\u{1F600}b", caretAt(1))
    e.moveCaret(mvRight)
    check e.selection.location == 3              # over the whole pair
    e.moveCaret(mvLeft)
    check e.selection.location == 1

  test "a shifted move extends the selection":
    let e = newTestEditor("hello", caretAt(0))
    e.moveCaret(mvRight, extend = true)
    e.moveCaret(mvRight, extend = true)
    check e.selection == rng(0, 2)

suite "find and replace":

  test "find reports every match and starts on the first":
    let e = newTestEditor("one two one two", caretAt(0))
    e.runFind("two")
    check e.findMatches.len == 2
    check e.currentMatch == 0

  test "find wraps around":
    let e = newTestEditor("a a a", caretAt(0))
    e.runFind("a")
    check e.findMatches.len == 3
    e.findNext()
    e.findNext()
    check e.currentMatch == 2
    e.findNext()
    check e.currentMatch == 0
    e.findPrevious()
    check e.currentMatch == 2

  test "find is case-insensitive":
    let e = newTestEditor("Alpha alpha ALPHA", caretAt(0))
    e.runFind("alpha")
    check e.findMatches.len == 3

  test "replacing the current match leaves the others":
    let e = newTestEditor("x y x", caretAt(0))
    e.runFind("x")
    e.replaceCurrentMatch("z")
    check e.displayText == "z y x"

  test "replace all is one undo step":
    let e = newTestEditor("x y x", caretAt(0))
    e.runFind("x")
    e.replaceAllMatches("z")
    check e.displayText == "z y z"
    e.undo()
    check e.displayText == "x y x"

  test "an empty query clears the matches":
    let e = newTestEditor("abc", caretAt(0))
    e.runFind("b")
    check e.findMatches.len == 1
    e.runFind("")
    check e.findMatches.len == 0

suite "checkboxes and clipboard":

  test "toggling a checkbox flips only its own marker":
    let e = newTestEditor("- [ ] one\n- [ ] two\n", caretAt(0))
    let box = initText(e.displayText).rangeOf("[ ]")
    e.toggleCheckbox(box)
    check e.displayText == "- [x] one\n- [ ] two\n"
    e.toggleCheckbox(box)
    check e.displayText == "- [ ] one\n- [ ] two\n"

  test "copy packages every flavour from the selection":
    let e = newTestEditor("a **bold** b", rng(2, 8))
    let (payload, ok) = e.copyPayload()
    check ok
    check payload.plain == "**bold**"
    check payload.rawMarkdown == "**bold**"
    check "<strong>bold</strong>" in payload.html

  test "copying nothing reports nothing":
    check newTestEditor("text", caretAt(0)).copyPayload()[1] == false

  test "cut removes the selection and returns it":
    let e = newTestEditor("abcdef", rng(1, 3))
    let (payload, ok) = e.cutPayload()
    check ok
    check payload.plain == "bcd"
    check e.displayText == "aef"

  test "a paste into a blockquote keeps the quote prefix on later lines":
    # Pasting multi-line text inside a quote must not drop out of it halfway.
    let e = newTestEditor("> start", caretAt(7))
    e.pasteMarkdown("one\ntwo")
    check e.displayText == "> startone\n> two"

  test "a paste outside a blockquote is left alone":
    let e = newTestEditor("start", caretAt(5))
    e.pasteMarkdown("one\ntwo")
    check e.displayText == "startone\ntwo"

suite "selection-driven restyle":

  test "the caret reveals the markers of the span it enters":
    let e = newTestEditor("a **bold** b", caretAt(0))
    proc markerFontSize(): float =
      let attrs = e.storage.attributesAt(2)
      if attrs.has(akFont): attrs.get(akFont).fontVal.size else: -1.0
    let hidden = initConfiguration().markers.hiddenMarkerFontSize
    check markerFontSize() == hidden
    e.setSelection(caretAt(6))
    check markerFontSize() != hidden
    e.setSelection(caretAt(0))
    check markerFontSize() == hidden

  test "the selection flags describe the caret's formatting":
    let e = newTestEditor("a **bold** b", caretAt(6))
    check e.selectionFlags.isBold
    check not e.selectionFlags.isItalic

suite "scrolling":

  test "scrolling is clamped to the content":
    let e = newTestEditor("one\ntwo\nthree\n", caretAt(0))
    e.scrollTo(-100)
    check e.scrollY == 0.0
    e.scrollTo(100_000)
    check e.scrollY <= e.maxScroll + 0.01

  test "the bottom overscroll leaves room below the last line":
    let e = newTestEditor("single line", caretAt(0))
    check e.bottomOverscroll >= 0.0

  test "scrolling the caret into view moves the offset":
    var text = ""
    for i in 0 ..< 200: text.add &"line {i}\n"
    let e = newTestEditor(text, caretAt(0))
    check e.scrollY == 0.0
    e.setSelection(caretAt(utf16Len(text) - 1))
    e.scrollCaretToVisible()
    check e.scrollY > 0.0
