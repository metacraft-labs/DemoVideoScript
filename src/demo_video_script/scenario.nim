## Reading a scenario file into the typed model.
##
## The checks here that produce `phStructural` diagnostics are exactly the
## published `scenario.schema.json`: a file is schema-valid if and only if this
## parser reports no structural error. Messages are written for a person; the
## rule ids are "yaml" (not YAML this reader accepts), "version" (a format
## version this parser does not implement), "schema" and "L1" (a step that is not
## an input action, observation, wait, flow call, beat, capture or extension
## step — §11's L1, enforced here because the schema enforces it too).

import std/[json, math, strutils, tables, sets]
import ./model, ./yaml

const
  ImplementedVersion* = 1
  ActionKeys* = ["key", "chord", "type", "press", "release", "move", "hover", "click",
                 "drag", "wheel", "expect", "wait", "flow", "beat", "capture", "ext"]
  AnnotationKeys* = ["id", "lead-in", "dwell", "chapter", "narration", "caption", "callout",
                     "alternatives"]
  ReservedObservationKeys* = ["at", "assert", "geometry", "role", "absent", "present"]
  PacePresets* = ["texting", "quick", "thoughtful", "careful"]
  PaceParams* = ["preset", "key-mean", "key-sigma", "key-min", "key-max", "curvature",
                 "overshoot", "commit-pause", "seed"]
  Capabilities* = ["input.key", "input.chord", "input.text", "input.pointer.move",
                   "input.pointer.click", "input.pointer.drag", "input.wheel", "input.hover",
                   "observe.text", "observe.geometry", "observe.style", "observe.image",
                   "observe.focus", "sync.event", "sync.visual-settle",
                   "record.cast", "record.video", "record.still"]

type
  Ctx* = object
    file*: string
    diags*: Diagnostics

proc report*(c: var Ctx; n: YNode; rule, msg: string; sev = sevError; phase = phStructural) =
  let (l, col) = (if n == nil: (0, 0) else: (n.line, n.col))
  c.diags.add Diagnostic(rule: rule, severity: sev, phase: phase, file: c.file,
                         line: l, col: col, message: msg)

proc structural*(c: var Ctx; n: YNode; msg: string) = c.report(n, "schema", msg)

# --- scalar helpers ------------------------------------------------------------

proc isNumber*(n: YNode): bool = n != nil and n.kind in {yInt, yFloat}

proc isIntegral*(n: YNode): bool =
  ## JSON Schema's "integer": a number with no fractional part (2.0 included).
  n != nil and (n.kind == yInt or (n.kind == yFloat and n.f.classify notin
    {fcNan, fcInf, fcNegInf} and n.f == floor(n.f)))

proc intValue*(n: YNode): int =
  if n.kind == yInt: int(n.i) else: int(n.f)

proc numValue*(n: YNode): float =
  if n.kind == yInt: float(n.i) else: n.f

proc expectMap*(c: var Ctx; n: YNode; what: string): bool =
  if n == nil or n.kind != yMap:
    c.structural(n, what & " must be a mapping, found " & n.kindName)
    return false
  true

proc expectString*(c: var Ctx; n: YNode; what: string): bool =
  if n == nil or n.kind != yString:
    c.structural(n, what & " must be a string, found " & n.kindName)
    return false
  true

proc expectBool*(c: var Ctx; n: YNode; what: string): int =
  if n == nil or n.kind != yBool:
    c.structural(n, what & " must be true or false, found " & n.kindName)
    return -1
  ord(n.b)

proc checkKeys*(c: var Ctx; n: YNode; allowed: openArray[string]; what: string;
               rule = "schema"): bool =
  result = true
  for k, _ in n.pairs:
    if k.s notin allowed:
      c.report(k, rule, "unknown key '" & k.s & "' in " & what & " (allowed: " &
        allowed.join(", ") & ")")
      result = false

