## The normalised form of a scenario: a JSON document that is itself a valid
## scenario, with every shorthand expanded, durations in milliseconds or whole
## seconds, chords and locators in canonical spelling. Parsing the normalised
## form gives back an equal model (the round-trip test relies on it).

import std/[json, tables]
import ./model, ./yaml

proc emitTarget(t: Target): JsonNode =
  result = %*{"at": $t.at}
  if t.anchor.name != "": result["anchor"] = %($t.anchor)

proc emitPace(p: Pace): JsonNode =
  case p.kind
  of paceNone: newJNull()
  of pacePreset: %p.preset
  of paceParams:
    var o = newJObject()
    if p.preset != "": o["preset"] = %p.preset
    for k, v in p.params:
      if k in ["key-mean", "key-min", "key-max", "commit-pause"]:
        o[k] = %formatDuration(v.getBiggestInt)
      else: o[k] = v
    o

proc emitMatcher(m: Matcher): JsonNode =
  case m.kind
  of mEquals:
    result = (if m.value.kind == JObject: %*{"equals": m.value} else: m.value)
  of mCount:
    result = %*{"count": emitMatcher(m.inner)}
  else:
    result = newJObject()
    result[$m.kind] = m.value

proc emitObservation(o: Observation): JsonNode =
  result = %*{"at": $o.target.at}
  for k, m in o.properties: result[k] = emitMatcher(m)
  if o.asserts.len == 1: result["assert"] = %($o.asserts[0])
  elif o.asserts.len > 1:
    var a = newJArray()
    for inv in o.asserts: a.add %($inv)
    result["assert"] = a
  if o.hasGeometry:
    var g = newJObject()
    for r in o.geometry.relations: g[$r.rel] = %($r.other)
    if o.geometry.visible >= 0: g["visible"] = %(o.geometry.visible == 1)
    result["geometry"] = g
  if o.role != "": result["role"] = %o.role
  if o.absent >= 0: result["absent"] = %(o.absent == 1)
  if o.present >= 0: result["present"] = %(o.present == 1)

proc emitSpan(s: Span): JsonNode =
  result = %*{"text": s.text}
  if s.fromId != "": result["from"] = %s.fromId
  if s.toId != "": result["to"] = %s.toId
  if s.voice != "": result["voice"] = %s.voice
  if s.style != "": result["style"] = %s.style

proc emitSteps*(steps: seq[Step]): JsonNode

proc emitStep*(s: Step): JsonNode =
  result = newJObject()
  case s.kind
  of stKey: result["key"] = %s.key
  of stChord:
    if s.bound != "": result["chord"] = %*{"bound": s.bound}
    else: result["chord"] = %($s.chords)
  of stType:
    if s.pace.kind == paceNone: result["type"] = %s.text
    else: result["type"] = %*{"text": s.text, "pace": emitPace(s.pace)}
  of stPress, stRelease:
    if s.isButton:
      var t = emitTarget(s.target)
      t["button"] = %($s.button)
      result[$s.kind] = t
    else: result[$s.kind] = %*{"key": s.key}
  of stMove, stHover, stClick:
    var t = emitTarget(s.target)
    if s.pace.kind != paceNone: t["pace"] = emitPace(s.pace)
    if s.kind == stHover and s.hoverFor >= 0: t["for"] = %formatDuration(s.hoverFor)
    if s.kind == stClick:
      t["button"] = %($s.button)
      t["count"] = %s.count
      if s.modifiers != {}:
        var m = newJArray()
        for x in Modifier:
          if x in s.modifiers: m.add %($x)
        t["modifiers"] = m
    result[$s.kind] = t
  of stDrag:
    var d = %*{"from": emitTarget(s.dragFrom), "to": emitTarget(s.dragTo),
               "button": $s.button}
    if s.via.len > 0:
      var v = newJArray()
      for t in s.via: v.add emitTarget(t)
      d["via"] = v
    if s.modifiers != {}:
      var m = newJArray()
      for x in Modifier:
        if x in s.modifiers: m.add %($x)
      d["modifiers"] = m
    if s.pace.kind != paceNone: d["pace"] = emitPace(s.pace)
    result["drag"] = d
  of stWheel:
    var t = emitTarget(s.target)
    t["direction"] = %($s.direction)
    t["amount"] = %s.amount
    result["wheel"] = t
  of stExpect: result["expect"] = emitObservation(s.observation)
  of stWait:
    var w = newJObject()
    w["until"] = (if s.untilIsObservation: emitObservation(s.observation) else: %s.untilName)
    if s.timeout >= 0: w["timeout"] = %formatDuration(s.timeout)
    result["wait"] = w
  of stFlow, stExt:
    result[$s.kind] = %s.name
    if s.args != nil: result["with"] = s.args.toJson
  of stBeat:
    result["beat"] = %s.name
    result["steps"] = emitSteps(s.steps)
  of stCapture:
    var c = %*{"name": s.name}
    if s.hasCaptureOf: c["of"] = %($s.captureOf.at)
    result["capture"] = c
  if s.kind in InputKinds and not s.settle: result["settle"] = %false
  if s.id != "": result["id"] = %s.id
  if s.leadIn >= 0: result["lead-in"] = %formatDuration(s.leadIn)
  if s.dwell >= 0: result["dwell"] = %formatDuration(s.dwell)
  if s.chapter != "": result["chapter"] = %s.chapter
  if s.hasNarration: result["narration"] = emitSpan(s.narration)
  if s.hasCaption: result["caption"] = emitSpan(s.caption)
  if s.callouts.len > 0:
    var a = newJArray()
    for c in s.callouts:
      var o = emitTarget(c.target)
      o["text"] = %c.text
      if c.fromId != "": o["from"] = %c.fromId
      if c.toId != "": o["to"] = %c.toId
      a.add o
    result["callout"] = a
  if s.alternatives.len > 0:
    var o = newJObject()
    for k, v in s.alternatives: o[k] = emitSteps(v)
    result["alternatives"] = o

proc emitSteps*(steps: seq[Step]): JsonNode =
  result = newJArray()
  for s in steps: result.add emitStep(s)

proc emitScenario*(sc: Scenario): JsonNode =
  result = %*{"scenario": sc.version, "name": sc.name}
  if sc.pack != "": result["pack"] = %sc.pack
  if sc.summary != "": result["summary"] = %sc.summary
  if sc.requires.len > 0: result["requires"] = %sc.requires
  if sc.stage.len > 0:
    var a = newJArray()
    for c in sc.stage:
      var o = %*{"use": c.use}
      if c.args != nil: o["with"] = c.args.toJson
      a.add o
    result["stage"] = a
  result["steps"] = emitSteps(sc.steps)
