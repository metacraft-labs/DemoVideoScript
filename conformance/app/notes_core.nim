## The conformance application's headless core: one state machine that the
## terminal program, the web page and the X11 window all render.
##
## It is a small notes list: a title, a toolbar (Sort, Filter, New), a search
## field, a scrolling list of notes that can be selected, reordered by dragging
## their handle, pinned and archived through a context menu, renamed through a
## dialog, and a status bar. Some operations finish asynchronously (sorting,
## filtering, archiving take a short, fixed time) so that a scenario must wait on
## the `loaded` condition rather than on time.
##
## Everything is laid out on a grid of character cells. Input arrives as decoded
## events (keys, characters, pointer events at a cell); `decodeTerminalInput`
## turns the bytes a terminal sends into those events, and every build feeds the
## core through it or through the same event types.

import std/[json, strutils, unicode, algorithm, sets, tables, times]

type
  Clock* = proc (): int64 {.closure.}   ## milliseconds

  Note* = object
    title*: string
    body*: seq[string]
    tags*: seq[string]
    pinned*: bool

  Focus* = enum
    focusList, focusSearch, focusDialogField

  PendingKind* = enum
    pendNone, pendSort, pendFilter, pendArchive

  ModKey* = enum
    mkShift, mkAlt, mkCtrl, mkMeta

  EventKind* = enum
    evKey, evChar, evPress, evRelease, evMove, evWheel

  MouseButton* = enum
    mbLeft, mbMiddle, mbRight, mbNone

  InputEvent* = object
    kind*: EventKind
    key*: string          ## evKey: Enter, Esc, Tab, Backspace, Delete, Up, Down, Left, Right,
                          ## Home, End, PageUp, PageDown, F1..F12, or a letter with Ctrl/Alt
    ch*: string           ## evChar: one UTF-8 character
    mods*: set[ModKey]
    button*: MouseButton
    row*, col*: int       ## pointer events: 0-based cell
    wheelUp*: bool

  Rect* = object
    row*, col*, w*, h*: int

  Element* = ref object
    role*: string
    keys*: seq[(string, string)]
    props*: JsonNode      ## property name -> value
    rect*: Rect
    children*: seq[Element]

  Cell* = object
    text*: string         ## one character
    reverse*, bold*: bool

  App* = ref object
    width*, height*: int
    clock*: Clock
    notes*: seq[Note]            ## the user's order
    view*: seq[int]              ## indices into notes, as displayed (filtered, possibly sorted)
    selected*: HashSet[string]   ## by title
    anchor*: string              ## selection anchor for Shift-extend
    search*: string
    searchCaret*: int
    appliedSearch*: string
    focus*: Focus
    scroll*: int
    status*: string
    dialogOpen*: bool
    dialogTarget*: string
    dialogValue*: string
    dialogCaret*: int
    menuOpen*: bool
    menuNote*: string
    menuRow*, menuCol*: int
    pending*: PendingKind
    pendingDue*: int64
    pendingArg*: string
    sorted*: bool
    dragFrom*: string
    dragOver*: string
    dragging*: bool
    pressRow*, pressCol*: int
    pressButton*: MouseButton
    lastClickAt*: int64
    lastClickCell*: (int, int)
    hoverLabel*: string
    keymap*: Table[string, string]   ## operation -> chord
    loadedGeneration*: int
    events*: int                     ## input events processed
    wallClock*: proc (): string {.closure.}
      ## The time of day shown in the title row (HH:MM:SS); nil shows none.
      ## A live clock is the volatile region a documentation capture must
      ## declare (DemoVideoScript-Format §9.2).

const
  OpDelay* = 150'i64                 ## how long an asynchronous operation takes
  DoubleClickMs* = 400'i64
  ToolbarButtons* = ["Sort", "Filter", "New"]
  MenuWidth = 12