proc parseName*(c: var Ctx; n: YNode; what: string): string =
  if not c.expectString(n, what): return ""
  if not n.s.isName:
    c.structural(n, what & " '" & n.s & "' is not a name ([a-z][a-z0-9-]*)")
    return ""
  n.s

proc parseDuration*(c: var Ctx; n: YNode; what: string): Millis =
  if n.isNumber:
    let v = n.numValue
    if v.classify in {fcNan, fcInf, fcNegInf} or v < 0:
      c.structural(n, what & " must be a non-negative duration")
      return -1
    return Millis(v * 1000.0 + 0.5)
  if n != nil and n.kind == yString:
    try: return parseDurationText(n.s)
    except GrammarError as e:
      c.structural(n, what & ": " & e.msg & " (for example 500ms, 1.5s, 2m)")
      return -1
  c.structural(n, what & " must be a duration (500ms, 1.5s, 2m, or seconds), found " &
    n.kindName)
  -1

proc parseLocatorNode*(c: var Ctx; n: YNode; what: string; ok: var bool): Locator =
  if not c.expectString(n, what):
    ok = false
    return
  try:
    result = parseLocator(n.s)
  except GrammarError as e:
    c.structural(n, what & ": " & e.msg)
    ok = false

proc parseAnchor(c: var Ctx; n: YNode; ok: var bool): Invocation =
  if not c.expectString(n, "anchor"):
    ok = false
    return
  try: result = parseInvocation(n.s)
  except GrammarError as e:
    c.structural(n, "anchor: " & e.msg)
    ok = false

proc parseTargetMap(c: var Ctx; n: YNode; extra: openArray[string]; what: string;
                    ok: var bool): Target =
  ## A mapping with `at`, optional `anchor`, and the `extra` keys.
  var allowed = @["at", "anchor"]
  for e in extra: allowed.add e
  if not c.checkKeys(n, allowed, what): ok = false
  let at = n.get("at")
  result.line = n.line
  result.col = n.col
  if at == nil:
    c.structural(n, what & " needs 'at' (a locator)")
    ok = false
  else:
    result.at = c.parseLocatorNode(at, what & " 'at'", ok)
    result.atText = (if at.kind == yString: at.s else: "")
    result.line = at.line
    result.col = at.col
  let an = n.get("anchor")
  if an != nil: result.anchor = c.parseAnchor(an, ok)

proc parseTarget(c: var Ctx; n: YNode; what: string; ok: var bool): Target =
  ## A locator string, or { at, anchor }.
  if n != nil and n.kind == yString:
    result.at = c.parseLocatorNode(n, what, ok)
    result.atText = n.s
    result.line = n.line
    result.col = n.col
  elif n != nil and n.kind == yMap:
    result = c.parseTargetMap(n, [], what, ok)
  else:
    c.structural(n, what & " must be a locator or { at, anchor }, found " & n.kindName)
    ok = false

proc parsePace(c: var Ctx; n: YNode; ok: var bool): Pace =
  if n.kind == yString:
    if n.s notin PacePresets:
      c.structural(n, "unknown pace '" & n.s & "' (" & PacePresets.join(", ") & ")")
      ok = false
    return Pace(kind: pacePreset, preset: n.s)
  if n.kind != yMap or n.keys.len == 0:
    c.structural(n, "pace must be a preset name or a mapping of pacing parameters")
    ok = false
    return
  result.kind = paceParams
  if not c.checkKeys(n, PaceParams, "pace"): ok = false
  for k, v in n.pairs:
    case k.s
    of "preset":
      if v.kind != yString or v.s notin PacePresets:
        c.structural(v, "pace preset must be one of " & PacePresets.join(", "))
        ok = false
      else: result.preset = v.s
    of "key-mean", "key-min", "key-max", "commit-pause":
      let ms = c.parseDuration(v, "pace " & k.s)
      if ms < 0: ok = false
      result.params[k.s] = %ms
    of "key-sigma", "curvature", "overshoot":
      if not v.isNumber or v.numValue < 0:
        c.structural(v, "pace " & k.s & " must be a non-negative number")
        ok = false
      else: result.params[k.s] = %v.numValue
    of "seed":
      if not v.isIntegral:
        c.structural(v, "pace seed must be an integer")
        ok = false
      else: result.params[k.s] = %v.intValue
    else: discard

