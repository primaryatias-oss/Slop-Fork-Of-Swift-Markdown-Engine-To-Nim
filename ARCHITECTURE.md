# Architecture

A codemap for the Nim port, in the order text flows through it. The Swift
original's architecture doc described the same pipeline; where a stage was
rewritten rather than translated, this says so and why.

## The two halves

```
src/
├── markdownengine.nim          # umbrella: imports and re-exports everything below
├── markdownengine/             # ENGINE — std/ only. No SDL3, no rasteriser, no window.
│   ├── ranges.nim              # Range (NSRange), scope normalisation
│   ├── utf16text.nim           # Utf16Text over seq[uint16]; line/paragraph walks
│   ├── color.nim               # Rgba, Color (light+dark), the system palette
│   ├── font.nim                # FontDesc (data), TextMetrics (injected procs)
│   ├── attributes.nim          # AttrKey / AttrValue / Attrs, ParagraphStyle
│   ├── theme.nim               # every colour the editor puts on screen
│   ├── configuration.nim       # every spacing / sizing / behaviour knob
│   ├── services.nim            # the four embedder seams + the editor bus
│   ├── extension.nim           # the extension seam and both registries
│   ├── directive*.nim          # the directive seam: value model, scanner, completion
│   ├── builtin_directives.nim  # @font and @color, reference implementations
│   ├── block_parser.nim        # phase 1: text → tiling [Block]
│   ├── inline_parser.nim       # phase 2: a block's text → [InlineNode]
│   ├── ast.nim                 # the two combined → [BlockNode]
│   ├── token.nim               # MarkdownToken — a PROJECTION of the AST
│   ├── tokenizer.nim           # the projection, with its caches
│   ├── parse_state.nim         # DocumentParseState: the incremental splice
│   ├── detection.nim           # active tokens, code/latex containment, the backtick census
│   ├── lists.nim               # list / blockquote / task line scanners
│   ├── table.nim               # GFM table source → header / alignments / rows
│   ├── wikilink.nim            # the [[Name|id]] ↔ [[Name]] transform
│   ├── ast_styler.nim          # THE styler: one AST walk, compose on descent
│   ├── styler.nim              # the artefact passes + styleAttributes, the facade
│   ├── html_renderer.nim       # markdown → HTML, for rich copy
│   ├── html_to_markdown.nim    # HTML → markdown, for smart paste
│   ├── clipboard.nim           # flavour packaging and paste resolution
│   └── input.nim               # typing helpers as pure decisions
├── mdui/                       # UI — SDL3, the rasteriser, layout, the editor
│   ├── sdlbridge.nim           # the vendored bindings, minus one name collision
│   ├── truetype.nim            # sfnt parser + scanline rasteriser
│   ├── fontmanager.nim         # family groups, fallback cascade, measurement
│   ├── textstorage.nim         # run-based attributed string
│   ├── layout.nim              # line breaking, caret geometry, hit testing
│   ├── painter.nim             # rects, lines, clipping, image decode
│   ├── atlas.nim               # the glyph atlas on SDL textures
│   ├── render.nim              # the ordered draw passes for a document
│   ├── tablerender.nim         # the table grid, drawn not rasterised
│   ├── editor.nim              # selection, editing, undo, find, scrolling
│   ├── widgets.nim             # buttons, scroller, find bar, context menu
│   ├── app.nim                 # the demo: samples, toolbar, event loop
│   ├── demodirectives.nim      # @icon, @flag, @emoji, @pagebreak
│   └── screenshot.nim          # PNG writer (stored DEFLATE) and frame capture
└── mdedit.nim                  # entry point
```

The split is load-bearing. `src/markdownengine/` imports nothing outside
`std/`: it can be used without a window, it is what the engine-level tests
exercise, and it is where every behaviour the Swift specified lives.
`src/mdui/` is everything AppKit used to provide.

## UTF-16 is the currency

Every range, every marker, every cache key is a UTF-16 offset, because the
Swift's were `NSRange`s and the whole engine was written against them.
`Utf16Text` is a `seq[uint16]` with the `NSString` walks the engine needs —
`lineRange`, `paragraphRange`, `rangeOf` — reproduced exactly, including the
distinction that U+2028 ends a *line* while U+2029 and `\n` end a
*paragraph*. Everything scoped per paragraph depends on that difference.