proc defaultKeymap*(): Table[string, string] =
  {"notes.archive-selected": "Ctrl+d", "notes.rename": "F2", "notes.sort": "Ctrl+s",
   "notes.focus-search": "Ctrl+f", "notes.pin": "Ctrl+p"}.toTable

proc newApp*(width = 60, height = 16; clock: Clock): App =
  App(width: width, height: height, clock: clock, keymap: defaultKeymap(),
      status: "Ready")

proc clockText*(t: DateTime): string =
  t.format("HH:mm:ss")

proc liveClock*(): proc (): string {.closure.} =
  ## The wall clock, as the title row shows it.
  result = proc (): string = clockText(now())

proc fixedClock*(at: string): proc (): string {.closure.} =
  ## A clock stopped at `at`: an ISO 8601 date-time (its time of day is shown)
  ## or a time of day, HH:MM:SS.
  var shown = at
  if 'T' in at:
    shown = at[at.find('T') + 1 .. ^1]
  if shown.len >= 8: shown = shown[0 ..< 8]
  result = proc (): string = shown

proc clockRect*(app: App): Rect =
  Rect(row: 0, col: (app.width - 8) div 2, w: 8, h: 1)

proc loadNotes*(app: App; j: JsonNode) =
  app.notes.setLen(0)
  for n in j["notes"]:
    var note = Note(title: n["title"].getStr)
    for b in n{"body"}.getElems: note.body.add b.getStr
    for t in n{"tags"}.getElems: note.tags.add t.getStr
    note.pinned = n{"pinned"}.getBool(false)
    app.notes.add note
  app.view.setLen(0)
  for k in 0 ..< app.notes.len: app.view.add k

# --- queries ------------------------------------------------------------------

proc now(app: App): int64 = app.clock()

proc loading*(app: App): bool = app.pending != pendNone

proc noteIndex(app: App; title: string): int =
  for k, n in app.notes:
    if n.title == title: return k
  -1

proc listTop*(app: App): int = 3                 ## first list row
proc listRows*(app: App): int = app.height - 4    ## rows between the search line and the status bar

proc visibleNotes*(app: App): seq[int] =
  let first = app.scroll
  let last = min(app.view.len, app.scroll + app.listRows) - 1
  for k in first .. last: result.add app.view[k]

proc rowOfNote(app: App; title: string): int =
  ## The screen row of a note, or -1 when it is filtered out or scrolled away.
  for k, idx in app.visibleNotes:
    if app.notes[idx].title == title: return app.listTop + k
  -1

proc noteAtRow(app: App; row: int): string =
  let k = row - app.listTop
  let vis = app.visibleNotes
  if k >= 0 and k < vis.len: app.notes[vis[k]].title else: ""

proc buttonCol(i: int): int =
  ## Toolbar buttons are "[Sort] [Filter] [New]" starting at column 1.
  result = 1
  for k in 0 ..< i: result += ToolbarButtons[k].len + 3

proc buttonAt(app: App; row, col: int): string =
  if row != 1: return ""
  for i, b in ToolbarButtons:
    let c = buttonCol(i)
    if col >= c and col < c + b.len + 2: return b
  ""

proc dialogRect*(app: App): Rect =
  let w = min(40, app.width - 4)
  Rect(row: app.height div 2 - 3, col: (app.width - w) div 2, w: w, h: 6)

proc menuItems(app: App): seq[string] =
  let k = app.noteIndex(app.menuNote)
  @[(if k >= 0 and app.notes[k].pinned: "Unpin" else: "Pin"), "Rename", "Archive"]

proc menuRect*(app: App): Rect =
  Rect(row: app.menuRow, col: app.menuCol, w: MenuWidth, h: app.menuItems.len + 2)

proc hint(label: string): string =
  case label
  of "Sort": "Sort notes by title"
  of "Filter": "Show pinned notes only"
  of "New": "Create a note"
  else: ""

# --- the asynchronous part ---------------------------------------------------------