proc parseButton(c: var Ctx; n: YNode; ok: var bool): Button =
  if n.kind == yString:
    case n.s
    of "left": return btnLeft
    of "right": return btnRight
    of "middle": return btnMiddle
    else: discard
  c.structural(n, "button must be left, right or middle")
  ok = false

proc parseModifiers(c: var Ctx; n: YNode; ok: var bool): set[Modifier] =
  if n.kind != ySeq:
    c.structural(n, "modifiers must be a list (Ctrl, Shift, Alt, Meta, Mod)")
    ok = false
    return
  var seen: HashSet[string]
  for it in n.items:
    if it.kind != yString or it.s notin ["Ctrl", "Shift", "Alt", "Meta", "Mod"]:
      c.structural(it, "modifier must be one of Ctrl, Shift, Alt, Meta, Mod")
      ok = false
      continue
    if it.s in seen:
      c.structural(it, "modifier '" & it.s & "' listed twice")
      ok = false
    seen.incl it.s
    result.incl parseEnum[Modifier](it.s)

# --- matchers and observations -------------------------------------------------------

proc parseMatcher*(c: var Ctx; n: YNode; ok: var bool): Matcher =
  case n.kind
  of yNull, yBool, yInt, yFloat, yString, ySeq:
    return Matcher(kind: mEquals, value: n.toJson)
  of yMap:
    if n.keys.len != 1:
      c.structural(n, "a matcher mapping has exactly one of equals, contains, matches, " &
        "one-of, lt, le, gt, ge, count, subsequence, unordered")
      ok = false
      return Matcher(kind: mEquals, value: n.toJson)
    let k = n.keys[0]
    let v = n.values[0]
    var kind: MatcherKind
    try: kind = parseEnum[MatcherKind](k.s)
    except ValueError:
      c.structural(k, "unknown matcher '" & k.s & "'")
      ok = false
      return Matcher(kind: mEquals, value: n.toJson)
    result = Matcher(kind: kind, value: v.toJson)
    case kind
    of mMatches:
      if v.kind != yString:
        c.structural(v, "matches takes a regular expression string")
        ok = false
    of mOneOf:
      if v.kind != ySeq or v.items.len == 0:
        c.structural(v, "one-of takes a non-empty list")
        ok = false
    of mLt, mLe, mGt, mGe:
      if not v.isNumber:
        c.structural(v, k.s & " takes a number")
        ok = false
    of mCount:
      result.inner = c.parseMatcher(v, ok)
    of mSubsequence, mUnordered:
      if v.kind != ySeq:
        c.structural(v, k.s & " takes a list")
        ok = false
    of mEquals, mContains: discard

proc parseGeometry(c: var Ctx; n: YNode; ok: var bool): GeometryCheck =
  result.visible = -1
  if n.kind != yMap or n.keys.len == 0:
    c.structural(n, "geometry must be a non-empty mapping of relations")
    ok = false
    return
  for k, v in n.pairs:
    if k.s == "visible":
      let b = c.expectBool(v, "geometry visible")
      if b < 0: ok = false
      result.visible = b
      continue
    var rel: Relation
    try: rel = parseEnum[Relation](k.s)
    except ValueError:
      c.structural(k, "unknown geometry relation '" & k.s & "'")
      ok = false
      continue
    let loc = c.parseLocatorNode(v, "geometry " & k.s, ok)
    result.relations.add (rel, loc, (if v.kind == yString: v.s else: ""))

