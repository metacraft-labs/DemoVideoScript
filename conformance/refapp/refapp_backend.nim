## The reference backend: the backend protocol over the conformance
## application's headless core.
##
## It introspects the application's state for `locate` and `read` (as a backend
## reading a DOM or an accessibility tree does), and delivers every input as the
## bytes a terminal would send — keys, SGR mouse reports — through the
## application's own input decoder (`decodeTerminalInput`). It exists so the
## runner can be qualified without any adapter (the format repository depends
## on no backend), and it carries the planted-defect arms of the conformance
## suite: a stale read, an input one cell off, a sync condition that fires
## early, and a read with a side effect.
##
## It is a real backend over a real program, not a stand-in for one: the same
## core is what the terminal, web and X11 builds of the application run.

import std/[json, tables, options, monotimes, times, os, strutils, unicode, sets]
import demo_video_script/backend
import ../app/notes_core

type
  PlantedDefect* = enum
    dfNone = "none", dfStaleRead = "stale-read", dfOffByOne = "off-by-one",
    dfEarlySync = "early-sync", dfReadSideEffect = "read-side-effect"

  RefappState = ref object
    app: App
    fixture: JsonNode
    stageClosed: bool
    defect: PlantedDefect
    ids: Table[string, seq[int]]   ## instance id -> child-index path from the root
    nextId: int
    beforeSend: Element            ## the surface before the last input (stale-read arm)
    heldMods: set[ModKey]
    realistic: bool
    t0: MonoTime
    without: seq[string]           ## capabilities withheld (to qualify `unsupported`)

const Capabilities = ["input.key", "input.chord", "input.text", "input.pointer.move",
                      "input.pointer.click", "input.pointer.drag", "input.wheel", "input.hover",
                      "observe.text", "observe.geometry", "observe.focus", "sync.event",
                      "record.still"]

proc nowMs(st: RefappState): int64 = (getMonoTime() - st.t0).inMilliseconds

proc requireApp(st: RefappState) =
  if st.app == nil:
    raise backendError(beInternal, "the application is not running (no launch-app stage)")

# --- the surface ---------------------------------------------------------------------

proc keyText(e: Element): string =
  if e.keys.len == 0: return e.role
  var parts: seq[string]
  for (k, v) in e.keys: parts.add k & "=\"" & v & "\""
  e.role & "[" & parts.join(", ") & "]"

proc atPath(root: Element; path: seq[int]): Element =
  result = root
  for i in path:
    if result == nil or i >= result.children.len: return nil
    result = result.children[i]

proc findPath(root, target: Element; path: var seq[int]): bool =
  if root == target: return true
  for i, c in root.children:
    path.add i
    if findPath(c, target, path): return true
    discard path.pop
  false

proc focusedElement(st: RefappState; root: Element): Element =
  let role = st.app.focusedRole
  proc walk(e: Element): Element =
    if e.role == role: return e
    for c in e.children:
      let r = walk(c)
      if r != nil: return r
    nil
  walk(root)

proc matches(e: Element; seg: JsonNode): bool =
  if e.role != seg{"role"}.getStr: return false
  for k, v in seg{"keys"}.getFields:
    var found = false
    for (kk, vv) in e.keys:
      if kk == k and vv == v.getStr: found = true
    if not found: return false
  true

proc register(st: RefappState; root, e: Element): string =
  var path: seq[int]
  discard findPath(root, e, path)
  inc st.nextId
  result = "e" & $st.nextId
  st.ids[result] = path

proc surfaceForRead(st: RefappState): Element =
  if st.defect == dfStaleRead and st.beforeSend != nil: st.beforeSend
  else: st.app.surface

proc parentOf(root, e: Element): Element =
  for c in root.children:
    if c == e: return root
    let p = parentOf(c, e)
    if p != nil: return p
  nil