proc applyView(app: App) =
  var v: seq[int]
  for k, n in app.notes:
    if app.appliedSearch.len == 0: v.add k
    else:
      let q = app.appliedSearch.toLowerAscii
      var hit = q in n.title.toLowerAscii
      for t in n.tags:
        if q == t.toLowerAscii: hit = true
      if hit: v.add k
  app.view = v
  app.scroll = max(0, min(app.scroll, app.view.len - app.listRows))

proc startPending(app: App; kind: PendingKind; arg = "") =
  app.pending = kind
  app.pendingArg = arg
  app.pendingDue = app.now + OpDelay
  app.status = "Loading..."

proc tick*(app: App) =
  ## Completes an asynchronous operation whose time has come.
  if app.pending == pendNone or app.now < app.pendingDue: return
  case app.pending
  of pendSort:
    app.notes.sort(proc (a, b: Note): int = cmp(a.title, b.title))
    app.sorted = true
    app.status = "Sorted by title"
  of pendFilter:
    app.appliedSearch = app.pendingArg
    app.status = (if app.appliedSearch.len == 0: "Ready" else: "Filtered: " & app.appliedSearch)
  of pendArchive:
    var keep: seq[Note]
    for n in app.notes:
      if n.title notin app.selected: keep.add n
    app.notes = keep
    app.selected.clear()
    app.status = "Archived"
  of pendNone: discard
  app.pending = pendNone
  inc app.loadedGeneration
  app.applyView()

proc settled*(app: App): bool =
  ## The input has been handled and no gesture is in progress. Asynchronous
  ## work may still be running: that is `loaded`, a separate condition.
  app.tick()
  not app.dragging

# --- operations ------------------------------------------------------------------

proc selectOnly(app: App; title: string) =
  app.selected.clear()
  if title != "": app.selected.incl title
  app.anchor = title

proc openDialog(app: App; title: string) =
  if title == "": return
  app.dialogOpen = true
  app.dialogTarget = title
  app.dialogValue = title
  app.dialogCaret = title.runeLen
  app.focus = focusDialogField
  app.menuOpen = false

proc closeDialog(app: App; commit: bool) =
  if commit and app.dialogValue.len > 0:
    let k = app.noteIndex(app.dialogTarget)
    if k >= 0:
      let wasSel = app.dialogTarget in app.selected
      app.notes[k].title = app.dialogValue
      if wasSel:
        app.selected.excl app.dialogTarget
        app.selected.incl app.dialogValue
      app.status = "Renamed"
  app.dialogOpen = false
  app.focus = focusList

proc runOperation*(app: App; op: string) =
  case op
  of "notes.archive-selected":
    if app.selected.len > 0: app.startPending(pendArchive)
  of "notes.rename":
    if app.selected.len == 1:
      for t in app.selected: app.openDialog(t)
  of "notes.sort": app.startPending(pendSort)
  of "notes.focus-search": app.focus = focusSearch
  of "notes.pin":
    for t in app.selected:
      let k = app.noteIndex(t)
      if k >= 0: app.notes[k].pinned = not app.notes[k].pinned
  else: discard

proc chordOf(e: InputEvent): string =
  if e.kind notin {evKey, evChar}: return ""
  for m in [mkCtrl, mkShift, mkAlt, mkMeta]:
    if m in e.mods:
      result.add (case m
        of mkCtrl: "Ctrl+"
        of mkShift: "Shift+"
        of mkAlt: "Alt+"
        of mkMeta: "Meta+")
  result.add (if e.kind == evKey: e.key else: e.ch)

