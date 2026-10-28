## The one runner (§6.2): everything that is not medium-specific.
##
## Parsing and linting happen before; then, in order: flow expansion, the
## capability check (before the stage runs), the stage, the closing of the
## stage channel, and the steps — each input action followed by the pack's
## `settled` condition, observations evaluated here, waits polled here or
## delegated by name to the backend, pacing and dwell enacted in realistic runs,
## per-step results and the recording manifest written as the run goes.

import std/[json, os, osproc, times, monotimes, tables, strutils, options, sets, math]
import ./model, ./yaml, ./scenario, ./lint, ./backend, ./eval, ./pacing, ./emit, ./predicates,
  ./grammar

const RunnerVersion* = "0.1.0"

type
  TimingMode* = enum
    tmFast = "fast", tmRealistic = "realistic", tmVirtual = "virtual"

  RecordPolicy* = enum
    rpOff = "off", rpOnFailure = "on-failure", rpAlways = "always"

  RunOutcome* = enum
    roPassed = "passed", roFailed = "failed", roUnsupported = "unsupported", roError = "error"

  StepStatus* = enum
    ssPassed = "passed", ssFailed = "failed", ssNotRun = "not-run"

  RunOptions* = object
    mode*: TimingMode
    seed*: int64
    record*: RecordPolicy
    runDir*: string             ## where the manifest and stills go; "" = nowhere
    timeoutMs*: int             ## default wait timeout
    settleTimeoutMs*: int
    probeReads*: bool           ## read every property twice and compare (§4.4.1, §12)
    scenarioDir*: string        ## base for the stage's relative paths
    runId*: string              ## the run directory's name, recorded in the manifest
    deterministic*: bool
      ## A documentation capture (§9.2): virtual timing, the environment
      ## substitution table, the pinned regions masked, and every capture
      ## taken twice — a region that changed between the takes and is not
      ## pinned fails the run.
    environment*: seq[(string, string)]
      ## Substitutions for the application's environment, passed to the
      ## stage as `$env` (the binding applies them when it starts the
      ## application).
    pinned*: seq[string]        ## locators of the volatile regions a capture masks
    pixelThreshold*: float      ## the SSIM two takes of a pixel capture must reach
    volatileProbeMs*: int       ## the interval between the two takes

  StepResult* = object
    index*: int                 ## 1-based, in execution order
    path*: string               ## where it is in the file: "3", "2.1", "4>2" (inside a flow)
    kind*: string
    beat*: string
    description*: string
    status*: StepStatus
    message*: string
    startMs*, endMs*: float
    virtualStartMs*, virtualEndMs*: float
    resolved*: JsonNode
    observed*: JsonNode
    variant*: string
    artifacts*: seq[string]
    name*: string               ## a capture step's capture name

  Unsupported* = object
    path*: string
    capability*: string

  RunResult* = object
    outcome*: RunOutcome
    message*: string
    scenario*: string
    backend*: string
    mode*: TimingMode
    seed*: int64
    steps*: seq[StepResult]
    unsupported*: seq[Unsupported]
    diagnostics*: Diagnostics
    runDir*: string
    media*: seq[string]
    durationMs*: float
    timingDependent*: bool      ## a dwell or lead-in preceded an observation (L6)

  ExecStep = object
    step: Step
    path: string
    beat: string
    variant: string
    callouts: seq[Callout]   ## the callouts that start with this step (its own, or its
                             ## beat's or flow call's when it is the first inside)

  StepFailure = object of CatchableError

  Run = object
    sc: Scenario
    pack: Pack
    b: Backend
    hello: Hello
    opts: RunOptions
    t0: MonoTime
    platform: Platform
    pointer: tuple[x, y: float, known: bool]
    seedCounter: int64
    res: RunResult
    capSet: HashSet[string]
    startedAt: string
    recordingStartMs: float

proc ms(r: Run): float = float((getMonoTime() - r.t0).inNanoseconds) / 1e6

proc fail(msg: string) {.noreturn.} = raise newException(StepFailure, msg)

proc sleepMs(x: float) =
  if x > 0: sleep(int(x + 0.5))

# --- static resolution and capabilities ------------------------------------------------

proc locatorJson*(loc: Locator): JsonNode =
  var segs = newJArray()
  for s in loc.segments:
    case s.kind
    of segFocused: segs.add %*{"focused": true}
    of segAncestor: segs.add %*{"ancestor": s.role}
    of segRole:
      var keys = newJObject()
      for kv in s.keys: keys[kv.key] = %kv.value
      var o = %*{"role": s.role, "keys": keys}
      if s.ordinal > 0: o["ordinal"] = %s.ordinal
      segs.add o
  %*{"text": $loc, "segments": segs}

