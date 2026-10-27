## The linter: §11's rules over a parsed scenario and its pack.
##
## L1 (only input, observations, waits, flows, beats and annotations in steps)
## is enforced by the parser, because the schema enforces it too; flows are
## checked for it after expansion here (L11). The other rules need the pack or
## the whole scenario:
##
## | L2  | every locator resolves against the role declarations (and every
##        property an observation reads is declared)                      | error |
## | L3  | an input action's target role declares the affordance          | error |
## | L4  | an ordinal locator                                              | warning |
## | L5  | an observation directly after an input action with `settle: false`
##        and no wait between                                             | error |
## | L6  | a `dwell` or `lead-in` followed by an observation with no sync between
##                                                                         | warning |
## | L7  | an assertion, sync condition, flow or stage referenced but not
##        declared, or invoked with the wrong arguments                    | error |
## | L8  | an extension step whose backend the scenario does not `require`  | error |
## | L9  | narration, caption or callout anchored to a step or beat that does
##        not exist                                                       | error |
## | L10 | a pack role, property, flow or assertion name that collides with a
##        format keyword                                                   | error |
## | L11 | a flow that, expanded, violates L1                               | error |
## | L12 | two steps with the same id, two beats with the same name, or two
##        captures with the same name                                      | error |

import std/[strutils, tables, sets]
import ./model, ./yaml, ./scenario, ./predicates

type
  Linter = object
    pack: Pack
    sc: Scenario
    file: string
    diags: Diagnostics
    flowStack: seq[string]
    callSite: tuple[active: bool, line, col: int, flow: string]

proc emit(l: var Linter; line, col: int; rule: string; sev: Severity; msg: string) =
  var (ln, cl, m) = (line, col, msg)
  if l.callSite.active:
    (ln, cl) = (l.callSite.line, l.callSite.col)
    m = "in flow '" & l.callSite.flow & "': " & msg
  l.diags.add Diagnostic(rule: rule, severity: sev, phase: phSemantic, file: l.file,
                         line: ln, col: cl, message: m)

proc err(l: var Linter; line, col: int; rule, msg: string) = l.emit(line, col, rule, sevError, msg)
proc warn(l: var Linter; line, col: int; rule, msg: string) = l.emit(line, col, rule, sevWarning, msg)

# --- locators ------------------------------------------------------------------

proc descendsFrom(pack: Pack; ancestor, role: string; seen: var HashSet[string]): bool =
  if ancestor == role: return true
  if ancestor in seen or not pack.roles.hasKey(ancestor): return false
  seen.incl ancestor
  for ch in pack.roles[ancestor].children.keys:
    if descendsFrom(pack, ch, role, seen): return true
  false

proc resolveLocator(l: var Linter; loc: Locator; text: string; line, col: int): string =
  ## The role a locator names, statically; "" when it depends on focus or does
  ## not resolve (an L2 error is reported for the latter).
  let pack = l.pack
  var cur = ""
  var dynamic = false
  for k, seg in loc.segments:
    case seg.kind
    of segFocused:
      dynamic = true
      cur = ""
    of segAncestor:
      if not pack.roles.hasKey(seg.role):
        l.err(line, col, "L2", "locator '" & text & "': ancestor(" & seg.role &
          ") names no declared role")
        return ""
      if cur != "":
        var seen: HashSet[string]
        if not descendsFrom(pack, seg.role, cur, seen) or seg.role == cur:
          l.err(line, col, "L2", "locator '" & text & "': '" & cur &
            "' never has an ancestor '" & seg.role & "'")
          return ""
      dynamic = false
      cur = seg.role
    of segRole:
      if not pack.roles.hasKey(seg.role):
        l.err(line, col, "L2", "locator '" & text & "': '" & seg.role & "' is not a declared role")
        return ""
      if k == 0:
        if seg.role != pack.root and not pack.roles[pack.root].children.hasKey(seg.role):
          l.err(line, col, "L2", "locator '" & text & "': '" & seg.role &
            "' is neither the root '" & pack.root & "' nor one of its children")
          return ""
      elif not dynamic and cur != "":
        if not pack.roles[cur].children.hasKey(seg.role):
          l.err(line, col, "L2", "locator '" & text & "': '" & seg.role &
            "' is not a child of '" & cur & "'")
          return ""
      let role = pack.roles[seg.role]
      for kv in seg.keys:
        if kv.key notin role.keys:
          l.err(line, col, "L2", "locator '" & text & "': '" & kv.key & "' is not a key of '" &
            seg.role & "' (keys: " & (if role.keys.len == 0: "none" else: role.keys.join(", ")) & ")")
      if seg.ordinal > 0:
        l.warn(line, col, "L4", "locator '" & text & "' selects by ordinal [#" & $seg.ordinal &
          "]; a re-sort silently selects another instance — prefer a semantic key")
      dynamic = false
      cur = seg.role
  if dynamic: "" else: cur