proc parseObservation*(c: var Ctx; n: YNode; what: string; ok: var bool): Observation =
  result.absent = -1
  result.present = -1
  if not c.expectMap(n, what):
    ok = false
    return
  let at = n.get("at")
  if at == nil:
    c.structural(n, what & " needs 'at' (a locator)")
    ok = false
  else:
    result.target.at = c.parseLocatorNode(at, what & " 'at'", ok)
    result.target.atText = (if at.kind == yString: at.s else: "")
    result.target.line = at.line
    result.target.col = at.col
  for k, v in n.pairs:
    case k.s
    of "at": discard
    of "assert":
      var items: seq[YNode]
      if v.kind == ySeq:
        if v.items.len == 0:
          c.structural(v, "assert takes an invocation or a non-empty list of them")
          ok = false
        items = v.items
      else: items = @[v]
      for it in items:
        if not c.expectString(it, "assert"):
          ok = false
          continue
        try: result.asserts.add parseInvocation(it.s)
        except GrammarError as e:
          c.structural(it, "assert: " & e.msg)
          ok = false
    of "geometry":
      result.hasGeometry = true
      result.geometry = c.parseGeometry(v, ok)
    of "role": result.role = c.parseName(v, "role")
    of "absent":
      result.absent = c.expectBool(v, "absent")
      if result.absent < 0: ok = false
    of "present":
      result.present = c.expectBool(v, "present")
      if result.present < 0: ok = false
    else:
      if not k.s.isName:
        c.structural(k, "'" & k.s & "' is not a property name ([a-z][a-z0-9-]*)")
        ok = false
        continue
      result.properties[k.s] = c.parseMatcher(v, ok)

# --- spans, callouts, annotations ------------------------------------------------------

proc parseSpan(c: var Ctx; n: YNode; what: string; ok: var bool): Span =
  result.line = n.line
  result.col = n.col
  if not c.expectMap(n, what):
    ok = false
    return
  if not c.checkKeys(n, ["text", "from", "to", "voice", "style"], what): ok = false
  let t = n.get("text")
  if t == nil:
    c.structural(n, what & " needs 'text'")
    ok = false
  elif c.expectString(t, what & " text"): result.text = t.s
  else: ok = false
  for k, v in n.pairs:
    case k.s
    of "from": result.fromId = c.parseName(v, what & " from")
    of "to": result.toId = c.parseName(v, what & " to")
    of "voice", "style":
      if not c.expectString(v, what & " " & k.s): ok = false
      elif k.s == "voice": result.voice = v.s
      else: result.style = v.s
    else: discard
    if k.s in ["from", "to"] and not (v.kind == yString and v.s.isName): ok = false

proc parseCallout(c: var Ctx; n: YNode; ok: var bool): Callout =
  result.line = n.line
  result.col = n.col
  if not c.expectMap(n, "callout"):
    ok = false
    return
  if not c.checkKeys(n, ["at", "anchor", "text", "from", "to"], "callout"): ok = false
  if n.get("at") == nil:
    c.structural(n, "callout needs 'at' (a locator)")
    ok = false
  else:
    let at = n.get("at")
    result.target.at = c.parseLocatorNode(at, "callout 'at'", ok)
    result.target.atText = (if at.kind == yString: at.s else: "")
    result.target.line = at.line
    result.target.col = at.col
  if n.get("anchor") != nil: result.target.anchor = c.parseAnchor(n.get("anchor"), ok)
  let t = n.get("text")
  if t == nil:
    c.structural(n, "callout needs 'text'")
    ok = false
  elif c.expectString(t, "callout text"): result.text = t.s
  else: ok = false
  if n.get("from") != nil:
    result.fromId = c.parseName(n.get("from"), "callout from")
    if result.fromId == "": ok = false
  if n.get("to") != nil:
    result.toId = c.parseName(n.get("to"), "callout to")
    if result.toId == "": ok = false

proc parseSteps*(c: var Ctx; n: YNode; what: string): seq[Step]