proc inputCapability(s: Step): string =
  case s.kind
  of stKey: "input.key"
  of stChord: "input.chord"
  of stType: "input.text"
  of stPress, stRelease: (if s.isButton: "input.pointer.click" else: "input.key")
  of stMove: "input.pointer.move"
  of stHover: "input.hover"
  of stClick: "input.pointer.click"
  of stDrag: "input.pointer.drag"
  of stWheel: "input.wheel"
  else: ""

proc observationNeeds(o: Observation): seq[string] =
  if o.properties.len > 0 or o.asserts.len > 0: result.add "observe.text"
  if o.hasGeometry: result.add "observe.geometry"
  if o.target.at.segments.len > 0 and o.target.at.segments[0].kind == segFocused:
    result.add "observe.focus"
  if o.role != "": result.add "observe.focus"

proc stepNeeds(s: Step): seq[string] =
  let c = s.inputCapability
  if c != "": result.add c
  case s.kind
  of stExpect: result.add observationNeeds(s.observation)
  of stWait:
    if s.untilIsObservation: result.add observationNeeds(s.observation)
  of stCapture: result.add "record.still"
  of stExt: result.add "ext." & s.name.split('.')[0]
  else: discard

proc affordanceFor(s: Step; which: string): string =
  case s.kind
  of stClick:
    if s.button == btnRight: "context-click" elif s.count >= 2: "double-click" else: "click"
  of stPress, stRelease: (if s.button == btnRight: "context-click" else: "click")
  of stDrag: (if which == "to": "drop-target" else: "drag-source")
  of stWheel: "wheel"
  else: ""

proc bindingNeeds(r: Run; s: Step): seq[string] =
  ## What the backend's binding declares per role (§4.9): an affordance for an
  ## input aimed at a role, a property for an observation of it.
  let b = r.hello.bindings
  if b == nil or b.kind != JObject: return
  proc declares(role, list, item: string): bool =
    if not b.hasKey(role): return true          # undeclared role: no claim either way
    for x in b[role]{list}.getElems:
      if x.getStr == item: return true
    false
  var acc: seq[string]
  proc check(t: Target; aff: string; acc: var seq[string]) =
    let role = staticRole(r.pack, t.at)
    if role != "" and aff != "" and not declares(role, "affordances", aff):
      acc.add "binding." & role & ".affordance." & aff
  case s.kind
  of stClick, stWheel: check(s.target, affordanceFor(s, ""), acc)
  of stPress, stRelease:
    if s.isButton: check(s.target, affordanceFor(s, ""), acc)
  of stDrag:
    check(s.dragFrom, "drag-source", acc)
    check(s.dragTo, "drop-target", acc)
  of stExpect, stWait:
    if s.kind == stWait and not s.untilIsObservation: return
    let role = staticRole(r.pack, s.observation.target.at)
    if role != "":
      for p in s.observation.properties.keys:
        if not declares(role, "properties", p):
          acc.add "binding." & role & ".property." & p
  else: discard
  acc

proc expand(r: Run; steps: seq[Step]; prefix, beat: string; depth: int;
            into: var seq[ExecStep]; missing: var seq[Unsupported]) =
  for k, s in steps:
    let path = (if prefix == "": $(k + 1) else: prefix & $(k + 1))
    let first = into.len
    case s.kind
    of stBeat:
      r.expand(s.steps, path & ".", s.name, depth, into, missing)
      if into.len > first: into[first].callouts = s.callouts & into[first].callouts
    of stFlow:
      if depth > 16: raise newException(ValueError, "flows nested too deeply at step " & path)
      var pd: Diagnostics
      let body = expandFlow(r.pack, s.name, s.args, pd, r.sc.file)
      r.expand(body, path & ">", beat, depth + 1, into, missing)
      if into.len > first: into[first].callouts = s.callouts & into[first].callouts
    else:
      var needs = stepNeeds(s)
      var lacking: seq[string]
      for c in needs:
        if c notin r.capSet: lacking.add c
      for c in r.bindingNeeds(s): lacking.add c
      if lacking.len == 0:
        into.add ExecStep(step: s, path: path, beat: beat, callouts: s.callouts)
        continue
      # an alternative may stand in, but only when it is itself admissible
      var used = false
      for gap in lacking:
        if s.alternatives.hasKey(gap):
          var alt: seq[ExecStep]
          var altMissing: seq[Unsupported]
          r.expand(s.alternatives[gap], path & "~", beat, depth, alt, altMissing)
          if altMissing.len == 0 and lacking.len == 1:
            for a in alt.mitems: a.variant = gap
            if alt.len > 0: alt[0].callouts = s.callouts & alt[0].callouts
            into.add alt
            used = true
          break
      if not used:
        for c in lacking: missing.add Unsupported(path: path, capability: c)

