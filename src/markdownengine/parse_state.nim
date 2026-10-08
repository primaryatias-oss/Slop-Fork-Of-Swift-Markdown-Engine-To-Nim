## parse_state.nim
## MarkdownEngine (Nim port)
##
## Per-editor incremental parse state: one UTF-16 buffer, its block list, and
## its token list evolve together under a single edit descriptor. A keystroke
## then pays one O(edit) buffer splice and a block-window re-tokenize instead
## of a full-document re-extraction plus two independent O(doc) prefix/suffix
## diff scans (the block parser and the tokenizer each ran their own).

import ./ranges, ./utf16text, ./extension, ./token, ./block_parser, ./tokenizer

type
  ParseEditDescriptor* = object
    ## A contiguous edit in NEW-text coordinates plus the length delta, as
    ## delivered by the text view's "should change / did change" pair. The
    ## described region may be wider than the minimal diff — splice logic only
    ## requires containment.
    editedRange*: Range   ## post-edit coords: location + replacement length
    delta*: int

  DocumentParseState* = ref object
    chars: seq[uint16]
    blocks: seq[Block]
    tokens: seq[MarkdownToken]
    valid: bool
    fingerprint: string
      ## Registry fingerprint the stored tokens were computed under; a change
      ## (extension registered/unregistered at runtime) invalidates the splice
      ## base — old tokens must not be reused under a new grammar.

proc newDocumentParseState*(): DocumentParseState =
  DocumentParseState(chars: @[], blocks: @[], tokens: @[], valid: false,
                     fingerprint: "")

proc currentBlocks*(state: DocumentParseState): seq[Block] =
  ## The block list matching the most recent `tokens` call — handed to the
  ## restyle so `parseDocument` skips the block parser.
  state.blocks

proc invalidate*(state: DocumentParseState) =
  ## Drop all state (document switch / full rebuild) — the next parse
  ## re-extracts and re-parses from scratch.
  state.valid = false
  state.chars = @[]
  state.blocks = @[]
  state.tokens = @[]

proc tokens*(state: DocumentParseState, t: Utf16Text,
             edit: ParseEditDescriptor, hasEdit: bool,
             registry = emptyRegistry()): seq[MarkdownToken] =
  ## Tokens for `t`. With a trustworthy `edit` the update is
  ## O(edit + touched blocks + suffix shift); without one, a single shared
  ## O(doc) diff scan replaces the two independent scans of the static path.
  let newLen = t.len
  let prevChars = state.chars
  let prevBlocks = state.blocks
  let prevTokens = state.tokens
  let wasValid = state.valid and state.fingerprint == registry.fingerprint

  # 1. New buffer + change region — spliced O(edit) when the descriptor passes
  #    every sanity check, adopted wholesale otherwise.
  var newChars: seq[uint16]
  var diff: BufferDiff
  var hasDiff = false

  if wasValid and hasEdit and
     edit.editedRange.location != NotFound and
     edit.editedRange.location >= 0 and edit.editedRange.length >= 0 and
     maxRange(edit.editedRange) <= newLen and
     edit.editedRange.length - edit.delta >= 0 and
     prevChars.len == newLen - edit.delta:
    let changeStart = edit.editedRange.location
    let changeEndNew = maxRange(edit.editedRange)
    let changeEndOld = changeEndNew - edit.delta
    newChars = prevChars
    let replacement = t.units(edit.editedRange)
    newChars[changeStart ..< changeEndOld] = replacement
    diff = BufferDiff(changeStart: changeStart, changeEndOld: changeEndOld,
                      changeEndNew: changeEndNew, delta: edit.delta)
    hasDiff = true
  else:
    newChars = t.units
    if wasValid:
      let (scanned, changed) = scanDiff(prevChars, newChars)
      if not changed and prevChars.len == newLen:
        return prevTokens                            # identical text
      diff = scanned
      hasDiff = changed

  # 2. Blocks: window splice on the shared diff, full reparse fallback.
  var resolvedBlocks: seq[Block]
  var blocksSpliced = false
  if wasValid and hasDiff:
    let (spliced, _, ok) = incrementalParse(prevChars, prevBlocks, newChars, t,
                                            diff, registry)
    if ok:
      resolvedBlocks = spliced
      blocksSpliced = true
  if not blocksSpliced:
    resolvedBlocks = computeBlocks(t, registry)

  # 3. Tokens: prefix/suffix reuse on the same diff, full fallback.
  var resolvedTokens: seq[MarkdownToken]
  var tokensSpliced = false
  if wasValid and hasDiff and blocksSpliced:
    let (spliced, _, ok) = incrementalTokens(prevChars, prevTokens, newChars,
                                             resolvedBlocks, t, diff, registry)
    if ok:
      resolvedTokens = spliced
      tokensSpliced = true
  if not tokensSpliced:
    resolvedTokens = fullTokens(resolvedBlocks, t, registry)

  state.chars = newChars
  state.blocks = resolvedBlocks
  state.tokens = resolvedTokens
  state.valid = true
  state.fingerprint = registry.fingerprint

  # Publish to the module memos so their callers (the restyle's
  # `parseDocument`, the smart-input helpers) take the memcmp hit instead of
  # splicing against a one-keystroke-stale cache every time.
  seedBlockCache(newChars, resolvedBlocks, registry.fingerprint)
  seedTokenCache(newChars, resolvedTokens, registry.fingerprint)
  resolvedTokens

proc tokens*(state: DocumentParseState, t: Utf16Text,
             registry = emptyRegistry()): seq[MarkdownToken] {.inline.} =
  state.tokens(t, ParseEditDescriptor(), false, registry)
