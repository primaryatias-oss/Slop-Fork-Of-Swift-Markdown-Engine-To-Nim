## mdedit.nim
## MarkdownEngine (Nim port) — entry point
##
## The demo editor. `--render-once` draws a single frame and exits, which is
## what the headless smoke test runs (set `SDL_VIDEODRIVER=dummy`): it proves
## the whole pipeline — parse, style, layout, rasterize, draw — executes with
## no display attached.

import std/[os, strutils]
import mdui/app

proc main() =
  var renderOnly = false
  var documentPath = ""
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    if arg == "--render-once":
      renderOnly = true
    elif arg == "--help" or arg == "-h":
      echo "mdedit [--render-once] [file.md]"
      echo ""
      echo "A live-styling Markdown editor: the Nim/SDL3 port of"
      echo "nodes-app/swift-markdown-engine."
      echo ""
      echo "  --render-once   draw one frame and exit (headless smoke test)"
      echo "  file.md         open a document instead of the built-in sample"
      return
    elif not arg.startsWith("-"):
      documentPath = arg

  let application = newApp(headless = renderOnly)
  defer: application.shutdown()

  if documentPath.len > 0:
    if fileExists(documentPath):
      application.openDocument(documentPath)
    else:
      echo "no such file: ", documentPath

  if renderOnly:
    application.renderOnce()
    echo "rendered one frame: ", application.frameSummary()
  else:
    application.run()

when isMainModule:
  main()