# --- talking to the backend -----------------------------------------------------------

proc locateOne(r: var Run; loc: Locator): LocateResult =
  result = r.b.locate(locatorJson(loc))
  case result.outcome
  of loOne: discard
  of loNone:
    fail("'" & $loc & "' resolves to nothing" &
      (if result.candidates.len > 0: "; present: " & result.candidates.join(", ") else: ""))
  of loAmbiguous:
    fail("'" & $loc & "' is ambiguous: " & result.candidates.join(", "))

proc readProps(r: var Run; instance: string; props: seq[string]): JsonNode =
  result = r.b.read(instance, props)
  if r.opts.probeReads:
    let again = r.b.read(instance, props)
    if again != result:
      fail("reading " & props.join(", ") & " changed what was read (" & $result & " then " &
        $again & "): a read has a side effect")
  for p in props:
    if not result.hasKey(p): fail("the backend did not read '" & p & "'")

proc childValues(r: var Run; instance: string; need: Table[string, seq[string]]): ChildValues =
  for role, props in need:
    var vals: seq[JsonNode]
    var k = 1
    while true:
      let seg = %*{"role": role, "keys": {}, "ordinal": k}
      let lr = r.b.locate(%*{"text": "child", "parent": instance, "segments": [seg]})
      if lr.outcome != loOne: break
      vals.add (if props.len == 0: newJObject() else: r.readProps(lr.instance, props))
      inc k
      if k > 10_000: fail("more than 10000 children of role " & role)
    result[role] = vals

# --- observations ----------------------------------------------------------------------

proc tolerance(r: Run): float = (if r.hello.units == "cell": 0.0 else: 2.0)

proc checkObservation(r: var Run; o: Observation; observed: var JsonNode): string =
  ## "" when the observation holds, otherwise why not.
  observed = newJObject()
  let lr = r.b.locate(locatorJson(o.target.at))
  observed["outcome"] = %($lr.outcome)
  if o.absent == 1:
    return (if lr.outcome == loNone: "" else: "'" & $o.target.at & "' is present (expected absent)")
  if o.present == 0:
    return (if lr.outcome == loNone: "" else: "'" & $o.target.at & "' is present (expected absent)")
  if lr.outcome == loNone:
    return "'" & $o.target.at & "' resolves to nothing" &
      (if lr.candidates.len > 0: "; present: " & lr.candidates.join(", ") else: "")
  if lr.outcome == loAmbiguous:
    return "'" & $o.target.at & "' is ambiguous: " & lr.candidates.join(", ")
  observed["role"] = %lr.role
  if o.role != "" and lr.role != o.role:
    return "'" & $o.target.at & "' is a " & lr.role & ", expected a " & o.role
  var props: seq[string]
  for p in o.properties.keys: props.add p
  if o.hasGeometry and "geometry" notin props: props.add "geometry"
  if props.len > 0:
    let vals = r.readProps(lr.instance, props)
    observed["values"] = vals
    for p, m in o.properties:
      if not evalMatcher(m, vals[p]):
        return "'" & $o.target.at & "' " & p & " is " & $vals[p] & ", expected " & describe(m)
    if o.hasGeometry:
      let g = geometryOf(vals["geometry"])
      if o.geometry.visible >= 0 and g.visible != (o.geometry.visible == 1):
        return "'" & $o.target.at & "' is " & (if g.visible: "visible" else: "not visible") &
          ", expected " & (if o.geometry.visible == 1: "visible" else: "not visible")
      for rel in o.geometry.relations:
        let other = r.locateOne(rel.other)
        let og = geometryOf(r.readProps(other.instance, @["geometry"])["geometry"])
        if not evalRelation(rel.rel, g, og, r.tolerance):
          observed["other"] = %*{"locator": $rel.other, "geometry": {"x": og.x, "y": og.y,
                                 "w": og.w, "h": og.h}}
          return "'" & $o.target.at & "' is not " & $rel.rel & " '" & $rel.other & "' (" &
            $g.x & "," & $g.y & " " & $g.w & "x" & $g.h & " vs " & $og.x & "," & $og.y & " " &
            $og.w & "x" & $og.h & ")"
  for inv in o.asserts:
    let role = lr.role
    if not r.pack.roles.hasKey(role) or not r.pack.roles[role].assertions.hasKey(inv.name):
      return "'" & inv.name & "' is not an assertion of " & role
    let decl = r.pack.roles[role].assertions[inv.name]
    var selfNeed: seq[string]
    var childNeed: Table[string, seq[string]]
    var params: Table[string, string]
    for k, prm in decl.sig.params: params[prm] = inv.args[k].text
    propertiesUsed(decl.pred, selfNeed, childNeed, params)
    let selfVals = (if selfNeed.len > 0: r.readProps(lr.instance, selfNeed) else: newJObject())
    let kids = r.childValues(lr.instance, childNeed)
    var kidsJson = newJObject()
    for role2, vals in kids: kidsJson[role2] = %vals
    observed["assert:" & $inv] = %*{"self": selfVals, "children": kidsJson}
    if not evalAssertion(decl, inv.args, selfVals, kids):
      return "'" & $o.target.at & "' does not satisfy " & $inv & " (" & decl.text & ")"
  ""