proc parseAnnotations(c: var Ctx; n: YNode; s: Step; ok: var bool) =
  for k, v in n.pairs:
    case k.s
    of "id":
      s.id = c.parseName(v, "id")
      if s.id == "": ok = false
    of "lead-in":
      s.leadIn = c.parseDuration(v, "lead-in")
      if s.leadIn < 0: ok = false
    of "dwell":
      s.dwell = c.parseDuration(v, "dwell")
      if s.dwell < 0: ok = false
    of "chapter":
      if c.expectString(v, "chapter"): s.chapter = v.s
      else: ok = false
    of "narration":
      s.narration = c.parseSpan(v, "narration", ok)
      s.hasNarration = true
    of "caption":
      s.caption = c.parseSpan(v, "caption", ok)
      s.hasCaption = true
    of "callout":
      if v.kind == ySeq:
        for it in v.items: s.callouts.add c.parseCallout(it, ok)
      else: s.callouts.add c.parseCallout(v, ok)
    of "alternatives":
      if v.kind != yMap or v.keys.len == 0:
        c.structural(v, "alternatives must be a non-empty mapping from a capability to steps")
        ok = false
        continue
      for ck, cv in v.pairs:
        if ck.s notin Capabilities:
          c.structural(ck, "'" & ck.s & "' is not a capability (" & Capabilities.join(", ") & ")")
          ok = false
          continue
        let before = c.diags.len
        s.alternatives[ck.s] = c.parseSteps(cv, "alternatives " & ck.s)
        if c.diags.len > before and c.diags.hasStructuralErrors: ok = false
    else: discard

# --- steps ---------------------------------------------------------------------------

proc newStep(kind: StepKind; n: YNode): Step =
  Step(kind: kind, line: n.line, col: n.col, leadIn: -1, dwell: -1, settle: true,
       hoverFor: -1, timeout: -1, count: 1, amount: 1)

proc parsePressRelease(c: var Ctx; s: Step; v: YNode; ok: var bool) =
  if v.kind == yString:
    try: s.key = parseKey(v.s)
    except GrammarError as e:
      c.structural(v, $s.kind & ": " & e.msg)
      ok = false
  elif v.kind == yMap and v.get("key") != nil and v.get("at") == nil:
    if not c.checkKeys(v, ["key"], $s.kind): ok = false
    let kn = v.get("key")
    if c.expectString(kn, "key"):
      try: s.key = parseKey(kn.s)
      except GrammarError as e:
        c.structural(kn, $s.kind & ": " & e.msg)
        ok = false
    else: ok = false
  elif v.kind == yMap:
    s.isButton = true
    s.target = c.parseTargetMap(v, ["button"], $s.kind, ok)
    if v.get("button") != nil: s.button = c.parseButton(v.get("button"), ok)
  else:
    c.structural(v, $s.kind & " takes a key name, { key }, or { at, anchor, button }")
    ok = false

