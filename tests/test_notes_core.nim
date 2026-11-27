## The conformance application's core: how it tells a double-click from two
## clicks. Driven through `handle` with a scripted handling clock (the one
## stand-in, and why it is not a mock: the defect is a matter of when the
## application gets to an event, which a loaded machine decides and a test
## cannot make happen on demand; the events themselves are the ones the
## native-window build passes, with the window system's timestamps).

import std/[json, os, unittest]
import ../conformance/app/notes_core

let fixture = currentSourcePath().parentDir / "../conformance/fixtures/three-notes.json"

proc appAt(handled: ptr int64): App =
  result = newApp(60, 16, proc (): int64 = handled[])
  result.loadNotes(parseFile(fixture))

proc click(app: App; handled: ptr int64; at, eventTime: int64) =
  ## A left click on the first note, handled at `at` on the application's
  ## clock, stamped `eventTime` by the window system (0: no timestamp).
  handled[] = at
  let row = app.listTop
  app.handle(InputEvent(kind: evPress, row: row, col: 4, button: mbLeft, time: eventTime))
  app.handle(InputEvent(kind: evRelease, row: row, col: 4, button: mbLeft, time: eventTime))

suite "a double-click":
  test "two clicks the window system delivered 200 ms apart, handled 700 ms apart, are one":
    # the first click's redraw kept the second waiting in the queue: what a
    # loaded host did to the native-window build
    var handled = 10_000'i64
    let app = appAt(addr handled)
    app.click(addr handled, 10_000, 5_000_000)
    app.click(addr handled, 10_700, 5_000_200)
    check app.dialogOpen

  test "two clicks the window system delivered 700 ms apart are two":
    var handled = 10_000'i64
    let app = appAt(addr handled)
    app.click(addr handled, 10_000, 5_000_000)
    app.click(addr handled, 10_100, 5_000_700)
    check not app.dialogOpen

  test "without timestamps (a terminal) the clicks are timed when they are handled":
    var handled = 10_000'i64
    let app = appAt(addr handled)
    app.click(addr handled, 10_000, 0)
    app.click(addr handled, 10_200, 0)
    check app.dialogOpen
    let other = appAt(addr handled)
    other.click(addr handled, 20_000, 0)
    other.click(addr handled, 20_700, 0)
    check not other.dialogOpen