# --- input ------------------------------------------------------------------------------

proc nextSeed(r: var Run): int64 =
  inc r.seedCounter
  r.opts.seed * 1_000_003 + r.seedCounter

proc presetOf(p: Pace): PacingPreset =
  if p.preset != "": parsePreset(p.preset) else: ppQuick

proc keyDelays(r: var Run; s: Step; n: int): seq[float] =
  if r.opts.mode != tmRealistic and r.opts.mode != tmVirtual: return
  var kp = keystrokePacingFor(presetOf(s.pace))
  if s.pace.kind == paceParams:
    if s.pace.params.hasKey("key-mean"): kp.meanMs = s.pace.params["key-mean"].getFloat
    if s.pace.params.hasKey("key-sigma"): kp.sigma = s.pace.params["key-sigma"].getFloat
    if s.pace.params.hasKey("key-min"): kp.minMs = s.pace.params["key-min"].getFloat
    if s.pace.params.hasKey("key-max"): kp.maxMs = s.pace.params["key-max"].getFloat
  let seed = (if s.pace.params.hasKey("seed"): s.pace.params["seed"].getBiggestInt
              else: r.nextSeed)
  var rng = newPacingRng(seed)
  for _ in 0 ..< n: result.add logNormalDelayMs(rng, kp)

proc centerOf(r: var Run; instance: string): tuple[x, y: float, ok: bool] =
  if "observe.geometry" notin r.capSet: return (0.0, 0.0, false)
  try:
    let g = geometryOf(r.b.read(instance, @["geometry"])["geometry"])
    (g.x + g.w / 2, g.y + g.h / 2, true)
  except CatchableError:
    (0.0, 0.0, false)

proc pointerPath(r: var Run; s: Step; instance: string): JsonNode =
  ## In realistic and virtual runs: the paced pointer path to the target, in the
  ## backend's own units, with the time each point is reached.
  if r.opts.mode == tmFast: return nil
  let c = r.centerOf(instance)
  if not c.ok: return nil
  let src = (if r.pointer.known: point(r.pointer.x, r.pointer.y) else: point(c.x, c.y))
  let dst = point(c.x, c.y)
  r.pointer = (c.x, c.y, true)
  var overshoot = 0.14
  if s.pace.params.hasKey("overshoot"): overshoot = s.pace.params["overshoot"].getFloat
  let dist = sqrt((dst.x - src.x) ^ 2 + (dst.y - src.y) ^ 2)
  let n = max(2, min(40, int(dist / (if r.hello.units == "cell": 1.0 else: 25.0)) + 2))
  let pts = bezierMousePath(src, dst, n, r.nextSeed, overshoot)
  let total = max(120.0, keystrokePacingFor(presetOf(s.pace)).meanMs * 3.0)
  result = newJArray()
  for k, p in pts:
    result.add %*[p.x, p.y, total * float(k) / float(max(1, n - 1))]

proc pathDuration(path: JsonNode): float =
  if path == nil or path.len == 0: 0.0 else: path[^1][2].getFloat

proc resolveChords(r: var Run; s: Step): string =
  var cs = s.chords
  if s.bound != "":
    let bound = r.b.resolveChord(s.bound)
    if bound.isNone: fail("nothing is bound to '" & s.bound & "' (the step never falls back to invoking it)")
    try: cs = parseChordSequence(bound.get)
    except GrammarError as e: fail("the binding resolver returned '" & bound.get & "': " & e.msg)
  for c in cs.mitems: c = resolveMod(c, r.platform)
  $cs