proc checkAnchor(l: var Linter; role: string; t: Target) =
  if role == "" or t.anchor.name == "" or t.anchor.name == "center": return
  for a in l.pack.roles[role].anchors:
    if a.name == t.anchor.name:
      if a.params.len != t.anchor.args.len:
        l.err(t.line, t.col, "L2", "anchor '" & t.anchor.name & "' of '" & role & "' takes " &
          $a.params.len & " argument(s)")
      return
  l.err(t.line, t.col, "L2", "'" & t.anchor.name & "' is not an anchor of '" & role & "'")

proc target(l: var Linter; t: Target): string =
  result = l.resolveLocator(t.at, $t.at, t.line, t.col)
  l.checkAnchor(result, t)

proc requireAffordance(l: var Linter; role: string; aff: Affordance; t: Target; action: string) =
  if role == "": return   # focus-relative: checked at run time
  if aff notin l.pack.roles[role].affordances:
    l.err(t.line, t.col, "L3", action & " on '" & $t.at & "': role '" & role &
      "' does not afford " & $aff)

# --- observations ---------------------------------------------------------------

proc packHasProp*(pack: Pack; role, prop: string): bool =
  prop in ImplicitProperties or (pack.roles.hasKey(role) and pack.roles[role].properties.hasKey(prop))


proc checkInvocation(l: var Linter; role: string; inv: Invocation; line, col: int) =
  let r = l.pack.roles[role]
  if not r.assertions.hasKey(inv.name):
    l.err(line, col, "L7", "'" & inv.name & "' is not a named assertion of '" & role & "'")
    return
  let decl = r.assertions[inv.name]
  if decl.sig.params.len != inv.args.len:
    l.err(line, col, "L7", "'" & inv.name & "' takes " & $decl.sig.params.len &
      " argument(s), given " & $inv.args.len)
    return
  if decl.pred == nil: return
  var problems: seq[string]
  var dyn: seq[tuple[param, role: string]]
  checkPredicate(l.pack, role, decl.sig.params, decl.pred, problems, dyn)
  var reported: HashSet[string]
  for (param, childRole) in dyn:
    if param & "/" & childRole in reported: continue
    reported.incl param & "/" & childRole
    let idx = decl.sig.params.find(param)
    let arg = inv.args[idx]
    if arg.kind != argNumber and not packHasProp(l.pack, childRole, arg.text):
      l.err(line, col, "L7", "'" & inv.name & "(" & arg.text & ")': '" & arg.text &
        "' is not a property of '" & childRole & "'")

proc checkObservation(l: var Linter; o: Observation) =
  let role = l.resolveLocator(o.target.at, $o.target.at, o.target.line, o.target.col)
  if o.role != "" and not l.pack.roles.hasKey(o.role):
    l.err(o.target.line, o.target.col, "L2", "role '" & o.role & "' is not declared")
  for rel in o.geometry.relations:
    discard l.resolveLocator(rel.other, $rel.other, o.target.line, o.target.col)
  if role == "": return
  for p in o.properties.keys:
    if not l.pack.roles[role].properties.hasKey(p):
      l.err(o.target.line, o.target.col, "L2", "'" & p & "' is not a property of '" & role & "'")
  for inv in o.asserts:
    l.checkInvocation(role, inv, o.target.line, o.target.col)

proc checkSyncName(l: var Linter; name: string; line, col: int) =
  if name == "settled": return   # the implicit condition every pack's binding provides
  let dot = name.find('.')
  if dot > 0 and l.pack.roles.hasKey(name[0 ..< dot]):
    let role = name[0 ..< dot]
    let cond = name[dot + 1 .. ^1]
    if not l.pack.roles[role].sync.hasKey(cond):
      l.err(line, col, "L7", "'" & cond & "' is not a sync condition of '" & role & "'")
    return
  if not l.pack.sync.hasKey(name):
    l.err(line, col, "L7", "sync condition '" & name & "' is not declared by the pack or a role")

