## The surface's instances: a located instance is found again, on a later read
## of the screen, by its keys, not by where it sat among its siblings.

import std/[json, unittest]
import demo_video_script/[surface, backend]

proc screen(rows: openArray[string]): Tree =
  ## A list of rows keyed by their text, under one root.
  result.root = node("window", 0, 0, 100, 100)
  for i, r in rows:
    result.add(result.root, node("row", 0, float(i), 100, 1, %*{"text": r}, @[("text", r)]))

proc rowLocator(text: string): JsonNode =
  %*{"segments": [{"role": "row", "keys": {"text": text}}]}

suite "the surface's instances":
  test "an instance is read again on the same screen":
    var idx: SurfaceIndex
    let t = screen(["a", "b", "c"])
    let r = idx.locate(t, rowLocator("b"))
    check r.outcome == loOne
    check idx.lookup(t, r.instance).props["text"].getStr == "b"

  test "a row drawn above it does not move the instance onto another row":
    var idx: SurfaceIndex
    let r = idx.locate(screen(["a", "b", "c"]), rowLocator("b"))
    let later = screen(["new", "a", "b", "c"])
    check idx.lookup(later, r.instance).props["text"].getStr == "b"

  test "a row removed above it does not move the instance onto another row":
    var idx: SurfaceIndex
    let r = idx.locate(screen(["a", "b", "c"]), rowLocator("c"))
    let later = screen(["b", "c"])
    check idx.lookup(later, r.instance).props["text"].getStr == "c"

  test "an instance that left the screen is gone":
    var idx: SurfaceIndex
    let r = idx.locate(screen(["a", "b"]), rowLocator("b"))
    expect BackendError:
      discard idx.lookup(screen(["a"]), r.instance)

  test "of siblings that share their keys, the instance keeps its place":
    var idx: SurfaceIndex
    let t = screen(["x", "x", "y"])
    let r = idx.locate(t, %*{"segments": [{"role": "row", "keys": {"text": "x"}, "ordinal": 2}]})
    check r.outcome == loOne
    let later = screen(["y", "x", "x"])
    check idx.lookup(later, r.instance) == later.kids(later.root)[2]
