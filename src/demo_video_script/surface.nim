## A surface: the tree of role instances a binding derived from what it
## observed, and the locator resolution over it.
##
## A binding that can produce the whole tree at once (from a terminal screen,
## an OCR pass or a model's state) builds `SurfaceNode`s and lets this module
## answer `locate`, `read` and `hit`; it then never resolves locators itself, so
## every such backend resolves them the same way (§4.2: one, none or ambiguous,
## with candidates). Instances are identified by their path of child indices,
## valid until the next input.

import std/[json, tables, options, strutils]
import ./backend

type
  SurfaceNode* = ref object
    role*: string
    keys*: seq[(string, string)]
    props*: JsonNode                 ## the properties the binding can read
    x*, y*, w*, h*: float            ## geometry in the backend's unit
    visible*: bool
    focused*: bool                   ## this instance has input focus
    unreadable*: Table[string, string]
      ## properties the binding cannot read right now, and why

  SurfaceIndex* = object
    ids: Table[string, seq[int]]
    next: int

proc node*(role: string; x, y, w, h: float; props: JsonNode = newJObject();
           keys: seq[(string, string)] = @[]; visible = true): SurfaceNode =
  SurfaceNode(role: role, keys: keys, props: props, x: x, y: y, w: w, h: h, visible: visible)

type Tree* = object
  root*: SurfaceNode
  children*: Table[pointer, seq[SurfaceNode]]

proc add*(t: var Tree; parent, child: SurfaceNode) =
  t.children.mgetOrPut(cast[pointer](parent), @[]).add child

proc kids*(t: Tree; n: SurfaceNode): seq[SurfaceNode] =
  t.children.getOrDefault(cast[pointer](n))

proc keyText*(n: SurfaceNode): string =
  if n.keys.len == 0: return n.role
  var parts: seq[string]
  for (k, v) in n.keys: parts.add k & "=\"" & v & "\""
  n.role & "[" & parts.join(", ") & "]"

proc matches(n: SurfaceNode; seg: JsonNode): bool =
  if n.role != seg{"role"}.getStr: return false
  for k, v in seg{"keys"}.getFields:
    var found = false
    for (kk, vv) in n.keys:
      if kk == k and vv == v.getStr: found = true
    if not found: return false
  true

proc pathTo(t: Tree; cur, target: SurfaceNode; path: var seq[int]): bool =
  if cur == target: return true
  for i, c in t.kids(cur):
    path.add i
    if t.pathTo(c, target, path): return true
    discard path.pop
  false

proc at*(t: Tree; path: seq[int]): SurfaceNode =
  result = t.root
  for i in path:
    let k = t.kids(result)
    if i >= k.len: return nil
    result = k[i]

proc parentOf(t: Tree; cur, target: SurfaceNode): SurfaceNode =
  for c in t.kids(cur):
    if c == target: return cur
    let p = t.parentOf(c, target)
    if p != nil: return p
  nil

proc focusedNode(t: Tree; n: SurfaceNode): SurfaceNode =
  if n.focused: return n
  for c in t.kids(n):
    let f = t.focusedNode(c)
    if f != nil: return f
  nil

proc register*(idx: var SurfaceIndex; t: Tree; n: SurfaceNode): string =
  var path: seq[int]
  discard t.pathTo(t.root, n, path)
  inc idx.next
  result = "i" & $idx.next
  idx.ids[result] = path

proc clear*(idx: var SurfaceIndex) = idx.ids.clear()

proc lookup*(idx: SurfaceIndex; t: Tree; id: string): SurfaceNode =
  if not idx.ids.hasKey(id): raise backendError(beNotFound, "no instance " & id)
  result = t.at(idx.ids[id])
  if result == nil: raise backendError(beNotFound, "instance " & id & " is gone")

proc locate*(idx: var SurfaceIndex; t: Tree; locator: JsonNode): LocateResult =
  var cur: SurfaceNode = nil
  let relative = locator.hasKey("parent")
  if relative: cur = idx.lookup(t, locator["parent"].getStr)
  for k, seg in locator{"segments"}.getElems:
    if seg.hasKey("focused"):
      cur = t.focusedNode(t.root)
      if cur == nil: return LocateResult(outcome: loNone, candidates: @["(nothing has focus)"])
      continue
    if seg.hasKey("ancestor"):
      var a = t.parentOf(t.root, cur)
      while a != nil and a.role != seg["ancestor"].getStr: a = t.parentOf(t.root, a)
      if a == nil: return LocateResult(outcome: loNone)
      cur = a
      continue
    var pool: seq[SurfaceNode]
    let parent = (if cur == nil: t.root else: cur)
    if cur == nil and k == 0 and not relative:
      if t.root.matches(seg): pool.add t.root
    for c in t.kids(parent):
      if c.matches(seg): pool.add c
    let ordinal = seg{"ordinal"}.getInt(0)
    var seen: seq[string]
    for c in t.kids(parent):
      if c.role == seg{"role"}.getStr: seen.add c.keyText
    if ordinal > 0:
      if ordinal > pool.len: return LocateResult(outcome: loNone, candidates: seen)
      cur = pool[ordinal - 1]
    elif pool.len == 0: return LocateResult(outcome: loNone, candidates: seen)
    elif pool.len > 1:
      var amb: seq[string]
      for e in pool: amb.add e.keyText
      return LocateResult(outcome: loAmbiguous, candidates: amb)
    else: cur = pool[0]
  if cur == nil: return LocateResult(outcome: loNone)
  LocateResult(outcome: loOne, instance: idx.register(t, cur), role: cur.role)

proc readNode*(n: SurfaceNode; props: seq[string]): JsonNode =
  result = newJObject()
  for p in props:
    if n.unreadable.hasKey(p):
      raise backendError(beUnsupported, "'" & p & "' of " & n.keyText & " cannot be read: " &
        n.unreadable[p])
    if p == "geometry":
      result[p] = %*{"x": n.x, "y": n.y, "w": n.w, "h": n.h, "visible": n.visible}
    elif p == "present": result[p] = %true
    elif n.props.hasKey(p): result[p] = n.props[p]

proc hit*(t: Tree; x, y: float): Option[string] =
  proc inside(n: SurfaceNode): bool = x >= n.x and x < n.x + n.w and y >= n.y and y < n.y + n.h
  if not inside(t.root): return none(string)
  var path = @[t.root]
  while true:
    var next: SurfaceNode = nil
    for c in t.kids(path[^1]):
      if inside(c): next = c
    if next == nil: break
    path.add next
  var segs: seq[string]
  for k in 1 ..< path.len:
    let n = path[k]
    if n.keys.len > 0:
      segs.add n.keyText
      continue
    var same, idx = 0
    for c in t.kids(path[k - 1]):
      if c.role == n.role:
        inc same
        if c == n: idx = same
    segs.add (if same > 1: n.role & "[#" & $idx & "]" else: n.role)
  some(if segs.len == 0: t.root.role else: segs.join("/"))