proc sendInput(r: var Run; s: Step; sr: var StepResult): float =
  ## Sends one input action; returns the pacing time it carries (virtual timing).
  var action = emitStep(s)
  for k in ["id", "lead-in", "dwell", "chapter", "narration", "caption", "callout",
            "alternatives", "settle"]:
    if action.hasKey(k): action.delete(k)
  var targets = newJObject()
  var resolved = newJObject()
  var timing = newJObject()
  proc resolveTarget(r: var Run; t: Target; name: string): string =
    let lr = r.locateOne(t.at)
    targets[name] = %lr.instance
    resolved[name] = %*{"locator": $t.at, "role": lr.role}
    lr.instance
  case s.kind
  of stKey, stPress, stRelease:
    if s.kind in {stPress, stRelease} and s.isButton:
      discard r.resolveTarget(s.target, "target")
  of stChord:
    let text = r.resolveChords(s)
    action["chord"] = %text
    resolved["chord"] = %text
  of stType:
    let d = r.keyDelays(s, s.text.len)
    if d.len > 0: timing["keyDelaysMs"] = %d
  of stMove, stHover, stClick, stWheel:
    let id = r.resolveTarget(s.target, "target")
    let p = r.pointerPath(s, id)
    if p != nil: timing["path"] = p
    if s.kind == stClick and s.modifiers != {}:
      let resolvedMods = resolveMod(Chord(modifiers: s.modifiers, key: "a"), r.platform).modifiers
      var mods = newJArray()
      for m in Modifier:
        if m in resolvedMods: mods.add %($m)
      action["click"]["modifiers"] = mods
  of stDrag:
    let fromId = r.resolveTarget(s.dragFrom, "from")
    var via = newJArray()
    for k, t in s.via:
      let lr = r.locateOne(t.at)
      via.add %lr.instance
    targets["via"] = via
    let toId = r.resolveTarget(s.dragTo, "to")
    let p1 = r.pointerPath(s, fromId)
    let p2 = r.pointerPath(s, toId)
    if s.modifiers != {}:
      let resolvedMods = resolveMod(Chord(modifiers: s.modifiers, key: "a"), r.platform).modifiers
      var mods = newJArray()
      for m in Modifier:
        if m in resolvedMods: mods.add %($m)
      action["drag"]["modifiers"] = mods
    if p1 != nil: timing["approach"] = p1
    if p2 != nil: timing["path"] = p2
    discard toId
  else: discard
  action["targets"] = targets
  if timing.len > 0 and r.opts.mode == tmRealistic: action["timing"] = timing
  # added to, not replaced: the callouts noted when the step started stay
  for k, v in resolved: sr.resolved[k] = v
  r.b.send(action)
  var pacing = 0.0
  if timing.hasKey("keyDelaysMs"):
    for d in timing["keyDelaysMs"]: pacing += d.getFloat
  pacing += pathDuration(timing{"path"}) + pathDuration(timing{"approach"})
  if s.kind == stHover and s.hoverFor > 0: pacing += float(s.hoverFor)
  pacing

proc settle(r: var Run; s: Step) =
  if not s.settle: return
  if not r.b.await("settled", "", r.opts.settleTimeoutMs):
    fail("the application did not settle within " & $r.opts.settleTimeoutMs & " ms after the input")

proc waitStep(r: var Run; s: Step; observed: var JsonNode) =
  let timeout = (if s.timeout >= 0: int(s.timeout) else: r.opts.timeoutMs)
  let deadline = r.ms + float(timeout)
  if not s.untilIsObservation:
    let name = s.untilName
    let dot = name.find('.')
    # a role condition with a predicate is evaluated here, by polling
    if dot > 0 and r.pack.roles.hasKey(name[0 ..< dot]):
      let role = name[0 ..< dot]
      let decl = r.pack.roles[role].sync.getOrDefault(name[dot + 1 .. ^1])
      if decl.pred != nil:
        while true:
          let lr = r.b.locate(locatorJson(parseLocator(role)))
          if lr.outcome == loOne:
            var selfNeed: seq[string]
            var childNeed: Table[string, seq[string]]
            propertiesUsed(decl.pred, selfNeed, childNeed)
            let selfVals = (if selfNeed.len > 0: r.readProps(lr.instance, selfNeed) else: newJObject())
            if evalSyncPredicate(decl.pred, selfVals, r.childValues(lr.instance, childNeed)): return
          if r.ms > deadline: fail("'" & name & "' did not hold within " & $timeout & " ms")
          sleep(25)
    if not r.b.await(name, "", timeout):
      fail("'" & name & "' did not happen within " & $timeout & " ms (a wait never passes by timing out)")
    return
  var last = ""
  while true:
    last = r.checkObservation(s.observation, observed)
    if last == "": return
    if r.ms > deadline:
      fail("waited " & $timeout & " ms; the condition never held: " & last)
    sleep(25)

# --- the run ----------------------------------------------------------------------------

proc describeStep(s: Step): string =
  let j = emitStep(s)
  for k in ["id", "lead-in", "dwell", "chapter", "narration", "caption", "callout",
            "alternatives", "settle", "steps"]:
    if j.hasKey(k): j.delete(k)
  $j

proc writeJson(path: string; j: JsonNode) =
  createDir(path.parentDir)
  writeFile(path, j.pretty & "\n")