proc locateIn(st: RefappState; locator: JsonNode): LocateResult =
  st.requireApp()
  let root = st.app.surface
  var cur: Element = nil
  if locator.hasKey("parent"):
    let id = locator["parent"].getStr
    if not st.ids.hasKey(id): raise backendError(beNotFound, "no instance " & id)
    cur = atPath(root, st.ids[id])
    if cur == nil: return LocateResult(outcome: loNone)
  let segs = locator{"segments"}.getElems
  for k, seg in segs:
    if seg.hasKey("focused"):
      cur = st.focusedElement(root)
      if cur == nil: return LocateResult(outcome: loNone, candidates: @["(nothing has focus)"])
      continue
    if seg.hasKey("ancestor"):
      var a = parentOf(root, cur)
      while a != nil and a.role != seg["ancestor"].getStr: a = parentOf(root, a)
      if a == nil: return LocateResult(outcome: loNone)
      cur = a
      continue
    var pool: seq[Element]
    if cur == nil and k == 0 and not locator.hasKey("parent"):
      if root.matches(seg): pool.add root
      for c in root.children:
        if c.matches(seg): pool.add c
    else:
      for c in cur.children:
        if c.matches(seg): pool.add c
    let ordinal = seg{"ordinal"}.getInt(0)
    if ordinal > 0:
      if ordinal > pool.len:
        var seen: seq[string]
        for e in pool: seen.add e.keyText
        return LocateResult(outcome: loNone, candidates: seen)
      cur = pool[ordinal - 1]
    elif pool.len == 0:
      var seen: seq[string]
      let parent = (if cur == nil: root else: cur)
      for c in parent.children:
        if c.role == seg{"role"}.getStr: seen.add c.keyText
      return LocateResult(outcome: loNone, candidates: seen)
    elif pool.len > 1:
      var seen: seq[string]
      for e in pool: seen.add e.keyText
      return LocateResult(outcome: loAmbiguous, candidates: seen)
    else:
      cur = pool[0]
  if cur == nil: return LocateResult(outcome: loNone)
  LocateResult(outcome: loOne, instance: st.register(root, cur), role: cur.role)

proc geometryJson(st: RefappState; e: Element): JsonNode =
  var visible = e.rect.row >= 0 and e.rect.row < st.app.height
  if e.role == "note":
    visible = e.rect.row >= st.app.listTop and e.rect.row < st.app.listTop + st.app.listRows
  %*{"x": e.rect.col, "y": e.rect.row, "w": e.rect.w, "h": e.rect.h, "visible": visible}

proc readIn(st: RefappState; id: string; props: seq[string]): JsonNode =
  st.requireApp()
  if not st.ids.hasKey(id): raise backendError(beNotFound, "no instance " & id)
  let e = atPath(st.surfaceForRead, st.ids[id])
  if e == nil: raise backendError(beNotFound, "instance " & id & " is gone")
  result = newJObject()
  for p in props:
    if p == "geometry": result[p] = st.geometryJson(e)
    elif p == "present": result[p] = %true
    elif e.props.hasKey(p): result[p] = e.props[p]
  if st.defect == dfReadSideEffect:
    # the planted defect: reading a note toggles its selection, and reading
    # anything else moves the list
    if e.role == "note":
      let t = e.props{"title"}.getStr
      if t in st.app.selected: st.app.selected.excl t else: st.app.selected.incl t
    else:
      st.app.scroll = (st.app.scroll + 1) mod max(1, st.app.view.len)

# --- input as terminal bytes ---------------------------------------------------------------

proc refuse(msg: string): ref BackendError = backendError(beRefused, msg)

proc modParam(mods: set[ModKey]): int =
  result = 1
  if mkShift in mods: result += 1
  if mkAlt in mods: result += 2
  if mkCtrl in mods: result += 4

proc modsOf(names: openArray[string]): set[ModKey] =
  for n in names:
    case n
    of "Ctrl": result.incl mkCtrl
    of "Shift": result.incl mkShift
    of "Alt": result.incl mkAlt
    of "Meta": result.incl mkMeta
    else: discard