proc editText(text: var string; caret: var int; e: InputEvent): bool =
  ## Line editing shared by the search field and the dialog field.
  var runes = text.toRunes
  caret = max(0, min(caret, runes.len))
  result = true
  if e.kind == evChar and (e.mods * {mkCtrl, mkAlt, mkMeta}) == {}:
    runes = runes[0 ..< caret] & e.ch.toRunes & runes[caret .. ^1]
    caret += e.ch.runeLen
  elif e.kind == evKey and e.key == "Backspace":
    if caret > 0:
      runes.delete(caret - 1)
      dec caret
  elif e.kind == evKey and e.key == "Delete":
    if caret < runes.len: runes.delete(caret)
  elif e.kind == evKey and e.key == "Left": caret = max(0, caret - 1)
  elif e.kind == evKey and e.key == "Right": caret = min(runes.len, caret + 1)
  elif e.kind == evKey and e.key == "Home": caret = 0
  elif e.kind == evKey and e.key == "End": caret = runes.len
  elif (e.kind == evChar and e.ch == "a" and mkCtrl in e.mods) or
       (e.kind == evKey and e.key == "a" and mkCtrl in e.mods):
    # select all: the next character replaces everything
    runes.setLen(0)
    caret = 0
  else:
    result = false
  text = $runes

proc moveSelection(app: App; delta: int; extend: bool) =
  if app.view.len == 0: return
  var cur = -1
  for k, idx in app.view:
    if app.notes[idx].title == app.anchor: cur = k
  let next = max(0, min(app.view.len - 1, (if cur < 0: 0 else: cur + delta)))
  let title = app.notes[app.view[next]].title
  if extend:
    app.selected.incl title
  else:
    app.selectOnly(title)
  app.anchor = title
  if next < app.scroll: app.scroll = next
  if next >= app.scroll + app.listRows: app.scroll = next - app.listRows + 1

proc handleKey(app: App; e: InputEvent) =
  let chord = chordOf(e)
  for op, c in app.keymap:
    if c == chord and not app.dialogOpen:
      app.runOperation(op)
      return
  if app.dialogOpen:
    if e.kind == evKey and e.key == "Enter": app.closeDialog(true)
    elif e.kind == evKey and e.key == "Esc": app.closeDialog(false)
    else: discard editText(app.dialogValue, app.dialogCaret, e)
    return
  if app.menuOpen and e.kind == evKey and e.key == "Esc":
    app.menuOpen = false
    return
  if e.kind == evKey and e.key == "Tab":
    app.focus = (if app.focus == focusSearch: focusList else: focusSearch)
    return
  case app.focus
  of focusSearch:
    if e.kind == evKey and e.key == "Esc":
      app.search = ""
      app.searchCaret = 0
      app.startPending(pendFilter, "")
    elif e.kind == evKey and e.key in ["Down", "Enter"]:
      app.focus = focusList
    elif editText(app.search, app.searchCaret, e):
      app.startPending(pendFilter, app.search)
  of focusList:
    if e.kind == evKey:
      case e.key
      of "Up": app.moveSelection(-1, mkShift in e.mods)
      of "Down": app.moveSelection(1, mkShift in e.mods)
      of "Esc": app.selectOnly("")
      of "Enter":
        if app.selected.len == 1:
          for t in app.selected: app.openDialog(t)
      else: discard
  of focusDialogField: discard

# --- the pointer ---------------------------------------------------------------------

proc inRect(r: Rect; row, col: int): bool =
  row >= r.row and row < r.row + r.h and col >= r.col and col < r.col + r.w