proc parseStep*(c: var Ctx; n: YNode): Step =
  ## One step. Returns nil when the step has no single action.
  if n == nil or n.kind != yMap:
    c.report(n, "L1", "a step must be a mapping with one action, found " & n.kindName)
    return nil
  var actions: seq[YNode]
  var unknown = false
  for k, _ in n.pairs:
    if k.s in ActionKeys: actions.add k
    elif k.s in AnnotationKeys or k.s in ["settle", "steps", "with"]: discard
    elif k.s == "use" or k.s == "stage":
      c.report(k, "L1", "a stage procedure cannot be called from steps; after the stage, " &
        "steps are only input, observations and waits (§4.7)")
      unknown = true
    else:
      c.report(k, "L1", "unknown step key '" & k.s & "' (actions: " & ActionKeys.join(", ") &
        "; annotations: " & AnnotationKeys.join(", ") & ")")
      unknown = true
  if actions.len == 0:
    if not unknown:
      c.report(n, "L1", "a step needs exactly one action (" & ActionKeys.join(", ") & ")")
    return nil
  if actions.len > 1:
    c.report(actions[1], "L1", "a step has exactly one action; found '" & actions[0].s &
      "' and '" & actions[1].s & "'")
    return nil
  let ak = actions[0]
  let kind = parseEnum[StepKind](ak.s)
  let s = newStep(kind, n)
  let v = n.get(ak.s)
  var ok = not unknown
  # keys allowed besides annotations
  if n.get("settle") != nil:
    if kind notin InputKinds:
      c.report(n.keyNode("settle"), "L1", "settle applies only to input actions")
      ok = false
    else:
      let b = c.expectBool(n.get("settle"), "settle")
      if b < 0: ok = false
      s.settle = b != 0
  if n.get("steps") != nil and kind != stBeat:
    c.report(n.keyNode("steps"), "L1", "'steps' belongs to a beat")
    ok = false
  if n.get("with") != nil and kind notin {stFlow, stExt}:
    c.report(n.keyNode("with"), "L1", "'with' belongs to a flow call or an extension step")
    ok = false
  c.parseAnnotations(n, s, ok)
  case kind
  of stKey:
    if c.expectString(v, "key"):
      try: s.key = parseKey(v.s)
      except GrammarError as e:
        c.structural(v, "key: " & e.msg)
        ok = false
    else: ok = false
  of stChord:
    if v.kind == yString:
      try: s.chords = parseChordSequence(v.s)
      except GrammarError as e:
        c.structural(v, "chord: " & e.msg)
        ok = false
    elif v.kind == yMap:
      if not c.checkKeys(v, ["bound"], "chord"): ok = false
      let b = v.get("bound")
      if b == nil:
        c.structural(v, "chord takes a chord sequence or { bound: <operation> }")
        ok = false
      elif not (b.kind == yString and b.s.isDottedName):
        c.structural(b, "bound names an operation (dotted names, e.g. notes.archive-selected)")
        ok = false
      else: s.bound = b.s
    else:
      c.structural(v, "chord takes a chord sequence or { bound: <operation> }")
      ok = false
  of stType:
    if v.kind == yString: s.text = v.s
    elif v.kind == yMap:
      if not c.checkKeys(v, ["text", "pace"], "type"): ok = false
      let t = v.get("text")
      if t == nil:
        c.structural(v, "type needs 'text'")
        ok = false
      elif c.expectString(t, "type text"): s.text = t.s
      else: ok = false
      if v.get("pace") != nil: s.pace = c.parsePace(v.get("pace"), ok)
    else:
      c.structural(v, "type takes text or { text, pace }")
      ok = false
  of stPress, stRelease:
    c.parsePressRelease(s, v, ok)
  of stMove, stHover, stClick:
    if v.kind == yString:
      s.target = c.parseTarget(v, $kind, ok)
    elif v.kind == yMap:
      let extra = case kind
        of stMove: @["pace"]
        of stHover: @["for", "pace"]
        else: @["button", "count", "modifiers", "pace"]
      s.target = c.parseTargetMap(v, extra, $kind, ok)
      for k2, v2 in v.pairs:
        case k2.s
        of "pace": s.pace = c.parsePace(v2, ok)
        of "for":
          s.hoverFor = c.parseDuration(v2, "hover for")
          if s.hoverFor < 0: ok = false
        of "button": s.button = c.parseButton(v2, ok)
        of "count":
          if not v2.isIntegral or v2.intValue notin 1..3:
            c.structural(v2, "count is 1, 2 or 3")
            ok = false
          else: s.count = v2.intValue
        of "modifiers": s.modifiers = c.parseModifiers(v2, ok)
        else: discard
    else:
      c.structural(v, $kind & " takes a locator or { at, anchor, … }")
      ok = false
  of stDrag:
    if c.expectMap(v, "drag"):
      if not c.checkKeys(v, ["from", "to", "via", "button", "modifiers", "pace"], "drag"):
        ok = false
      if v.get("from") == nil or v.get("to") == nil:
        c.structural(v, "drag needs 'from' and 'to'")
        ok = false
      for k2, v2 in v.pairs:
        case k2.s
        of "from": s.dragFrom = c.parseTarget(v2, "drag from", ok)
        of "to": s.dragTo = c.parseTarget(v2, "drag to", ok)
        of "via":
          if v2.kind != ySeq:
            c.structural(v2, "via is a list of targets")
            ok = false
          else:
            for it in v2.items: s.via.add c.parseTarget(it, "drag via", ok)
        of "button": s.button = c.parseButton(v2, ok)
        of "modifiers": s.modifiers = c.parseModifiers(v2, ok)
        of "pace": s.pace = c.parsePace(v2, ok)
        else: discard
    else: ok = false
  of stWheel:
    if c.expectMap(v, "wheel"):
      s.target = c.parseTargetMap(v, ["direction", "amount"], "wheel", ok)
      let d = v.get("direction")
      if d == nil:
        c.structural(v, "wheel needs 'direction' (up, down, left, right)")
        ok = false
      elif d.kind == yString and d.s in ["up", "down", "left", "right"]:
        s.direction = parseEnum[Direction](d.s)
      else:
        c.structural(d, "direction is up, down, left or right")
        ok = false
      let a = v.get("amount")
      if a != nil:
        if not a.isIntegral or a.intValue < 1:
          c.structural(a, "amount is a positive integer")
          ok = false
        else: s.amount = a.intValue
    else: ok = false
  of stExpect:
    s.observation = c.parseObservation(v, "expect", ok)
  of stWait:
    if v.kind == yString:
      if v.s.isDottedName: s.untilName = v.s
      else:
        c.structural(v, "wait names a sync condition (role.condition or condition)")
        ok = false
    elif v.kind == yMap:
      if not c.checkKeys(v, ["until", "timeout"], "wait"): ok = false
      let u = v.get("until")
      if u == nil:
        c.structural(v, "wait needs 'until'")
        ok = false
      elif u.kind == yString:
        if u.s.isDottedName: s.untilName = u.s
        else:
          c.structural(u, "until names a sync condition (role.condition or condition)")
          ok = false
      elif u.kind == yMap:
        s.untilIsObservation = true
        s.observation = c.parseObservation(u, "until", ok)
      else:
        c.structural(u, "until is a sync condition name or an observation")
        ok = false
      if v.get("timeout") != nil:
        s.timeout = c.parseDuration(v.get("timeout"), "timeout")
        if s.timeout < 0: ok = false
    else:
      c.structural(v, "wait takes a condition name or { until, timeout }")
      ok = false
  of stFlow, stExt:
    if kind == stFlow:
      s.name = c.parseName(v, "flow")
    elif c.expectString(v, "ext"):
      if v.s.isExtName: s.name = v.s
      else:
        c.structural(v, "ext names <backend>.<step>, e.g. termassert.golden")
        ok = false
    else: ok = false
    if s.name == "": ok = false
    let w = n.get("with")
    if w != nil:
      if not c.expectMap(w, "with"): ok = false
      s.args = w
  of stBeat:
    s.name = c.parseName(v, "beat")
    if s.name == "": ok = false
    let st = n.get("steps")
    if st == nil:
      c.structural(n, "a beat needs 'steps'")
      ok = false
    else:
      let before = c.diags.len
      s.steps = c.parseSteps(st, "beat steps")
      for k in before ..< c.diags.len:
        if c.diags[k].phase == phStructural and c.diags[k].severity == sevError: ok = false
  of stCapture:
    if c.expectMap(v, "capture"):
      if not c.checkKeys(v, ["name", "of"], "capture"): ok = false
      let nm = v.get("name")
      if nm == nil:
        c.structural(v, "capture needs 'name'")
        ok = false
      else:
        s.name = c.parseName(nm, "capture name")
        if s.name == "": ok = false
      let o = v.get("of")
      if o != nil:
        s.hasCaptureOf = true
        s.captureOf.at = c.parseLocatorNode(o, "capture of", ok)
        s.captureOf.atText = (if o.kind == yString: o.s else: "")
        s.captureOf.line = o.line
        s.captureOf.col = o.col
    else: ok = false
  if not ok: return nil
  s