proc stepJson*(sr: StepResult): JsonNode =
  result = %*{"index": sr.index, "path": sr.path, "kind": sr.kind, "status": $sr.status,
              "description": sr.description, "startMs": sr.startMs, "endMs": sr.endMs,
              "virtualStartMs": sr.virtualStartMs, "virtualEndMs": sr.virtualEndMs}
  if sr.beat != "": result["beat"] = %sr.beat
  if sr.message != "": result["message"] = %sr.message
  if sr.resolved != nil and sr.resolved.len > 0: result["resolved"] = sr.resolved
  if sr.observed != nil and sr.observed.len > 0: result["observed"] = sr.observed
  if sr.variant != "": result["variant"] = %sr.variant
  if sr.artifacts.len > 0: result["artifacts"] = %sr.artifacts
  if sr.name != "": result["name"] = %sr.name

proc manifestJson*(res: RunResult; r: Run): JsonNode =
  var steps = newJArray()
  for s in res.steps: steps.add stepJson(s)
  var uns = newJArray()
  for u in res.unsupported: uns.add %*{"step": u.path, "capability": u.capability}
  var diags = newJArray()
  for d in res.diagnostics: diags.add %($d)
  var env = newJObject()
  for (k, v) in r.opts.environment: env[k] = %v
  %*{"format": "demo-video-script.run.v1", "runner": RunnerVersion,
     "scenario": {"name": res.scenario, "file": r.sc.file}, "pack": r.pack.name,
     "backend": r.hello.toJson, "mode": $res.mode, "seed": res.seed,
     "runId": r.opts.runId, "startedAt": r.startedAt,
     "deterministic": r.opts.deterministic, "environment": env, "pinned": r.opts.pinned,
     "recordingStartMs": r.recordingStartMs,
     "outcome": $res.outcome, "message": res.message, "durationMs": res.durationMs,
     "timingDependent": res.timingDependent,
     "steps": steps, "unsupported": uns, "diagnostics": diags, "media": res.media}

# --- documentation captures (§9.2) --------------------------------------------------------

proc pinnedInstances(r: var Run): JsonNode =
  ## The instances of the declared volatile regions that are on screen now.
  result = newJArray()
  for text in r.opts.pinned:
    let res = r.b.locate(locatorJson(parseLocator(text)))
    case res.outcome
    of loOne: result.add %res.instance
    of loNone: discard
    of loAmbiguous: fail("the pinned region '" & text & "' is ambiguous: " &
                         res.candidates.join(", "))

proc ssim(a, b: string): float =
  ## The structural similarity of two images, by ffmpeg's `ssim` filter.
  let ff = getEnv("FFMPEG_BIN", "ffmpeg")
  let (o, code) = execCmdEx(quoteShellCommand([ff, "-hide_banner", "-nostats", "-i", a, "-i", b,
                                               "-lavfi", "ssim", "-f", "null", "-"]))
  if code != 0: fail("comparing two takes with ffmpeg failed: " & o.strip)
  let i = o.rfind("All:")
  if i < 0: fail("ffmpeg reported no SSIM: " & o.strip)
  parseFloat(o[i + 4 .. ^1].strip.split(' ')[0])

proc changedRows(a, b: string): seq[int] =
  let la = a.splitLines
  let lb = b.splitLines
  for k in 0 ..< max(la.len, lb.len):
    if (if k < la.len: la[k] else: "") != (if k < lb.len: lb[k] else: ""): result.add k + 1

proc checkStable(r: var Run; args: JsonNode; files: seq[string]) =
  ## A deterministic capture is taken a second time, `volatileProbeMs` later;
  ## anything that changed in between is a volatile region the run did not
  ## declare, and fails the run rather than publishing an unstable capture.
  sleepMs(float(r.opts.volatileProbeMs))
  var again = args.copy
  again["path"] = %(args["path"].getStr & ".take2")
  again["mask"] = r.pinnedInstances()
  let res = r.b.record(recStill, again)
  var second: seq[string]
  for f in res{"files"}.getElems: second.add f.getStr
  defer:
    for f in second: removeFile(f)
  if second.len != files.len: fail("the second take of the capture produced other files")
  for k, f in files:
    let g = second[k]
    if f.endsWith(".png"):
      let v = ssim(f, g)
      if v < r.opts.pixelThreshold:
        fail("an undeclared volatile region: " & f.lastPathPart & " changed between two takes " &
          $r.opts.volatileProbeMs & " ms apart (SSIM " & formatFloat(v, ffDecimal, 4) &
          " below " & $r.opts.pixelThreshold & "); declare it with --pin")
    elif readFile(f) != readFile(g):
      let rows = changedRows(readFile(f), readFile(g))
      fail("an undeclared volatile region: " & f.lastPathPart & " changed between two takes " &
        $r.opts.volatileProbeMs & " ms apart" &
        (if rows.len > 0 and rows.len < 20: " (lines " & rows.join(", ") & ")" else: "") &
        "; declare it with --pin")

