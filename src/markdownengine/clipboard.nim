## clipboard.nim
## MarkdownEngine (Nim port)
##
## Builds the clean, multi-flavour representation of a raw markdown selection
## that the copy path puts on the clipboard, and resolves an incoming paste
## back to markdown.
##
## The editor's storage holds RAW markdown styled in place, so a naive copy
## leaks syntax markers and drops thematic breaks. Here the raw markdown is
## rendered to clean HTML, the HTML is kept for rich consumers, and the raw
## markdown itself stays the plain-text flavour.
##
## What the port drops, and why: the Swift writer also produced a Safari web
## archive and an RTF flavour, both derived through AppKit's HTML importer.
## Linux clipboards have no equivalent of either, so this emits `text/html` and
## `text/plain` plus the engine's private raw-markdown flavour — the three that
## actually round-trip here. The `<hr>` stand-in logic stays, since a consumer
## that takes the HTML verbatim still benefits from it.

import std/strutils
import ./extension, ./directive, ./html_renderer, ./html_to_markdown

const
  markdownFlavor* = "dev.markdownengine.raw-markdown"
    ## Private flavour carrying the EXACT raw markdown of the selection. When
    ## one of our own editors pastes, it prefers this over the derived HTML so
    ## wiki links (`[[Name|UUID]]`), code, and every other construct round-trip
    ## byte-exact instead of being re-derived from the lossy HTML flavour.
  htmlFlavor* = "text/html"
  plainFlavor* = "text/plain"

  rtfRuleStandIn* = "────────────────────────────────────────"
    ## The visible horizontal-rule stand-in for flavours that cannot carry a
    ## rule: a line of U+2500 (glyphs connect edge-to-edge); 40 characters
    ## reads full-width yet never wraps in ~72-column text.

type
  ClipboardPayload* = object
    ## One flavour per field. A consumer picks the richest it understands.
    plain*: string
    html*: string
    rawMarkdown*: string

func stripTaskCheckboxes*(body: string): string =
  ## Rich targets show task items as plain bullets: drop the GFM checkbox
  ## inputs the renderer emits (the HTML flavour keeps them).
  body.replace("<input type=\"checkbox\" checked disabled> ", "")
      .replace("<input type=\"checkbox\" disabled> ", "")

func ruleStandInBody*(body: string): string =
  ## Stand-in for what plain rich text can't carry: substitute a visible rule.
  body.replace("<hr>", "<p>" & rtfRuleStandIn & "</p>")

proc makeClipboardPayload*(markdown: string,
                           extensions: seq[MarkdownExtension] = @[],
                           directives: seq[MarkdownDirective] = @[],
                           directiveSettings = defaultDirectiveSettings): ClipboardPayload =
  ## Render the selection once and package every flavour from it.
  let htmlBody = renderHTML(markdown, extensions, directives, directiveSettings)
  ClipboardPayload(
    plain: markdown,
    html: "<html><head><meta charset=\"utf-8\"></head><body>" & htmlBody &
          "</body></html>",
    rawMarkdown: markdown)

proc resolvePaste*(rawMarkdown: string, hasRawMarkdown: bool,
                   html: string, hasHTML: bool,
                   plain: string): (string, bool) =
  ## Pick the richest flavour a paste offers and return markdown.
  ##
  ## Our own private flavour wins outright — it is the selection verbatim. HTML
  ## comes next, through the lenient converter; when the HTML carries no
  ## convertible structure the plain text is used instead, which is also the
  ## last resort.
  if hasRawMarkdown and rawMarkdown.len > 0:
    return (rawMarkdown, true)
  if hasHTML and html.len > 0:
    let (converted, ok) = markdownFromHTML(html)
    if ok: return (converted, true)
  if plain.len > 0: (plain, true) else: ("", false)