proc click(app: App; e: InputEvent; count: int) =
  let (row, col) = (e.row, e.col)
  if app.dialogOpen:
    let d = app.dialogRect
    if row == d.row + 4:
      if col >= d.col + 2 and col < d.col + 6: app.closeDialog(true)
      elif col >= d.col + 7 and col < d.col + 15: app.closeDialog(false)
    elif row == d.row + 2 and col >= d.col + 8:
      app.dialogCaret = min(app.dialogValue.runeLen, col - (d.col + 8))
      app.focus = focusDialogField
    return
  if app.menuOpen:
    let m = app.menuRect
    if inRect(m, row, col) and row > m.row and row < m.row + m.h - 1:
      let item = app.menuItems[row - m.row - 1]
      let title = app.menuNote
      app.menuOpen = false
      case item
      of "Pin", "Unpin":
        let k = app.noteIndex(title)
        if k >= 0: app.notes[k].pinned = item == "Pin"
        app.status = (if item == "Pin": "Pinned" else: "Unpinned")
      of "Rename": app.openDialog(title)
      of "Archive":
        app.selectOnly(title)
        app.startPending(pendArchive)
      else: discard
      return
    app.menuOpen = false
    return
  let b = app.buttonAt(row, col)
  if b != "":
    case b
    of "Sort": app.startPending(pendSort)
    of "Filter":
      app.search = "pinned"
      app.searchCaret = app.search.len
      app.startPending(pendFilter, "pinned")
    of "New":
      var n = 1
      while app.noteIndex("Untitled " & $n) >= 0: inc n
      app.notes.add Note(title: "Untitled " & $n)
      app.applyView()
    else: discard
    return
  if row == 2 and col >= 8:
    app.focus = focusSearch
    app.searchCaret = min(app.search.runeLen, col - 8)
    return
  let title = app.noteAtRow(row)
  if title == "": return
  app.focus = focusList
  if e.button == mbRight:
    app.selectOnly(title)
    app.menuOpen = true
    app.menuNote = title
    app.menuRow = min(row + 1, app.height - app.menuItems.len - 3)
    app.menuCol = min(col, app.width - MenuWidth - 1)
    return
  if count >= 2:
    app.selectOnly(title)
    app.openDialog(title)
    return
  if mkCtrl in e.mods or mkMeta in e.mods:
    if title in app.selected: app.selected.excl title else: app.selected.incl title
    app.anchor = title
  elif mkShift in e.mods and app.anchor != "":
    var a, b2 = -1
    for k, idx in app.view:
      if app.notes[idx].title == app.anchor: a = k
      if app.notes[idx].title == title: b2 = k
    if a >= 0 and b2 >= 0:
      for k in min(a, b2) .. max(a, b2): app.selected.incl app.notes[app.view[k]].title
  else:
    app.selectOnly(title)

proc handlePointer(app: App; e: InputEvent) =
  case e.kind
  of evPress:
    app.pressRow = e.row
    app.pressCol = e.col
    app.pressButton = e.button
    let title = app.noteAtRow(e.row)
    if e.button == mbLeft and title != "" and e.col in 1 .. 2 and not app.dialogOpen and
        not app.menuOpen:
      app.dragFrom = title
      app.dragOver = title
  of evMove:
    if app.dragFrom != "" and e.button == mbLeft:
      app.dragging = true
      let over = app.noteAtRow(e.row)
      if over != "": app.dragOver = over
    elif e.button == mbNone:
      let label = app.buttonAt(e.row, e.col)
      if label != app.hoverLabel:
        app.hoverLabel = label
        app.status = (if label == "": "Ready" else: hint(label))
  of evRelease:
    if app.dragFrom != "":
      let over = app.noteAtRow(e.row)
      if app.dragging and over != "" and over != app.dragFrom:
        let a = app.noteIndex(app.dragFrom)
        let note = app.notes[a]
        app.notes.delete(a)
        let b = app.noteIndex(over)
        app.notes.insert(note, b)
        app.applyView()
        app.status = "Moved " & note.title
        app.dragFrom = ""
        app.dragging = false
        return
      app.dragFrom = ""
      app.dragging = false
    if e.row == app.pressRow and e.col == app.pressCol:
      let t = app.now
      var count = 1
      if e.button == mbLeft and t - app.lastClickAt <= DoubleClickMs and
          app.lastClickCell == (e.row, e.col):
        count = 2
        app.lastClickAt = 0
      else:
        app.lastClickAt = t
      app.lastClickCell = (e.row, e.col)
      app.click(InputEvent(kind: evRelease, row: e.row, col: e.col, button: app.pressButton,
                           mods: e.mods), count)
  of evWheel:
    if e.row >= app.listTop and e.row < app.listTop + app.listRows:
      let maxScroll = max(0, app.view.len - app.listRows)
      app.scroll = max(0, min(maxScroll, app.scroll + (if e.wheelUp: -1 else: 1)))
  else: discard