# --- flows -----------------------------------------------------------------------

proc substitute(n: YNode; args: Table[string, string]): YNode =
  case n.kind
  of yString:
    var s = n.s
    for k, v in args: s = s.replace("${" & k & "}", v)
    YNode(kind: yString, s: s, quoted: n.quoted, line: n.line, col: n.col)
  of ySeq:
    var r = YNode(kind: ySeq, line: n.line, col: n.col)
    for it in n.items: r.items.add substitute(it, args)
    r
  of yMap:
    var r = YNode(kind: yMap, line: n.line, col: n.col)
    for k in 0 ..< n.keys.len:
      r.keys.add n.keys[k]
      r.values.add substitute(n.values[k], args)
    r
  else: n

proc expandFlow*(pack: Pack; name: string; args: YNode; diags: var Diagnostics;
                 file: string): seq[Step] =
  ## The flow's steps with its parameters substituted. Parse problems are
  ## returned in `diags` (structural, with the pack file's positions).
  let f = pack.flows[name]
  var subst: Table[string, string]
  for p in f.sig.params:
    let v = (if args == nil: nil else: args.get(p))
    subst[p] = (if v == nil: "" else: v.scalarText)
  var c = Ctx(file: file)
  result = c.parseSteps(substitute(f.body, subst), "flow '" & name & "'")
  diags = c.diags

proc lintSteps(l: var Linter; steps: seq[Step])

proc lintFlowCall(l: var Linter; s: Step) =
  if not l.pack.flows.hasKey(s.name):
    l.err(s.line, s.col, "L7", "flow '" & s.name & "' is not declared by the pack")
    return
  let f = l.pack.flows[s.name]
  var given: HashSet[string]
  if s.args != nil:
    for k, v in s.args.pairs:
      given.incl k.s
      if k.s notin f.sig.params:
        l.err(k.line, k.col, "L7", "flow '" & s.name & "' has no parameter '" & k.s & "'")
      elif v.kind in {ySeq, yMap}:
        l.err(v.line, v.col, "L7", "flow argument '" & k.s & "' must be a scalar")
  for p in f.sig.params:
    if p notin given:
      l.err(s.line, s.col, "L7", "flow '" & s.name & "' needs argument '" & p & "'")
  if s.name in l.flowStack:
    l.err(s.line, s.col, "L11", "flow '" & s.name & "' calls itself (" &
      (l.flowStack & @[s.name]).join(" → ") & ")")
    return
  var pd: Diagnostics
  let steps = expandFlow(l.pack, s.name, s.args, pd, l.file)
  for d in pd:
    if d.severity == sevError:
      l.err(s.line, s.col, "L11", "flow '" & s.name & "', expanded: " & d.message &
        " (" & l.pack.file & ":" & $d.line & ")")
  let saved = l.callSite
  if not l.callSite.active: l.callSite = (true, s.line, s.col, s.name)
  l.flowStack.add s.name
  l.lintSteps(steps)
  discard l.flowStack.pop
  l.callSite = saved

# --- steps -----------------------------------------------------------------------

