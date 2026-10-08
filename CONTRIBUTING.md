# Contributing

This is the Nim/SDL3 Linux port of
[nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine).
A pull request is the normal way in, for fixes, documentation and new
extensions alike. If a change is large or architectural, open it as a draft
with the design sketched in the description — that gets you an answer faster
than describing it in prose.

> **New here?** Start with [ARCHITECTURE.md](ARCHITECTURE.md) — a codemap
> that walks each module in the order text flows through the engine.

## Development setup

```bash
nim c -r --hints:off tests/test_all.nim     # the suite: 451 cases, 94 suites
nim c -r -d:release src/mdedit.nim          # the editor
```

Needs **Nim 2.2+**, **SDL3** as a shared library, and at least one scalable
TrueType family (DejaVu or Liberation covers sans, serif and mono). There are
no Nim package dependencies, so `nimble` is optional — the `.nimble` file's
`test` and `demo` tasks run exactly the two commands above.

SDL3 is not packaged for Ubuntu 24.04; `.github/workflows/ci.yml` shows the
from-source build CI uses, which works locally too.

The test suite needs no SDL3 at all — the bindings `dlopen` lazily and
nothing under test reaches an SDL call — so you can run it on a machine with
no SDL3 installed.

## Reporting bugs

Include:

- A minimal reproducer: the smallest Markdown input that triggers it
- Your Nim version (`nim --version`), SDL3 version, and distribution
- Which fonts are installed, if it is a rendering or metrics bug
- Expected vs. actual behaviour

For a rendering bug, `SDL_VIDEODRIVER=dummy ./mdedit --render-once` prints a
frame summary, and `mdui/screenshot.nim` can capture the frame to a PNG
without a display. Both are more useful than a description.

## Pull requests

- One logical change per PR, branched from `main`
- Tests for new parser / styler / service / extension behaviour in `tests/`
- A one-line entry in `CHANGELOG.md` under `[Unreleased]`
- `nim c -r --hints:off tests/test_all.nim` green; CI runs the same thing

## Design constraints

These are the ones worth stating, because breaking them is easy and the
damage is diffuse:

- **The engine depends on nothing outside `std/`.** `src/markdownengine/`
  imports no UI, no SDL3, no rasteriser — which is what lets it be tested
  without a window and reused without one. App-specific behaviour plugs in
  through the four service seams (`WikiLinkResolver`,
  `EmbeddedImageProvider`, `SyntaxHighlighter`, `LatexRenderer`). The port's
  only dependency at all is the vendored SDL3 bindings, used by `src/mdui/`.
- **The engine never measures text itself.** It takes a `TextMetrics` — two
  injected procs — so the same styler runs under the real rasteriser and
  under `defaultTextMetrics` in tests. Reaching for a font directly from
  engine code breaks that.
- **New constructs are extensions or directives, not core grammar.** A
  delimiter pair like `==highlight==` or a `::: … :::` block is a
  `MarkdownExtension`; something needing a name and typed arguments is a
  `MarkdownDirective`. Never a new case threaded through the parser, styler
  and renderer. Tables and math are the standing exception — they genuinely
  need core work.
- **Markers shrink, they never disappear.** An inactive syntax marker renders
  at `hiddenMarkerFontSize` with negative kern; it is never removed from the
  storage. Selection, find, copy and undo all depend on the characters still
  being there.
- **UTF-16 is the range currency.** Every range, marker and cache key is a
  UTF-16 offset, because the Swift's were `NSRange`s and every ported test
  is written in those coordinates.

## Commit messages

Imperative subject, blank line, then a paragraph explaining *why*:

```
Measure a table header at the weight it is drawn

The renderer draws the header row bold but measureTable measured every cell
at body weight, so a header word wider than its column ran through the grid
line beside it. Caught by eye in a headless capture, now pinned by a test.
```

The "what" is in the diff.

## License

By contributing, you agree that your contributions are licensed under the
[Apache 2.0 License](LICENSE).