Converting at the boundary and working in runes internally was the obvious
alternative and the wrong one: every offset in every ported test, every
marker range, every `scopedRanges` entry would have had to move with it.

## `markdownengine/` — text → AST → tokens

Two phases, following CommonMark's model. There is no regex anywhere; every
pattern the Swift expressed as an `NSRegularExpression` is a hand-written
scanner here, for the plain reason that `std/re` and `std/nre` wrap PCRE.

**1. `block_parser.nim`** splits the document into a flat, gap-free
(*tiling*) sequence of `Block`s: heading, paragraph, blockquote, list, fenced
code, block LaTeX, table, thematic break, blank, and extension blocks. Tiling
is pinned by the tests: a block that grows has to shrink its neighbour, so a
bug surfaces here rather than three passes later as a mis-styled run. The
module memoises its last parse, keyed by the buffer, so the several
per-keystroke callers share one line scan.

**2. `inline_parser.nim`** turns one inline-bearing block's text into an
inline AST with CommonMark precedence: code spans → escapes → link family
(`![[…]]`, `[[…]]`, `![…](…)`, `[…](…)`, extension spans, directives, `$…$`)
→ emphasis (delimiter runs) → `buildTree`. Each pass claims spans only in
regions no earlier pass claimed, so claimed spans are either disjoint or
properly nested and the tree is a clean containment tree.

That invariant is what keeps the parse linear in span count: claimed ranges
are consulted through a cursor rather than rescanned, and `buildTree` derives
containment from a sort instead of comparing spans pairwise. `InlineParseCost`
counts both quantities so the density tests can assert on a pure function of
the input rather than on elapsed time — identical on a laptop and on a loaded
CI runner, and quadratic versus linear differ by orders of magnitude rather
than by 1.4×.

`InlineNode` is a flat record with an `InlineNodeKind` tag, where the Swift
had an enum with associated values. Most kinds share `range`, `markers` and
`contentRange`; every consumer switches on the kind; and the adapter, styler
and HTML renderer all want uniform access to the shared geometry. The cost is
that unused fields exist per node, which matters once — `offsetNode` shifts
only the fields the kind actually uses, or two structurally identical nodes
would compare unequal depending on whether they came back from a sub-parse.

**3. `ast.nim`** combines the two into `[BlockNode]`, each inline-bearing
block carrying its children in absolute document coordinates. `parseDocument`
takes `scopedRanges`: in scoped mode it builds `BlockNode`s only for blocks
the edit touched, walking blocks and sorted scopes together in one sweep
rather than scanning every scope per block.

**Tokens are a projection of the AST, not the source of truth.**
`tokenizer.nim` walks the tree and emits one `MarkdownToken` per markup node,
reproducing the flat, overlapping token set the pre-AST code produced —
because the caret-reveal logic, the copy path and the find highlighting all
read tokens, and rewriting them all was not the port's job. Two caches sit
here: a per-block memo keyed by `(kind, extensionID, text)`, and
`incrementalTokens`, which shifts the tokens after an edit instead of
re-emitting them.

**`parse_state.nim`** is where the incremental story lands. `DocumentParseState`
splices buffer, blocks and tokens under one edit descriptor. With a
trustworthy descriptor the update is O(edit + touched blocks + suffix shift);
without one, a single shared diff scan replaces two independent ones. It may
fall back to a full parse at any time, and the differential fuzz in
`tests/test_incremental.nim` exists because equivalence is the only contract
worth stating: the fast path is free to give up, never to be wrong.

The guard that makes the splice sound is `hasBlockDelimiter`. Any edit
touching a line that carries ``` ``` ``` or `$$` — or a registered extension
fence — forces the full reparse, because those pair at a distance and the
pairing of every fence below can change. It is line-expanded rather than
±3 around the edit, since block delimiters are classified from a trimmed
prefix and editing the leading whitespace of an indented `$$` flips the
pairing from arbitrarily far away from the literal `$$`.

## `markdownengine/ast_styler.nim` — one walk, composing on descent

The single most important file. It walks the AST once, carrying the font down
the tree and **composing** rather than overwriting: a heading sets a large
bold font, descending into `**bold**` adds the trait and keeps the size,
descending again into `*italic*` adds that trait and keeps both. This is what
the flat multi-pass styler it replaced got wrong, and `# **n*o*des**` — where
the middle letter rendered at a different size — is the case that named it.