proc parseSteps*(c: var Ctx; n: YNode; what: string): seq[Step] =
  if n == nil or n.kind != ySeq:
    c.structural(n, what & " must be a list of steps, found " & n.kindName)
    return
  for it in n.items:
    let s = c.parseStep(it)
    if s != nil: result.add s

# --- the file ------------------------------------------------------------------------

proc parseScenarioNode*(root: YNode; file: string): (Scenario, Diagnostics) =
  var c = Ctx(file: file)
  var sc = Scenario(file: file)
  if root == nil or root.kind != yMap:
    c.structural(root, "a scenario file is a mapping (scenario, name, pack, stage, steps)")
    return (sc, c.diags)
  # The version first: a file of another version is refused by number, before
  # anything else in it is read.
  let ver = root.get("scenario")
  if ver == nil:
    c.structural(root, "missing 'scenario: 1' (the format version)")
  elif not ver.isNumber:
    c.structural(ver, "'scenario' is the format version number, found " & ver.kindName)
  elif ver.numValue != float(ImplementedVersion):
    c.report(ver, "version", "scenario format version " & ver.scalarText &
      " is not implemented; this parser implements version " & $ImplementedVersion)
    return (sc, c.diags)
  else:
    sc.version = ImplementedVersion
  discard c.checkKeys(root, ["scenario", "name", "pack", "summary", "requires", "stage", "steps"],
    "a scenario")
  let nm = root.get("name")
  if nm == nil: c.structural(root, "missing 'name'")
  elif c.expectString(nm, "name"):
    if nm.s.isScenarioName: sc.name = nm.s
    else: c.structural(nm, "scenario name '" & nm.s & "' must be lower-case words separated by '-' and '/'")
  for k, v in root.pairs:
    case k.s
    of "pack": sc.pack = c.parseName(v, "pack")
    of "summary":
      if c.expectString(v, "summary"): sc.summary = v.s
    of "requires":
      if v.kind != ySeq:
        c.structural(v, "requires is a list of backend names")
      else:
        for it in v.items:
          let b = c.parseName(it, "requires")
          if b != "" and b in sc.requires: c.structural(it, "backend '" & b & "' listed twice")
          if b != "": sc.requires.add b
    of "stage":
      if v.kind != ySeq:
        c.structural(v, "stage is a list of { use, with } calls")
      else:
        for it in v.items:
          if not c.expectMap(it, "a stage call"): continue
          discard c.checkKeys(it, ["use", "with"], "a stage call")
          let u = it.get("use")
          if u == nil:
            c.structural(it, "a stage call needs 'use' (a stage procedure name)")
            continue
          let call = StageCall(use: c.parseName(u, "use"), args: it.get("with"),
                               line: it.line, col: it.col)
          if call.args != nil and call.args.kind != yMap:
            c.structural(call.args, "with must be a mapping")
          sc.stage.add call
    of "steps": sc.steps = c.parseSteps(v, "steps")
    else: discard
  if root.get("steps") == nil: c.structural(root, "missing 'steps'")
  (sc, c.diags)

proc parseScenarioText*(text, file: string): (Scenario, Diagnostics) =
  var root: YNode
  try:
    root = readYaml(text)
  except YamlError as e:
    var msg = e.msg
    let colon = msg.find(": ")
    if colon >= 0: msg = msg[colon + 2 .. ^1]
    return (Scenario(file: file), @[Diagnostic(rule: "yaml", severity: sevError,
      phase: phStructural, file: file, line: e.line, col: e.col, message: msg)])
  parseScenarioNode(root, file)

proc parseScenarioFile*(path: string): (Scenario, Diagnostics) =
  parseScenarioText(readFile(path), path)