proc keyBytes(key: string; mods: set[ModKey]): string =
  ## The bytes a terminal sends for a key with modifiers; refuses what a
  ## terminal cannot express rather than sending another key.
  if mkMeta in mods: raise refuse("a terminal cannot deliver the Meta modifier (" & key & ")")
  let csiFinal = {"Up": 'A', "Down": 'B', "Right": 'C', "Left": 'D', "Home": 'H', "End": 'F'}.toTable
  let tilde = {"Insert": 2, "Delete": 3, "PageUp": 5, "PageDown": 6, "F5": 15, "F6": 17,
               "F7": 18, "F8": 19, "F9": 20, "F10": 21, "F11": 23, "F12": 24}.toTable
  let ss3 = {"F1": 'P', "F2": 'Q', "F3": 'R', "F4": 'S'}.toTable
  if csiFinal.hasKey(key):
    return (if mods == {}: "\e[" & $csiFinal[key] else: "\e[1;" & $modParam(mods) & $csiFinal[key])
  if tilde.hasKey(key):
    return "\e[" & $tilde[key] & (if mods == {}: "" else: ";" & $modParam(mods)) & "~"
  if ss3.hasKey(key):
    return (if mods == {}: "\eO" & $ss3[key] else: "\e[1;" & $modParam(mods) & $ss3[key])
  var base = case key
    of "Enter": "\r"
    of "Tab": (if mkShift in mods: "\e[Z" else: "\t")
    of "Esc": "\e"
    of "Backspace": "\x7f"
    of "Space": " "
    of "Plus": "+"
    of "Ctrl", "Shift", "Alt", "Meta", "Mod":
      raise refuse("a terminal cannot deliver the " & key & " key on its own")
    else: key
  if key in ["Tab"] and mkShift in mods: return base
  if base.runeLen != 1:
    raise refuse("no terminal encoding for the key '" & key & "'")
  var m = mods
  if mkShift in m and base.len == 1 and base[0] in {'a'..'z'}:
    base = $base[0].toUpperAscii
    m.excl mkShift
  if mkShift in m and key notin ["Enter", "Esc", "Backspace", "Space"] and base.len == 1 and
      base[0] notin {'a'..'z', 'A'..'Z'}:
    m.excl mkShift   # a shifted symbol is the symbol itself
  if mkCtrl in m:
    let c = base.toLowerAscii
    if c.len == 1 and c[0] in {'a'..'z'}:
      base = $chr(ord(c[0]) - ord('a') + 1)
      m.excl mkCtrl
    else:
      raise refuse("a terminal cannot deliver Ctrl+" & key)
  if mkShift in m: raise refuse("a terminal cannot deliver Shift+" & key)
  if mkAlt in m: base = "\e" & base
  base

proc chordBytes(chord: string): string =
  for c in chord.split(' '):
    let parts = c.split('+')
    result.add keyBytes(parts[^1], modsOf(parts[0 ..< parts.high]))

proc sgr(code, row, col: int; press: bool): string =
  "\e[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) & (if press: "M" else: "m")

proc modBits(mods: set[ModKey]): int =
  (if mkShift in mods: 4 else: 0) + (if mkAlt in mods: 8 else: 0) +
    (if mkCtrl in mods: 16 else: 0)

proc feed(st: RefappState; bytes: string) =
  var buf = bytes
  for e in decodeTerminalInput(buf): st.app.handle(e)

proc elementOf(st: RefappState; id: string): Element =
  if not st.ids.hasKey(id): raise backendError(beNotFound, "no instance " & id)
  result = atPath(st.app.surface, st.ids[id])
  if result == nil: raise backendError(beNotFound, "instance " & id & " is gone")

proc anchorCell(st: RefappState; id: string; anchor: string): (int, int) =
  let e = st.elementOf(id)
  var (row, col) = (e.rect.row + e.rect.h div 2, e.rect.col + max(0, e.rect.w div 2 - 1))
  if anchor.len > 0 and anchor != "center":
    let name = anchor.split('(')[0]
    case name
    of "handle": col = e.rect.col + 1
    of "title-end":
      col = e.rect.col + 4 + e.props{"title"}.getStr.runeLen - 1
    of "caret-at":
      col = e.rect.col + parseInt(anchor[anchor.find('(') + 1 ..< anchor.find(')')])
    else: raise backendError(beUnsupported, "no anchor '" & anchor & "' on " & e.role)
  if st.defect == dfOffByOne: inc row
  (row, col)

proc pause(st: RefappState; ms: float) =
  if st.realistic and ms > 0: sleep(int(ms + 0.5))

proc movePath(st: RefappState; path: JsonNode; code: int) =
  ## Motion reports along a paced path (realistic runs).
  if path == nil: return
  var last = 0.0
  for p in path:
    let t = p[2].getFloat
    st.pause(t - last)
    last = t
    st.feed(sgr(code, int(p[1].getFloat + 0.5), int(p[0].getFloat + 0.5), true))