Two rules run through the whole file:

**Markers shrink, they never disappear.** An inactive syntax marker is
rendered at `hiddenMarkerFontSize` (0.1pt) with negative kern, not removed
from the storage. Selection, find, copy and undo therefore all see the real
characters, and the document you edit is the markdown you save. Every
collapse in the port — markers, a self-contained directive's source, a hidden
task checkbox's `[ ] ` — is the same mechanism.

**The caret reveals.** A construct the caret is inside renders its syntax
muted instead of collapsed. `detection.nim` computes the active token set;
the styler asks `isActive` per range. The one exception is the ordered-list
display number, which is positional rather than authored: revealing the source
digit under the caret renamed the item the reader was pointing at, so the
overlay stays put for the caret *and* for a selection.

`styler.nim` wraps the AST walk with the artefact passes — block LaTeX, inline
LaTeX, image embeds, image links, tables — and exposes `styleAttributes`, the
one public entry point. It returns overlapping `StyledRange`s in emission
order: later ranges win per key, which `flattenedRuns` collapses when a caller
wants one write per character.

## The two seams

**Extensions** (`extension.nim`) are *delimiter-shaped*: an open string, a
close string, whether the content is re-parsed. `==highlight==`,
`~~strikethrough~~` and `::: … :::` are built with the same seam an embedder
would use, and unregistered syntax stays literal text. The registry
fingerprints itself with length-prefixed fields so a concatenation of
free-text names cannot alias another registry — the fingerprint keys the parse
caches, and a grammar change has to invalidate them.

**Directives** (`directive*.nim`) are *name-shaped*: a name, typed arguments,
and a body. `@font(size: 18){…}` is the motivating case, and the reason the
seam exists is that no delimiter pair can express a typed argument.

Four files:

- `directive.nim` — the value model. `DirectiveValue` with units,
  `DirectiveParameter` schemas, `DirectiveFontTransform` as **data** rather
  than a closure (inspectable, testable and cheap on the per-keystroke path,
  with `custom` as the escape hatch), `DirectivePresentation` for the
  self-contained form.
- `directive_scanner.nim` — `matchDirective`, the boundary rule, balanced
  delimiter scanning, and `parseArguments`, which coerces against the schema
  without ever throwing or partially applying: a bad argument is dropped and
  recorded as a diagnostic, so a directive always receives well-formed
  arguments and decides for itself whether to render as invalid.
- `directive_completion.nim` — what the caret is trying to complete. This
  scanner's job is the opposite of the parser's: it must succeed on text the
  parser rejects, because `@gly` is what a directive looks like while you are
  still typing it.
- `builtin_directives.nim` — `@font` and `@color`, meant to be read.

Directives project as `InlineNode.ext` under a reserved `directive.` id
namespace, so every downstream consumer — tokens, caret reveal, copy, HTML —
gets them for free. Marker dispatch is one table probe per character on the
parse hot path, which is why a marker is a single UTF-16 code unit.

## `mdui/` — everything AppKit used to do

### `truetype.nim` — the rasteriser

A pure-Nim sfnt parser and scanline rasteriser: `head`, `hhea`, `maxp`,
`hmtx`, `cmap` (formats 0, 4, 6, 12), `loca`, `glyf`, `OS/2`, `post` and
`kern`; simple and composite glyphs; quadratic Béziers flattened to lines.

Coverage is computed analytically rather than by supersampling: each line
segment accumulates a signed area per pixel, and a prefix sum over the
accumulator turns into coverage in one pass (the approach `font-rs` describes).
It is exact for the polygon it is given, it needs one float per pixel, and it
has no sample-count knob to get wrong.

Synthetic bold (dilation) and oblique (shear) cover the faces a family group
is missing. CFF/OTF outlines are not read; a face without `glyf` is rejected
at load and the next family in the group is tried.

### `fontmanager.nim`

Families are *groups* — four faces, regular/bold/italic/bold-italic — and
resolution picks the first group whose regular face actually loads. A missing
face within a chosen group is synthesised rather than sending the whole group
back. Per code point there is a fallback cascade, so a glyph the chosen family
lacks is drawn from one that has it.

It is also where `TextMetrics` comes from, the two-proc record the engine
measures through. `defaultTextMetrics` is a cheap approximation; the engine
cannot tell the difference, which is what lets every engine-level test run
without touching a font file.