proc lintStep(l: var Linter; s: Step) =
  for c in s.callouts:
    discard l.target(c.target)
  case s.kind
  of stClick:
    let role = l.target(s.target)
    let aff = (if s.button == btnRight: affContextClick
               elif s.count >= 2: affDoubleClick
               else: affClick)
    l.requireAffordance(role, aff, s.target, "click")
  of stPress, stRelease:
    if s.isButton:
      let role = l.target(s.target)
      l.requireAffordance(role, (if s.button == btnRight: affContextClick else: affClick),
                          s.target, $s.kind)
  of stMove, stHover:
    discard l.target(s.target)
  of stDrag:
    let fr = l.target(s.dragFrom)
    l.requireAffordance(fr, affDragSource, s.dragFrom, "drag from")
    for v in s.via: discard l.target(v)
    let to = l.target(s.dragTo)
    l.requireAffordance(to, affDropTarget, s.dragTo, "drag to")
  of stWheel:
    let role = l.target(s.target)
    l.requireAffordance(role, affWheel, s.target, "wheel")
  of stExpect:
    l.checkObservation(s.observation)
  of stWait:
    if s.untilIsObservation: l.checkObservation(s.observation)
    else: l.checkSyncName(s.untilName, s.line, s.col)
  of stCapture:
    if s.hasCaptureOf: discard l.target(s.captureOf)
  of stFlow:
    l.lintFlowCall(s)
  of stBeat:
    l.lintSteps(s.steps)
  of stExt:
    let backend = s.name.split('.')[0]
    if backend notin l.sc.requires:
      l.err(s.line, s.col, "L8", "extension step 'ext: " & s.name & "' needs backend '" &
        backend & "'; declare it with requires: [" & backend & "]")
  of stKey, stChord, stType: discard
  for _, alt in s.alternatives:
    l.lintSteps(alt)

proc lintSteps(l: var Linter; steps: seq[Step]) =
  for s in steps: l.lintStep(s)

# --- sequence rules (L5, L6) over the flattened run order ----------------------------

proc flatten(l: Linter; steps: seq[Step]; depth: int; into: var seq[Step]) =
  for s in steps:
    case s.kind
    of stBeat: l.flatten(s.steps, depth, into)
    of stFlow:
      if depth < 8 and l.pack != nil and l.pack.flows.hasKey(s.name):
        var pd: Diagnostics
        let body = expandFlow(l.pack, s.name, s.args, pd, l.file)
        var inner: seq[Step]
        l.flatten(body, depth + 1, inner)
        for x in inner:
          # report flow-internal sequence findings at the call site
          x.line = s.line
          x.col = s.col
          into.add x
      else: into.add s
    else: into.add s

proc lintSequence(l: var Linter) =
  var flat: seq[Step]
  l.flatten(l.sc.steps, 0, flat)
  for k in 0 ..< flat.len:
    let s = flat[k]
    let next = (if k + 1 < flat.len: flat[k + 1] else: nil)
    if s.kind in InputKinds and not s.settle and next != nil and next.kind == stExpect:
      l.err(next.line, next.col, "L5", "this observation directly follows an input action " &
        "with settle: false and no wait; add a wait on the condition the input causes")
    if s.dwell >= 0 and next != nil and next.kind == stExpect:
      l.warn(next.line, next.col, "L6", "this observation follows a dwell with no sync " &
        "condition between; it may depend on time (dwell has no effect in fast mode)")
    if s.leadIn >= 0 and s.kind == stExpect and k > 0 and flat[k - 1].kind != stWait:
      l.warn(s.line, s.col, "L6", "this observation has a lead-in and no sync condition " &
        "before it; it may depend on time")

# --- anchors and duplicates (L9, L12) -------------------------------------------------

proc collectNames(steps: seq[Step]; ids, beats, captures: var Table[string, Step];
                  dups: var seq[(Step, string)]) =
  for s in steps:
    if s.id != "":
      if ids.hasKey(s.id) or beats.hasKey(s.id): dups.add (s, "step id '" & s.id & "'")
      else: ids[s.id] = s
    if s.kind == stBeat:
      if beats.hasKey(s.name) or ids.hasKey(s.name): dups.add (s, "beat '" & s.name & "'")
      else: beats[s.name] = s
      collectNames(s.steps, ids, beats, captures, dups)
    if s.kind == stCapture:
      if captures.hasKey(s.name): dups.add (s, "capture '" & s.name & "'")
      else: captures[s.name] = s

proc lintAnchors(l: var Linter) =
  var ids, beats, captures: Table[string, Step]
  var dups: seq[(Step, string)]
  collectNames(l.sc.steps, ids, beats, captures, dups)
  for (s, what) in dups:
    l.err(s.line, s.col, "L12", "duplicate " & what & "; anchors and citations must be unique")
  proc known(name: string): bool = name == "" or ids.hasKey(name) or beats.hasKey(name)
  proc walk(l: var Linter; steps: seq[Step]) =
    for s in steps:
      if s.hasNarration:
        for a in [s.narration.fromId, s.narration.toId]:
          if not known(a):
            l.err(s.narration.line, s.narration.col, "L9", "narration is anchored to '" & a &
              "', which is no step id or beat")
      if s.hasCaption:
        for a in [s.caption.fromId, s.caption.toId]:
          if not known(a):
            l.err(s.caption.line, s.caption.col, "L9", "caption is anchored to '" & a &
              "', which is no step id or beat")
      for c in s.callouts:
        for a in [c.fromId, c.toId]:
          if not known(a):
            l.err(c.line, c.col, "L9", "callout is anchored to '" & a &
              "', which is no step id or beat")
      if s.kind == stBeat: walk(l, s.steps)
  l.walk(l.sc.steps)