proc sendAction(st: RefappState; a: JsonNode) =
  st.requireApp()
  st.beforeSend = st.app.surface
  st.realistic = a.hasKey("timing")
  let targets = a{"targets"}
  let timing = a{"timing"}
  if a.hasKey("ext"):
    raise backendError(beUnsupported, "the reference backend has no extension steps")
  if a.hasKey("key"):
    let k = a["key"]{"key"}.getStr(a["key"].getStr)
    st.feed(keyBytes(k, st.heldMods))
  elif a.hasKey("chord"):
    st.feed(chordBytes(a["chord"].getStr))
  elif a.hasKey("type"):
    let text = (if a["type"].kind == JString: a["type"].getStr else: a["type"]{"text"}.getStr)
    let delays = timing{"keyDelaysMs"}
    var k = 0
    for r in text.runes:
      if delays != nil and k < delays.len: st.pause(delays[k].getFloat)
      st.feed($r)
      inc k
  elif a.hasKey("press") or a.hasKey("release"):
    let isPress = a.hasKey("press")
    let v = (if isPress: a["press"] else: a["release"])
    if v.hasKey("key"):
      let k = v["key"].getStr
      let m = modsOf([k])
      if m == {}:
        raise refuse("a terminal sends a key's press and release together; it cannot hold '" & k & "'")
      if mkMeta in m: raise refuse("a terminal cannot deliver the Meta modifier")
      if isPress: st.heldMods.incl m else: st.heldMods.excl m
    else:
      let (row, col) = st.anchorCell(targets["target"].getStr, v{"anchor"}.getStr)
      let b = case v{"button"}.getStr("left")
        of "middle": 1
        of "right": 2
        else: 0
      st.feed(sgr(b + modBits(st.heldMods), row, col, isPress))
  elif a.hasKey("move") or a.hasKey("hover"):
    let v = (if a.hasKey("move"): a["move"] else: a["hover"])
    st.movePath(timing{"path"}, 35)
    let (row, col) = st.anchorCell(targets["target"].getStr, v{"anchor"}.getStr)
    st.feed(sgr(35 + modBits(st.heldMods), row, col, true))
    if a.hasKey("hover"):
      let f = v{"for"}.getStr("")
      if f.len > 0:
        let ms = (if f.endsWith("ms"): parseFloat(f[0 ..< f.len - 2])
                  elif f.endsWith("s"): parseFloat(f[0 ..< f.len - 1]) * 1000
                  else: parseFloat(f) * 1000)
        sleep(int(ms))
  elif a.hasKey("click"):
    let v = a["click"]
    st.movePath(timing{"path"}, 35)
    let (row, col) = st.anchorCell(targets["target"].getStr, v{"anchor"}.getStr)
    var mods = st.heldMods
    for m in v{"modifiers"}.getElems:
      mods = mods + modsOf([m.getStr])
    if mkMeta in mods: raise refuse("a terminal cannot deliver the Meta modifier")
    let b = case v{"button"}.getStr("left")
      of "middle": 1
      of "right": 2
      else: 0
    for _ in 1 .. v{"count"}.getInt(1):
      st.feed(sgr(b + modBits(mods), row, col, true))
      st.feed(sgr(b + modBits(mods), row, col, false))
  elif a.hasKey("drag"):
    let v = a["drag"]
    st.movePath(timing{"approach"}, 35)
    let fa = (if v["from"].kind == JObject: v["from"]{"anchor"}.getStr else: "")
    let ta = (if v["to"].kind == JObject: v["to"]{"anchor"}.getStr else: "")
    let (r0, c0) = st.anchorCell(targets["from"].getStr, fa)
    let mods = modBits(st.heldMods)
    st.feed(sgr(0 + mods, r0, c0, true))
    for vid in targets{"via"}.getElems:
      let (rv, cv) = st.anchorCell(vid.getStr, "")
      st.feed(sgr(32 + mods, rv, cv, true))
    st.movePath(timing{"path"}, 32 + mods)
    let (r1, c1) = st.anchorCell(targets["to"].getStr, ta)
    st.feed(sgr(32 + mods, r1, c1, true))
    st.feed(sgr(0 + mods, r1, c1, false))
  elif a.hasKey("wheel"):
    let v = a["wheel"]
    let (row, col) = st.anchorCell(targets["target"].getStr, v{"anchor"}.getStr)
    let code = case v{"direction"}.getStr
      of "up": 64
      of "down": 65
      of "left": 66
      else: 67
    for _ in 1 .. v{"amount"}.getInt(1):
      st.feed(sgr(code + modBits(st.heldMods), row, col, true))
  else:
    raise backendError(beProtocol, "send: no input action in " & $a)
  st.ids.clear()   # instance ids are valid until the next input

