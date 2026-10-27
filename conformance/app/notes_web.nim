## The conformance application's web build: the headless core (notes_core.nim)
## compiled to JavaScript and drawn in a page.
##
##   nim js -d:release -o:conformance/app/web/notes_web.js conformance/app/notes_web.nim
##
## The cells are drawn as text rows in a monospace grid. Each role instance of
## the core's surface is also a transparent element over its cells, carrying
## `data-role`, its keys as `data-key-<name>` and its properties as
## `data-props` (JSON): what a DOM binding reads. Pointer and keyboard events on
## the page become the core's input events at the cell under the pointer, so
## the page behaves as the terminal and window builds do.
##
## The page reads its notes from `window.DVS_FIXTURE` (a JSON string, set
## before the page loads) and its size from the URL (`?w=60&h=16`).

import std/[json, strutils]
import std/dom except Element
from std/dom import nil
import ./notes_core

proc perfNow(): float {.importjs: "performance.now()".}
proc fixtureText(): cstring {.importjs: "(window.DVS_FIXTURE || '')".}
proc queryInt(name: cstring; default: int): int {.importjs:
  "(parseInt(new URLSearchParams(window.location.search).get(#)) || #)".}
proc setIntervalMs(f: proc () {.closure.}; ms: int) {.importjs: "setInterval(#, #)".}
proc cellWidthPx(e: dom.Element): float {.importjs: "#.getBoundingClientRect().width".}
proc boxLeft(e: dom.Element): float {.importjs: "#.getBoundingClientRect().left".}
proc boxTop(e: dom.Element): float {.importjs: "#.getBoundingClientRect().top".}
proc evX(e: Event): float {.importjs: "#.clientX".}
proc evY(e: Event): float {.importjs: "#.clientY".}
proc evButton(e: Event): int {.importjs: "#.button".}
proc evButtons(e: Event): int {.importjs: "#.buttons".}
proc evDeltaY(e: Event): float {.importjs: "#.deltaY".}
proc evKey(e: Event): cstring {.importjs: "#.key".}
proc evShift(e: Event): bool {.importjs: "#.shiftKey".}
proc evCtrl(e: Event): bool {.importjs: "#.ctrlKey".}
proc evAlt(e: Event): bool {.importjs: "#.altKey".}
proc evMeta(e: Event): bool {.importjs: "#.metaKey".}
proc setHtml(e: dom.Element; s: cstring) {.importjs: "#.innerHTML = #".}

const CellH = 20.0

var cellW = 9.6
let t0 = perfNow()
let app = newApp(queryInt("w", 60), queryInt("h", 16), proc (): int64 = int64(perfNow() - t0))

proc esc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc overlay(e: Element; html: var string) =
  var attrs = "data-role=\"" & e.role & "\""
  for (k, v) in e.keys: attrs.add " data-key-" & k & "=\"" & esc(v) & "\""
  attrs.add " data-props=\"" & esc($e.props) & "\""
  let style = "left:" & $(float(e.rect.col) * cellW) & "px;top:" & $(float(e.rect.row) * CellH) &
    "px;width:" & $(float(e.rect.w) * cellW) & "px;height:" & $(float(e.rect.h) * CellH) & "px"
  html.add "<div class=\"role\" " & attrs & " style=\"" & style & "\">"
  for c in e.children: overlay(c, html)
  html.add "</div>"

proc relative(e: Element; parentRow, parentCol: int): Element =
  ## Nested overlays are positioned relative to their parent overlay.
  result = Element(role: e.role, keys: e.keys, props: e.props,
                   rect: Rect(row: e.rect.row - parentRow, col: e.rect.col - parentCol,
                              w: e.rect.w, h: e.rect.h))
  for c in e.children: result.children.add relative(c, e.rect.row, e.rect.col)

var lastHtml = ""