proc handle*(app: App; e: InputEvent) =
  app.tick()
  inc app.events
  case e.kind
  of evKey, evChar: app.handleKey(e)
  else: app.handlePointer(e)

# --- the surface: role instances, their properties and where they are ------------------

proc el(role: string; rect: Rect; props: JsonNode; keys: seq[(string, string)] = @[]): Element =
  Element(role: role, rect: rect, props: props, keys: keys)

proc surface*(app: App): Element =
  ## The tree of role instances on screen, with their properties. This is the
  ## conformance pack's role model, read from the application's own state.
  app.tick()
  let w = app.width
  result = el("window", Rect(row: 0, col: 0, w: w, h: app.height), %*{"title": "Notes"})
  var tb = el("toolbar", Rect(row: 1, col: 0, w: w, h: 1), newJObject())
  for i, b in ToolbarButtons:
    tb.children.add el("toolbar-button", Rect(row: 1, col: buttonCol(i), w: b.len + 2, h: 1),
      %*{"label": b, "enabled": true}, @[("label", b)])
  result.children.add tb
  result.children.add el("search-field", Rect(row: 2, col: 8, w: w - 8, h: 1),
    %*{"value": app.search, "focused": app.focus == focusSearch and not app.dialogOpen})
  var order: seq[string]
  for idx in app.view: order.add app.notes[idx].title
  var list = el("note-list", Rect(row: app.listTop, col: 0, w: w, h: app.listRows),
    %*{"count": app.view.len, "order": order,
       "first-visible": (if app.scroll < app.view.len: app.notes[app.view[app.scroll]].title else: "")})
  for pos, idx in app.view:
    let n = app.notes[idx]
    let k = pos - app.scroll
    let rect = Rect(row: app.listTop + k, col: 0, w: w, h: 1)
    list.children.add el("note", rect, %*{"title": n.title, "selected": n.title in app.selected,
      "pinned": n.pinned, "body": n.body, "tags": n.tags, "position": pos + 1,
      "state": "active"}, @[("title", n.title)])
  result.children.add list
  result.children.add el("status-bar", Rect(row: app.height - 1, col: 0, w: w, h: 1),
    %*{"message": app.status})
  if app.wallClock != nil:
    result.children.add el("clock", app.clockRect, %*{"time": app.wallClock()})
  if app.dialogOpen:
    let d = app.dialogRect
    var dlg = el("dialog", d, %*{"title": "Rename"}, @[("title", "Rename")])
    dlg.children.add el("text-field", Rect(row: d.row + 2, col: d.col + 8, w: d.w - 10, h: 1),
      %*{"label": "Name", "value": app.dialogValue, "focused": app.focus == focusDialogField},
      @[("label", "Name")])
    dlg.children.add el("dialog-button", Rect(row: d.row + 4, col: d.col + 2, w: 4, h: 1),
      %*{"label": "OK"}, @[("label", "OK")])
    dlg.children.add el("dialog-button", Rect(row: d.row + 4, col: d.col + 7, w: 8, h: 1),
      %*{"label": "Cancel"}, @[("label", "Cancel")])
    result.children.add dlg
  if app.menuOpen:
    let m = app.menuRect
    var menu = el("context-menu", m, newJObject())
    for i, item in app.menuItems:
      menu.children.add el("menu-item", Rect(row: m.row + 1 + i, col: m.col + 1, w: m.w - 2, h: 1),
        %*{"label": item, "enabled": true}, @[("label", item)])
    result.children.add menu

proc focusedRole*(app: App): string =
  if app.dialogOpen: "text-field"
  elif app.focus == focusSearch: "search-field"
  else: "note-list"

# --- rendering to cells ---------------------------------------------------------------

proc put(g: var seq[seq[Cell]]; row, col: int; s: string; reverse = false; bold = false) =
  if row < 0 or row >= g.len: return
  var c = col
  for r in s.runes:
    if c >= 0 and c < g[row].len:
      g[row][c] = Cell(text: $r, reverse: reverse, bold: bold)
    inc c

