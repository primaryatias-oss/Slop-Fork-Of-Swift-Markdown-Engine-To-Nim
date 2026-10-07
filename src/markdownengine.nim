## markdownengine.nim
## MarkdownEngine (Nim port of nodes-app/swift-markdown-engine)
##
## Umbrella module: importing this gives the whole engine — the parser, the AST,
## the token projection, the extension and directive seams, the styler, the
## HTML renderer, the clipboard flavours, and the typing-time input handlers.
##
## The engine is pure computation over a UTF-16 buffer. It never opens a window,
## loads a font file or draws a pixel: the UI layer in `mdui/` supplies the
## measurement seam (`TextMetrics`) and consumes the styled ranges. That split
## is what keeps the parser and styler testable headlessly, and it mirrors the
## original's "the engine never reaches into the host app" contract.

import markdownengine/ranges
import markdownengine/utf16text
import markdownengine/color
import markdownengine/font
import markdownengine/attributes
import markdownengine/theme
import markdownengine/directive
import markdownengine/directive_scanner
import markdownengine/directive_completion
import markdownengine/builtin_directives
import markdownengine/extension
import markdownengine/inline_parser
import markdownengine/block_parser
import markdownengine/ast
import markdownengine/token
import markdownengine/tokenizer
import markdownengine/detection
import markdownengine/parse_state
import markdownengine/services
import markdownengine/configuration
import markdownengine/wikilink
import markdownengine/lists
import markdownengine/table
import markdownengine/ast_styler
import markdownengine/styler
import markdownengine/html_renderer
import markdownengine/html_to_markdown
import markdownengine/clipboard
import markdownengine/input

export ranges, utf16text, color, font, attributes, theme
export directive, directive_scanner, directive_completion, builtin_directives
export extension, inline_parser, block_parser, ast, token, tokenizer
export detection, parse_state, services, configuration, wikilink, lists
export table, ast_styler, styler, html_renderer, html_to_markdown
export clipboard, input