proc runScenario*(sc: Scenario; pack: Pack; b: Backend; options: RunOptions): RunResult =
  var r = Run(sc: sc, pack: pack, b: b, opts: options, t0: getMonoTime(),
              startedAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"))
  if r.opts.deterministic: r.opts.mode = tmVirtual
  if r.opts.pixelThreshold <= 0: r.opts.pixelThreshold = 0.995
  if r.opts.volatileProbeMs <= 0: r.opts.volatileProbeMs = 1200
  if r.opts.timeoutMs <= 0: r.opts.timeoutMs = 5000
  if r.opts.settleTimeoutMs <= 0: r.opts.settleTimeoutMs = 5000
  let opts = r.opts
  r.res = RunResult(scenario: sc.name, mode: r.opts.mode, seed: opts.seed, runDir: opts.runDir)
  template finish(oc: RunOutcome; msg: string) =
    r.res.outcome = oc
    r.res.message = msg
    r.res.durationMs = r.ms
    if opts.runDir != "" and (opts.record == rpAlways or
        (opts.record == rpOnFailure and oc in {roFailed, roError})):
      writeJson(opts.runDir / "manifest.json", manifestJson(r.res, r))
    elif opts.runDir != "" and dirExists(opts.runDir) and opts.record == rpOnFailure:
      removeDir(opts.runDir)
    return r.res
  # lint first: a scenario with lint errors does not run
  let diags = lintScenario(sc, pack)
  r.res.diagnostics = diags
  if diags.hasErrors:
    try: r.hello = b.hello() except CatchableError: discard
    finish(roError, "the scenario has lint errors")
  try:
    r.hello = b.hello()
  except BackendError as e:
    finish(roError, "backend: " & e.msg)
  r.res.backend = r.hello.backend
  r.platform = (case r.hello.platform
    of "macos": platMacos
    of "windows": platWindows
    else: platLinux)
  for c in r.hello.capabilities: r.capSet.incl c
  r.capSet.incl "ext." & r.hello.backend
  # flows expanded; capabilities checked before anything runs (§4.9)
  var plan: seq[ExecStep]
  var missing: seq[Unsupported]
  try:
    r.expand(sc.steps, "", "", 0, plan, missing)
  except ValueError as e:
    finish(roError, e.msg)
  # a documentation capture with declared volatile regions needs a backend
  # that masks them (§9.2); without it the captures would not be stable
  if opts.deterministic and opts.pinned.len > 0 and "record.mask" notin r.capSet:
    missing.add Unsupported(path: "--pin", capability: "record.mask")
  if missing.len > 0:
    r.res.unsupported = missing
    var parts: seq[string]
    for u in missing: parts.add "step " & u.path & " needs " & u.capability
    finish(roUnsupported, "not applicable on backend '" & r.hello.backend & "': " & parts.join("; "))
  # the stage, then the stage channel closes
  try:
    for call in sc.stage:
      var args = (if call.args == nil: newJObject() else: call.args.toJson)
      args["$base"] = %opts.scenarioDir
      if opts.environment.len > 0:
        var env = newJObject()
        for (k, v) in opts.environment: env[k] = %v
        args["$env"] = env
      b.stage(call.use, args)
    b.endStage()
  except BackendError as e:
    finish(roError, "stage: " & e.msg)
  let recording = opts.record != rpOff and opts.runDir != ""
  if recording:
    createDir(opts.runDir / "steps")
    try:
      r.recordingStartMs = r.ms
      var start = %*{"dir": opts.runDir, "deterministic": opts.deterministic}
      if opts.deterministic:
        try: start["mask"] = r.pinnedInstances()
        except StepFailure: discard
      discard b.record(recStart, start)
    except BackendError as e:
      finish(roError, "record: " & e.msg)
  var vcursor = 0.0
  var failedAt = -1
  for k, es in plan:
    let s = es.step
    var sr = StepResult(index: k + 1, path: es.path, kind: $s.kind, beat: es.beat,
                        description: describeStep(s), variant: es.variant,
                        resolved: newJObject(), observed: newJObject())
    if failedAt >= 0:
      sr.status = ssNotRun
      r.res.steps.add sr
      continue
    if s.leadIn > 0:
      if opts.mode == tmRealistic: sleepMs(float(s.leadIn))
      vcursor += float(s.leadIn)
    sr.startMs = r.ms
    sr.virtualStartMs = vcursor
    if recording:
      var mark = %*{"step": k + 1, "path": es.path, "kind": $s.kind, "virtualMs": vcursor}
      if opts.deterministic:
        try: mark["mask"] = r.pinnedInstances()
        except StepFailure: discard
      try: discard b.record(recMark, mark)
      except BackendError: discard
      # where each callout starting here points, for composition: a callout is
      # presentation, so one that does not resolve is recorded, not failed
      if es.callouts.len > 0:
        var cs = newJArray()
        for c in es.callouts:
          var o = %*{"locator": $c.target.at, "text": c.text}
          try:
            let lr = b.locate(locatorJson(c.target.at))
            o["outcome"] = %($lr.outcome)
            if lr.outcome == loOne:
              o["geometry"] = b.read(lr.instance, @["geometry"]){"geometry"}
          except BackendError as e:
            o["outcome"] = %"error"
            o["message"] = %e.msg
          cs.add o
        sr.resolved["callouts"] = cs
    var pacing = 0.0
    try:
      case s.kind
      of InputKinds:
        pacing = r.sendInput(s, sr)
        r.settle(s)
      of stExpect:
        var observed: JsonNode
        let why = r.checkObservation(s.observation, observed)
        sr.observed = observed
        if why != "": fail(why)
      of stWait:
        var observed = newJObject()
        r.waitStep(s, observed)
        sr.observed = observed
      of stCapture:
        sr.name = s.name
        var args = %*{"name": s.name, "path": "steps" / ($(k + 1) & "-" & s.name)}
        if s.hasCaptureOf:
          let lr = r.locateOne(s.captureOf.at)
          args["instance"] = %lr.instance
        if opts.deterministic:
          args["mask"] = r.pinnedInstances()
        if recording or opts.runDir != "":
          createDir(opts.runDir / "steps")
          args["dir"] = %opts.runDir
          let res = b.record(recStill, args)
          for f in res{"files"}.getElems: sr.artifacts.add f.getStr
          if opts.deterministic: r.checkStable(args, sr.artifacts)
      of stExt:
        b.send(%*{"ext": s.name, "with": (if s.args == nil: newJObject() else: s.args.toJson)})
      else: discard
      sr.status = ssPassed
    except StepFailure as e:
      sr.status = ssFailed
      sr.message = e.msg
    except EvalError as e:
      sr.status = ssFailed
      sr.message = e.msg
    except BackendError as e:
      sr.status = ssFailed
      sr.message = "backend (" & $e.kind & "): " & e.msg
      if e.kind in {beCrashed, beProtocol, beInternal}:
        sr.endMs = r.ms
        r.res.steps.add sr
        failedAt = k
        r.res.outcome = roError
        continue
    sr.endMs = r.ms
    if s.dwell > 0 and opts.mode == tmRealistic: sleepMs(float(s.dwell))
    # a deterministic run's timeline is the scenario's alone: what the
    # machine took to run a step is not part of it
    let took = (if opts.deterministic: 0.0 else: sr.endMs - sr.startMs)
    vcursor += took + pacing + max(0.0, float(s.dwell))
    sr.virtualEndMs = vcursor
    if recording:
      let base = "steps" / $(k + 1)
      writeJson(opts.runDir / (base & "-state.json"), %*{"step": stepJson(sr)})
      # a capture step's still is its capture
      if "record.still" in r.capSet and s.kind != stCapture:
        try:
          let res = b.record(recStill, %*{"dir": opts.runDir, "path": base & "-" & $s.kind,
                                            "name": $s.kind})
          for f in res{"files"}.getElems: sr.artifacts.add f.getStr
        except BackendError: discard
    if sr.status == ssFailed and failedAt < 0:
      failedAt = k
      if recording or opts.record == rpOnFailure and opts.runDir != "":
        createDir(opts.runDir / "failure")
        writeJson(opts.runDir / "failure" / "observation.json",
          %*{"step": stepJson(sr)})
        writeFile(opts.runDir / "failure" / "backend.log",
          (if b.log == nil: "(an in-process backend: its messages are in the run's output)\n"
           else: b.log()))
        if "record.still" in r.capSet:
          try: discard b.record(recStill, %*{"dir": opts.runDir, "path": "failure/surface",
                                             "name": "surface"})
          except BackendError: discard
    r.res.steps.add sr
  # an observation that only holds because of a dwell or lead-in (§6.3, L6)
  for d in diags:
    if d.rule == "L6": r.res.timingDependent = true
  if recording:
    try:
      let res = b.record(recStop, %*{"dir": opts.runDir})
      for f in res{"files"}.getElems: r.res.media.add f.getStr
    except BackendError: discard
  if r.res.outcome == roError:
    finish(roError, r.res.steps[^1].message)
  if failedAt >= 0:
    let f = r.res.steps[failedAt]
    finish(roFailed, "step " & f.path & " (" & f.kind & ") failed: " & f.message)
  finish(roPassed, "")