### `textstorage.nim` and `layout.nim`

`TextStorage` is the run-based attributed string: text plus attribute runs,
with `applyStyledRanges` expanding per character *within one paragraph*,
compressing back to runs, and splicing. Bounding the expansion to a paragraph
is what keeps the exact `addAttribute` semantics without ever materialising
the document character by character.

`layout.nim` replaces TextKit 2: paragraph-based line breaking honouring the
paragraph style's indents and line heights, glyph positioning with kerning,
caret rectangles, hit testing, selection rectangles, word and line motion,
and vertical motion with a sticky desired x. Extra line height goes *above*
the baseline, matching `minimumLineHeight`.

### `render.nim`

An ordered pass list, because the order is the whole design: code-block
backgrounds (merged across consecutive lines, or the 2pt paragraph spacing
shows as a seam), block backgrounds, glyph backgrounds, find highlights,
artefacts (tables, images, formulas), glyphs, text decorations, task
checkboxes, bullet markers, ordered markers, thematic breaks, blockquote bars.

Two things the engine deliberately leaves to this layer: a directive's symbol
name arrives as data (`"symbol:arrow.down.to.line"`) rather than as a
rasterised image, and a table arrives as a handle plus its geometry rather
than as a bitmap. The Swift rasterised tables into an `NSImage`; drawing them
with the same text engine as everything else gives crisp text at any scale.

### `editor.nim`

Selection, editing, undo and redo with typing coalescence, the clipboard
paths, find and replace, scrolling with bottom overscroll, drag selection with
autoscroll, checkbox hit testing, and the directive completion commit. It owns
the display/storage wiki-link transform: the editor edits the display form and
`storageFormText` is what should be persisted.

Formatting toggles go through the *token list* rather than through a literal
probe of the characters around the selection. The markers are almost never
part of what the user highlighted, and a hand-dragged selection lands half on
them as often as not. Asking the parser where the span begins is both simpler
and more forgiving — and it is what makes bold-off inside `***both***` produce
`*both*` instead of refusing.

## Testing

`tests/` mirrors `Tests/MarkdownEngineTests/` from the Swift, case by case.
Each file names the suite it came from; where this port diverges, the test
says so and why.

The engine-level suites need no fonts and no window: they measure through
`defaultTextMetrics`. The UI-level ones (`test_tables.nim`'s cell formatting,
`test_editor.nim`) construct a real `FontManager`, which reads the installed
fonts but still opens nothing.

Two suites carry most of the weight:

- **`test_incremental.nim`** — differential fuzz over the incremental parse,
  plus the backtick census composition property. Deterministic PRNG, so a
  failing seed reproduces exactly.
- **`test_styler.nim`** — the scoped restyle against the full pass, attribute
  by attribute at every index, and `flattenedRuns` against the naive loop it
  replaced under randomised overlap storms.

## Deliberate divergences

Each is commented where it happens and pinned by a test.

| Divergence | Why |
|---|---|
| Autolinks and resolving wiki links state their colour and underline | AppKit painted a `.link` run from the attribute alone; nothing below this layer does |
| A scheme-less host gets `https`, not `http` | `NSDataDetector`'s choice predates ubiquitous TLS |
| The incomplete-link pass skips ranges the AST called complete links | `[[Name]]` matches the Swift's pattern; it was harmless there only because AppKit repainted afterwards |
| A directive's symbol name reaches the renderer as data | There are no SF Symbols; the renderer decides what it can draw |
| Tables are drawn, not rasterised | Crisp text at any scale, and no bitmap cache to invalidate |
| `TableAlignment` members are `tca…` | Two exported enums sharing a member name are ambiguous unqualified in Nim |
| `ParagraphStyle` has structural `==` | It is a `ref` only because the Swift mutated one and passed it around; two identical styles are the same style |

## Build

```bash
nim c -r -d:release src/mdedit.nim           # the editor
nim c -r --hints:off tests/test_all.nim      # the suite
SDL_VIDEODRIVER=dummy ./mdedit --render-once # one frame, headless
```

`nim.cfg` sets `--mm:orc`, `--threads:off`, and the two source paths. There
are no Nim package dependencies, so `nimble` is optional; the `.nimble` file's
`test` and `demo` tasks run exactly the commands above.
