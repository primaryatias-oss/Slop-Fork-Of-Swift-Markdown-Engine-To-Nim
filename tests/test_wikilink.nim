## test_wikilink.nim
## The wiki-link storage/display transform and its incremental splice.
##
## Ported from `WikiLinkIncrementalTests.swift`.
##
## Storage form is `[[Name|<id>]]`; what the editor shows is `[[Name]]`. The
## id is the stable target, the name is only a label, and the two forms have
## to stay in step through every keystroke — so the splice path exists, and so
## does the proof obligation that makes it bail.

import std/[unittest, tables, algorithm, sequtils, strformat]
import markdownengine

const seedStorage = "Hello [[Note|abc123]] world"
  ## display: "Hello [[Note]] world" — display link range {6, 8},
  ## storage link range {6, 15}.

proc seedState(): (string, string, LinkMetadataTable) =
  let (display, metadata) = makeDisplayState(seedStorage)
  (display, seedStorage, metadata)

proc replacing(text: string, r: Range, insert: string): string =
  utf16ToString(initText(text).replacingCharacters(r, toUtf16(insert)))

suite "wiki links — display and storage forms":

  test "storage collapses to display, keeping the id in the metadata":
    let (display, metadata) = makeDisplayState(seedStorage)
    check display == "Hello [[Note]] world"
    check metadata.len == 1
    for key, value in metadata:
      check key.location == 6
      check key.length == 8
      check value.hasID
      check value.id == "abc123"
      check value.storageRange == rng(6, 15)

  test "a document with no links needs no rebuild":
    let (storage, metadata) = makeStorageState(initText("plain text"),
                                               initTable[RangeKey, LinkMetadata]())
    check storage == "plain text"
    check metadata.len == 0

  test "display round-trips back to storage through the metadata":
    let (display, metadata) = makeDisplayState(seedStorage)
    let (storage, _) = makeStorageState(initText(display), metadata)
    check storage == seedStorage

  test "an image embed keeps its own storage form":
    let (display, metadata) = makeDisplayState("See ![[Pic|id9]] here")
    check display == "See ![[Pic]] here"
    check metadata.len == 1

suite "wiki links — incremental splice":

  test "appending after a link splices the storage":
    let (display, storage, metadata) = seedState()
    let (spliced, newMetadata, ok) = updatedStorageState(
      initText(display & "x"), rng(utf16Len(display), 1), 1,
      initText(storage), metadata)
    check ok
    check spliced == "Hello [[Note|abc123]] worldx"
    # The link sits before the edit, so its metadata is unchanged.
    check newMetadata.len == 1
    for key, value in newMetadata:
      check key.location == 6
      check key.length == 8
      check value.id == "abc123"
      check value.storageRange == rng(6, 15)

  test "inserting before a link shifts its metadata":
    let (display, storage, metadata) = seedState()
    let (spliced, newMetadata, ok) = updatedStorageState(
      initText("x" & display), rng(0, 1), 1, initText(storage), metadata)
    check ok
    check spliced == "xHello [[Note|abc123]] world"
    for key, value in newMetadata:
      check key.location == 7                  # shifted by +1
      check key.length == 8
      check value.storageRange == rng(7, 15)
      check value.id == "abc123"

  test "a deletion in plain text splices":
    let (display, storage, metadata) = seedState()
    # Delete the "l" of "world" — far enough from the link that neither the
    # ±3 probe nor the metadata guard band trips.
    let (spliced, _, ok) = updatedStorageState(
      initText(replacing(display, rng(18, 1), "")), rng(18, 0), -1,
      initText(storage), metadata)
    check ok
    check spliced == "Hello [[Note|abc123]] word"

  test "an edit touching a link falls back":
    let (display, storage, metadata) = seedState()
    # Typing directly after `]]` (display location 14) is inside the guard band.
    let (_, _, ok) = updatedStorageState(
      initText(display & " "), rng(14, 1), 1, initText(storage), metadata)
    check not ok

  test "an edit that creates link syntax falls back":
    # `[[x]` plus a typed `]` completes a link, so the new-text probe sees `]]`.
    let display = "pre [[x] post"
    let (_, _, ok) = updatedStorageState(
      initText(replacing(display, rng(8, 0), "]")), rng(8, 1), 1,
      initText(display), initTable[RangeKey, LinkMetadata]())
    check not ok

  test "an unknown delta falls back":
    let (display, storage, metadata) = seedState()
    let (_, _, ok) = updatedStorageState(initText(display), rng(0, 0),
                                         low(int), initText(storage), metadata)
    check not ok

  test "the splice round-trips at every position that takes the fast path":
    # Comparing against a full rebuild would be wrong here: the full rebuild
    # loses ids when link ranges shift, which is precisely what the
    # incremental path fixes. So the property is round-trip plus id survival.
    let storage = "aaaa [[One|id1]] bbbb [[Two|id2]] cccc"
    let (display, metadata) = makeDisplayState(storage)
    var fastPathTaken = 0

    for position in 0 .. utf16Len(display):
      let newDisplay = replacing(display, rng(position, 0), "q")
      let (spliced, newMetadata, ok) = updatedStorageState(
        initText(newDisplay), rng(position, 1), 1, initText(storage), metadata)
      if not ok: continue                      # guarded position → fallback
      inc fastPathTaken
      let (roundTrip, _) = makeDisplayState(spliced)
      checkpoint(&"position {position}")
      check roundTrip == newDisplay
      var ids = newMetadata.values.toSeq.filterIt(it.hasID).mapIt(it.id)
      ids.sort()
      check ids == @["id1", "id2"]

    check fastPathTaken > 0                    # the sweep was not vacuous