proc awaitCond(st: RefappState; cond: string; timeoutMs: int): bool =
  st.requireApp()
  if st.defect == dfEarlySync: return true
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    let met = case cond
      of "settled": st.app.settled
      of "note-list.loaded": (st.app.tick(); not st.app.loading)
      of "idle": st.app.settled and not st.app.loading
      else: raise backendError(beUnsupported, "the reference backend cannot detect '" & cond & "'")
    if met: return true
    if getMonoTime() > deadline: return false
    sleep(10)

proc hitAt(st: RefappState; x, y: float): Option[string] =
  st.requireApp()
  let root = st.app.surface
  let (row, col) = (int(y), int(x))
  proc inside(e: Element): bool =
    row >= e.rect.row and row < e.rect.row + e.rect.h and col >= e.rect.col and
      col < e.rect.col + e.rect.w
  var path: seq[Element]
  var cur = root
  if not inside(cur): return none(string)
  path.add cur
  while true:
    var next: Element = nil
    for c in cur.children:
      if inside(c): next = c
    if next == nil: break
    path.add next
    cur = next
  var segs: seq[string]
  for k in 1 ..< path.len:
    let e = path[k]
    if e.keys.len > 0: segs.add e.keyText
    else:
      var same = 0
      for c in path[k - 1].children:
        if c.role == e.role: inc same
      if same > 1:
        var idx = 1
        for c in path[k - 1].children:
          if c == e: break
          if c.role == e.role: inc idx
        segs.add e.role & "[#" & $idx & "]"
      else: segs.add e.role
  if segs.len == 0: some(root.role) else: some(segs.join("/"))

proc newRefappBackend*(defect: PlantedDefect = dfNone; without: seq[string] = @[]): Backend =
  let st = RefappState(defect: defect, t0: getMonoTime(), without: without)
  result = Backend()
  result.hello = proc (): Hello =
    var caps: seq[string]
    for c in Capabilities:
      if c notin st.without: caps.add c
    Hello(backend: "refapp", version: "1", platform: "linux", capabilities: caps,
          bindings: newJNull(), units: "cell")
  result.stage = proc (use: string; args: JsonNode) =
    if st.stageClosed:
      raise backendError(beStageClosed, "the stage has ended; '" & use & "' cannot run now")
    let base = args{"$base"}.getStr(".")
    case use
    of "seed-notes":
      let f = args{"fixture"}.getStr
      let path = (if f.isAbsolute: f else: base / f)
      if not fileExists(path): raise backendError(beStage, "seed-notes: no fixture " & path)
      st.fixture = parseFile(path)
    of "launch-app":
      st.app = newApp(args{"width"}.getInt(60), args{"height"}.getInt(16),
                      proc (): int64 = st.nowMs)
      if st.fixture != nil: st.app.loadNotes(st.fixture)
    of "set-clock": discard   # the application shows no clock
    of "mark-started":
      let path = args{"path"}.getStr
      writeFile((if path.isAbsolute: path else: base / path), "the stage ran\n")
    else: raise backendError(beStage, "no stage procedure '" & use & "'")
  result.endStage = proc () = st.stageClosed = true
  result.resolveChord = proc (operation: string): Option[string] =
    st.requireApp()
    if st.app.keymap.hasKey(operation): some(st.app.keymap[operation]) else: none(string)
  result.locate = proc (locator: JsonNode): LocateResult = st.locateIn(locator)
  result.read = proc (instance: string; properties: seq[string]): JsonNode =
    st.readIn(instance, properties)
  result.send = proc (action: JsonNode) = st.sendAction(action)
  result.await = proc (condition, instance: string; timeoutMs: int): bool =
    st.awaitCond(condition, timeoutMs)
  result.record = proc (op: RecordOp; args: JsonNode): JsonNode =
    result = %*{"files": []}
    if op == recStill:
      st.requireApp()
      let path = args{"dir"}.getStr(".") / args{"path"}.getStr("still") & ".txt"
      createDir(path.parentDir)
      writeFile(path, st.app.screenText.join("\n") & "\n")
      result["files"] = %[path]
  result.hit = proc (x, y: float): Option[string] = st.hitAt(x, y)
  result.close = proc () = discard