proc render*(app: App): seq[seq[Cell]] =
  app.tick()
  result = newSeq[seq[Cell]](app.height)
  for r in 0 ..< app.height:
    result[r] = newSeq[Cell](app.width)
    for c in 0 ..< app.width: result[r][c] = Cell(text: " ")
  result.put(0, 0, " Notes ", bold = true)
  # the list's size, right-aligned: what a reader of the screen counts by
  let size = $app.view.len & " notes "
  result.put(0, app.width - size.len, size)
  if app.wallClock != nil: result.put(0, app.clockRect.col, app.wallClock())
  for i, b in ToolbarButtons:
    result.put(1, buttonCol(i), "[" & b & "]", reverse = app.hoverLabel == b)
  result.put(2, 0, "Search: ")
  result.put(2, 8, app.search, reverse = false)
  for k, idx in app.visibleNotes:
    let n = app.notes[idx]
    let sel = n.title in app.selected
    var line = (if sel: ">" else: " ") & "::" & " " & n.title
    if n.pinned: line.add " *"
    if app.dragging and n.title == app.dragOver and app.dragOver != app.dragFrom: line.add " <"
    result.put(app.listTop + k, 0, line, reverse = sel)
  if app.view.len == 0:
    result.put(app.listTop, 1, "(no notes)")
  result.put(app.height - 1, 0, " " & app.status)
  if app.menuOpen:
    let m = app.menuRect
    result.put(m.row, m.col, "+" & "-".repeat(m.w - 2) & "+")
    for i, item in app.menuItems:
      result.put(m.row + 1 + i, m.col, "|" & alignLeft(" " & item, m.w - 2) & "|")
    result.put(m.row + m.h - 1, m.col, "+" & "-".repeat(m.w - 2) & "+")
  if app.dialogOpen:
    let d = app.dialogRect
    result.put(d.row, d.col, "+" & "-".repeat(d.w - 2) & "+")
    result.put(d.row + 1, d.col, "|" & center("Rename", d.w - 2) & "|")
    result.put(d.row + 2, d.col, "| Name: " & alignLeft(app.dialogValue, d.w - 9) & "|")
    result.put(d.row + 3, d.col, "|" & " ".repeat(d.w - 2) & "|")
    result.put(d.row + 4, d.col, "| [OK] [Cancel]" & " ".repeat(d.w - 16) & "|")
    result.put(d.row + 5, d.col, "+" & "-".repeat(d.w - 2) & "+")

proc screenText*(app: App): seq[string] =
  for row in app.render:
    var s = ""
    for c in row: s.add c.text
    result.add s

proc cursorCell*(app: App): (int, int) =
  if app.dialogOpen:
    let d = app.dialogRect
    (d.row + 2, d.col + 8 + app.dialogCaret)
  elif app.focus == focusSearch: (2, 8 + app.searchCaret)
  else: (-1, -1)

# --- terminal input decoding -------------------------------------------------------------

proc sgrMods(code: int): set[ModKey] =
  if (code and 4) != 0: result.incl mkShift
  if (code and 8) != 0: result.incl mkAlt
  if (code and 16) != 0: result.incl mkCtrl

proc csiMods(p: int): set[ModKey] =
  ## xterm modifier parameter: 1 + (shift 1, alt 2, ctrl 4, meta 8)
  let m = p - 1
  if (m and 1) != 0: result.incl mkShift
  if (m and 2) != 0: result.incl mkAlt
  if (m and 4) != 0: result.incl mkCtrl
  if (m and 8) != 0: result.incl mkMeta

proc btnOf(b: int): MouseButton =
  case b
  of 0: mbLeft
  of 1: mbMiddle
  of 2: mbRight
  else: mbNone