# --- the pack (L10, L11 at definition) ------------------------------------------------

proc predicateWords(): HashSet[string] =
  for k in PredicateKeywords:
    if k != "count": result.incl k   # `count` is a name unless written count(role)

proc roleKeywords(): HashSet[string] =
  ## A role name appears in locators and predicates.
  result = predicateWords()
  for k in ["focused", "ancestor", "count"]: result.incl k

proc propertyKeywords(): HashSet[string] =
  ## A property name appears as an observation key and in predicates.
  result = predicateWords()
  for k in ReservedObservationKeys: result.incl k
  for k in ImplicitProperties: result.incl k

proc flowKeywords(): HashSet[string] =
  for k in ActionKeys: result.incl k
  for k in AnnotationKeys: result.incl k
  for k in ["settle", "steps", "with"]: result.incl k

proc lintPack*(pack: Pack): Diagnostics =
  ## L10 and L11 for a pack on its own.
  let rk = roleKeywords()
  let pk = propertyKeywords()
  let ak = predicateWords()
  let fk = flowKeywords()
  var l = Linter(pack: pack, file: pack.file)
  for role in pack.roles.values:
    if role.name in rk:
      l.err(role.line, role.col, "L10", "role name '" & role.name & "' is a format keyword")
    for p in role.properties.keys:
      if p in pk:
        l.err(role.line, role.col, "L10", "property '" & role.name & "." & p &
          "' is a format keyword and cannot be observed")
    for a in role.assertions.keys:
      if a in ak or a == "count":
        l.err(role.line, role.col, "L10", "assertion '" & role.name & "." & a & "' is a format keyword")
  for f in pack.flows.values:
    if f.sig.name in fk:
      l.err(f.line, f.col, "L10", "flow name '" & f.sig.name & "' is a format keyword")
    var args = YNode(kind: yMap)
    for p in f.sig.params:
      args.keys.add YNode(kind: yString, s: p)
      args.values.add YNode(kind: yString, s: "x")
    var pd: Diagnostics
    discard expandFlow(pack, f.sig.name, args, pd, pack.file)
    for d in pd:
      if d.severity == sevError:
        l.diags.add Diagnostic(rule: "L11", severity: sevError, phase: phSemantic,
          file: pack.file, line: d.line, col: d.col,
          message: "flow '" & f.sig.name & "': " & d.message)
  l.diags

# --- static resolution, for the runner ------------------------------------------------

proc staticRole*(pack: Pack; loc: Locator): string =
  ## The role a locator names, or "" when it depends on focus or does not resolve.
  if pack == nil: return ""
  var l = Linter(pack: pack)
  l.resolveLocator(loc, $loc, 0, 0)

# --- entry point -------------------------------------------------------------------

proc lintScenario*(sc: Scenario; pack: Pack): Diagnostics =
  var l = Linter(pack: pack, sc: sc, file: sc.file)
  if pack != nil:
    if sc.pack != "" and pack.name != "" and sc.pack != pack.name:
      l.err(1, 1, "L2", "the scenario names pack '" & sc.pack & "' but was linted with pack '" &
        pack.name & "'")
    for call in sc.stage:
      if not pack.stages.hasKey(call.use):
        l.err(call.line, call.col, "L7", "stage '" & call.use & "' is not declared by the pack")
        continue
      let d = pack.stages[call.use]
      if call.args != nil and call.args.kind == yMap:
        for k, _ in call.args.pairs:
          if not d.params.hasKey(k.s):
            l.err(k.line, k.col, "L7", "stage '" & call.use & "' has no parameter '" & k.s & "'")
    l.lintSteps(sc.steps)
    l.lintSequence()
  l.lintAnchors()
  l.diags