proc draw() =
  var html = "<div class=\"grid\">"
  let (cr, cc) = app.cursorCell
  for r, row in app.render:
    html.add "<div class=\"row\">"
    for c, cell in row:
      var cls = ""
      if cell.reverse or (r == cr and c == cc): cls.add " rev"
      if cell.bold: cls.add " bold"
      let t = (if cell.text == " ": "&nbsp;" else: esc(cell.text))
      html.add (if cls.len > 0: "<span class=\"" & cls.strip & "\">" & t & "</span>" else: t)
    html.add "</div>"
  html.add "</div><div class=\"roles\">"
  overlay(relative(app.surface, 0, 0), html)
  html.add "</div>"
  if html != lastHtml:
    document.getElementById("app").setHtml(cstring(html))
    lastHtml = html

proc mods(e: Event): set[ModKey] =
  if e.evShift: result.incl mkShift
  if e.evCtrl: result.incl mkCtrl
  if e.evAlt: result.incl mkAlt
  if e.evMeta: result.incl mkMeta

proc cellOf(e: Event): (int, int) =
  let box = document.getElementById("app")
  (int((e.evY - box.boxTop) / CellH), int((e.evX - box.boxLeft) / cellW))

proc buttonOf(code: int): MouseButton =
  case code
  of 0: mbLeft
  of 1: mbMiddle
  of 2: mbRight
  else: mbNone

proc feed(ev: InputEvent) =
  app.handle(ev)
  draw()

proc onPointer(kind: EventKind): proc (e: Event) =
  result = proc (e: Event) =
    e.preventDefault()
    let (row, col) = cellOf(e)
    var ev = InputEvent(kind: kind, row: row, col: col, mods: mods(e))
    case kind
    of evPress, evRelease: ev.button = buttonOf(e.evButton)
    of evMove:
      let held = e.evButtons
      ev.button = (if (held and 1) != 0: mbLeft elif (held and 2) != 0: mbRight
                   elif (held and 4) != 0: mbMiddle else: mbNone)
    of evWheel: ev.wheelUp = e.evDeltaY < 0
    else: discard
    feed(ev)

const keyNames = [("Enter", "Enter"), ("Escape", "Esc"), ("Tab", "Tab"),
                  ("Backspace", "Backspace"), ("Delete", "Delete"), ("Insert", "Insert"),
                  ("Home", "Home"), ("End", "End"), ("PageUp", "PageUp"),
                  ("PageDown", "PageDown"), ("ArrowUp", "Up"), ("ArrowDown", "Down"),
                  ("ArrowLeft", "Left"), ("ArrowRight", "Right")]

proc onKey(e: Event) =
  let k = $e.evKey
  if k in ["Shift", "Control", "Alt", "Meta"]: return
  e.preventDefault()
  for (dom, name) in keyNames:
    if k == dom:
      feed(InputEvent(kind: evKey, key: name, mods: mods(e)))
      return
  if k.len >= 2 and k[0] == 'F' and k[1 .. ^1].allCharsInSet(Digits):
    feed(InputEvent(kind: evKey, key: k, mods: mods(e)))
    return
  var m = mods(e)
  var ch = k
  if m * {mkCtrl, mkAlt, mkMeta} != {}: ch = ch.toLowerAscii
  m.excl mkShift   # the shifted character already says it
  feed(InputEvent(kind: evChar, ch: ch, mods: m))

proc main() =
  let root = document.getElementById("app")
  let probe = document.getElementById("probe")
  cellW = probe.cellWidthPx
  let fx = $fixtureText()
  if fx.len > 0: app.loadNotes(parseJson(fx))
  root.addEventListener("mousedown", onPointer(evPress))
  root.addEventListener("mouseup", onPointer(evRelease))
  root.addEventListener("mousemove", onPointer(evMove))
  root.addEventListener("wheel", onPointer(evWheel))
  root.addEventListener("contextmenu", proc (e: Event) = e.preventDefault())
  document.addEventListener("keydown", onKey)
  draw()
  setIntervalMs(proc () = draw(), 20)

main()