proc decodeTerminalInput*(buf: var string): seq[InputEvent] =
  ## Decodes as many complete events as `buf` holds and leaves an incomplete
  ## escape sequence in it. A lone ESC at the end of `buf` is the Esc key.
  var i = 0
  while i < buf.len:
    let c = buf[i]
    if c == '\e':
      if i + 1 >= buf.len:
        result.add InputEvent(kind: evKey, key: "Esc")
        inc i
        continue
      let n = buf[i + 1]
      if n == '[':
        # CSI: parameters, then a final byte
        var j = i + 2
        let mouse = j < buf.len and buf[j] == '<'
        if mouse: inc j
        let pstart = j
        while j < buf.len and buf[j] in {'0'..'9', ';'}: inc j
        if j >= buf.len: break   # incomplete
        let final = buf[j]
        let params = buf[pstart ..< j].split(';')
        proc pint(k: int): int =
          if k < params.len and params[k].len > 0: parseInt(params[k]) else: 0
        if mouse and final in {'M', 'm'} and params.len == 3:
          let code = pint(0)
          let col = pint(1) - 1
          let row = pint(2) - 1
          let mods = sgrMods(code)
          let base = code and not (4 or 8 or 16)
          if (base and 64) != 0:
            result.add InputEvent(kind: evWheel, row: row, col: col, mods: mods,
                                  wheelUp: (base and 1) == 0)
          elif (base and 32) != 0:
            let b = base and 3
            result.add InputEvent(kind: evMove, row: row, col: col, mods: mods, button: btnOf(b))
          else:
            let b = base and 3
            let btn = btnOf(b)
            result.add InputEvent(kind: (if final == 'M': evPress else: evRelease),
                                  row: row, col: col, mods: mods, button: btn)
        else:
          let mods = (if params.len >= 2: csiMods(pint(1)) else: {})
          let key = case final
            of 'A': "Up"
            of 'B': "Down"
            of 'C': "Right"
            of 'D': "Left"
            of 'H': "Home"
            of 'F': "End"
            of 'Z': "Tab"
            of '~':
              case pint(0)
              of 1, 7: "Home"
              of 2: "Insert"
              of 3: "Delete"
              of 4, 8: "End"
              of 5: "PageUp"
              of 6: "PageDown"
              of 15: "F5"
              of 17: "F6"
              of 18: "F7"
              of 19: "F8"
              of 20: "F9"
              of 21: "F10"
              of 23: "F11"
              of 24: "F12"
              else: ""
            else: ""
          if key != "":
            var ev = InputEvent(kind: evKey, key: key, mods: mods)
            if final == 'Z': ev.mods.incl mkShift
            result.add ev
        i = j + 1
      elif n == 'O' and i + 2 < buf.len:
        let key = case buf[i + 2]
          of 'P': "F1"
          of 'Q': "F2"
          of 'R': "F3"
          of 'S': "F4"
          of 'H': "Home"
          of 'F': "End"
          else: ""
        if key != "": result.add InputEvent(kind: evKey, key: key)
        i += 3
      elif n == 'O':
        break   # incomplete
      else:
        # Alt+key
        let r = buf.runeAt(i + 1)
        result.add InputEvent(kind: evChar, ch: $r, mods: {mkAlt})
        i += 1 + r.size
    elif c == '\r' or c == '\n':
      result.add InputEvent(kind: evKey, key: "Enter")
      inc i
    elif c == '\t':
      result.add InputEvent(kind: evKey, key: "Tab")
      inc i
    elif c == '\x7f' or c == '\b':
      result.add InputEvent(kind: evKey, key: "Backspace")
      inc i
    elif ord(c) >= 1 and ord(c) <= 26:
      result.add InputEvent(kind: evChar, ch: $chr(ord(c) + ord('a') - 1), mods: {mkCtrl})
      inc i
    elif ord(c) < 32:
      inc i
    else:
      let r = buf.runeAt(i)
      result.add InputEvent(kind: evChar, ch: $r)
      i += r.size
  buf = buf[i .. ^1]
