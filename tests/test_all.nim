## test_all.nim
## The whole suite in one binary — what `nimble test` runs.
##
## One binary rather than a per-file run: every module shares the same engine,
## so compiling once and linking once is markedly faster than seventeen
## separate builds, and `unittest` prints each suite under its own heading
## either way.
##
## Note the module-level caches the engine keeps (the block memo, the
## per-block token memo). They are keyed by content, so sharing a process
## across suites is sound — and running the suites together is the only thing
## that would catch it if that ever stopped being true.

# Each module's suites register themselves as a side effect of being
# imported, so nothing here reads a symbol out of them. That is exactly what
# UnusedImport is for, and exactly not a problem here.
{.warning[UnusedImport]: off.}

import ./test_text
import ./test_block_parser
import ./test_inline_parser
import ./test_ast
import ./test_lists
import ./test_extensions
import ./test_directives
import ./test_directive_args
import ./test_directive_completion
import ./test_directive_composition
import ./test_directive_glyph
import ./test_styler
import ./test_tables
import ./test_html
import ./test_wikilink
import ./test_incremental
import ./test_editor
