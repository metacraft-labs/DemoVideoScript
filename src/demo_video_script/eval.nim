## Evaluating observations: matchers (§4.4.1), named-assertion predicates
## (§4.4.2) and geometry relations (§4.4.3). This is the only implementation of
## each, and it runs in the runner over values a backend produced.

import std/[json, math, tables, strutils]
import ./model, ./regex

type
  EvalError* = object of CatchableError

  Geometry* = object
    x*, y*, w*, h*: float
    visible*: bool

  ChildValues* = Table[string, seq[JsonNode]]
    ## role -> the properties of each child instance of that role, in order

proc evalError(msg: string): ref EvalError = newException(EvalError, msg)

proc geometryOf*(j: JsonNode): Geometry =
  if j == nil or j.kind != JObject: raise evalError("no geometry was read")
  Geometry(x: j{"x"}.getFloat, y: j{"y"}.getFloat, w: j{"w"}.getFloat, h: j{"h"}.getFloat,
           visible: j{"visible"}.getBool(true))

proc num(j: JsonNode): float =
  case j.kind
  of JInt: float(j.getBiggestInt)
  of JFloat: j.getFloat
  else: raise evalError("expected a number, observed " & $j)

proc jsonEq*(a, b: JsonNode): bool =
  ## JSON equality with numbers compared by value (3 == 3.0).
  if a.kind in {JInt, JFloat} and b.kind in {JInt, JFloat}: return num(a) == num(b)
  if a.kind != b.kind: return false
  case a.kind
  of JArray:
    if a.len != b.len: return false
    for k in 0 ..< a.len:
      if not jsonEq(a[k], b[k]): return false
    true
  of JObject:
    if a.len != b.len: return false
    for k, v in a:
      if not b.hasKey(k) or not jsonEq(v, b[k]): return false
    true
  else: a == b

proc containsValue(observed, operand: JsonNode): bool =
  case observed.kind
  of JString:
    operand.kind == JString and operand.getStr in observed.getStr
  of JArray:
    for it in observed:
      if it.kind == JString and operand.kind == JString:
        if operand.getStr in it.getStr: return true
      elif jsonEq(it, operand): return true
    false
  of JObject:
    if operand.kind != JObject: return false
    for k, v in operand:
      if not observed.hasKey(k) or not jsonEq(observed[k], v): return false
    true
  else: false

proc matchesRe(observed: JsonNode; pattern: string): bool =
  if observed.kind == JString: return regex.matches(pattern, observed.getStr)
  if observed.kind == JArray:
    for it in observed:
      if it.kind == JString and regex.matches(pattern, it.getStr): return true
    return false
  raise evalError("matches applies to text or lines, observed " & $observed)

proc evalMatcher*(m: Matcher; observed: JsonNode): bool =
  case m.kind
  of mEquals: jsonEq(observed, m.value)
  of mContains: containsValue(observed, m.value)
  of mMatches: matchesRe(observed, m.value.getStr)
  of mOneOf:
    for v in m.value:
      if jsonEq(observed, v): return true
    false
  of mLt: num(observed) < num(m.value)
  of mLe: num(observed) <= num(m.value)
  of mGt: num(observed) > num(m.value)
  of mGe: num(observed) >= num(m.value)
  of mCount:
    let n = case observed.kind
      of JArray: observed.len
      of JString: observed.getStr.len
      of JInt: int(observed.getBiggestInt)
      else: raise evalError("count applies to a list, observed " & $observed)
    evalMatcher(m.inner, %n)
  of mSubsequence:
    if observed.kind != JArray: raise evalError("subsequence applies to a list, observed " & $observed)
    var k = 0
    for it in observed:
      if k < m.value.len and jsonEq(it, m.value[k]): inc k
    k == m.value.len
  of mUnordered:
    if observed.kind != JArray: raise evalError("unordered applies to a list, observed " & $observed)
    if observed.len != m.value.len: return false
    var used = newSeq[bool](observed.len)
    for want in m.value:
      var found = false
      for k in 0 ..< observed.len:
        let it = observed[k]
        if not used[k] and jsonEq(it, want):
          used[k] = true
          found = true
          break
      if not found: return false
    true

proc describe*(m: Matcher): string =
  case m.kind
  of mEquals: $m.value
  of mCount: "count " & describe(m.inner)
  else: $m.kind & " " & $m.value

# --- geometry ---------------------------------------------------------------------

proc evalRelation*(rel: Relation; a, b: Geometry; tolerance: float): bool =
  let t = tolerance
  case rel
  of relAbove: a.y + a.h <= b.y + t
  of relBelow: a.y + t >= b.y + b.h
  of relLeftOf: a.x + a.w <= b.x + t
  of relRightOf: a.x + t >= b.x + b.w
  of relInside:
    a.x + t >= b.x and a.y + t >= b.y and a.x + a.w <= b.x + b.w + t and
      a.y + a.h <= b.y + b.h + t
  of relOverlaps:
    a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
  of relAlignedLeft: abs(a.x - b.x) <= t
  of relAlignedTop: abs(a.y - b.y) <= t
  of relSpansWidthOf: a.x <= b.x + t and a.x + a.w + t >= b.x + b.w
  of relSpansHeightOf: a.y <= b.y + t and a.y + a.h + t >= b.y + b.h

# --- predicates -----------------------------------------------------------------------

type
  Env = object
    selfProps: JsonNode
    children: ChildValues
    params: Table[string, JsonNode]
    vars: Table[string, JsonNode]

proc evalPred(p: Pred; env: Env): JsonNode

proc truthy(j: JsonNode): bool =
  case j.kind
  of JBool: j.getBool
  of JNull: false
  of JInt, JFloat: num(j) != 0
  of JString: j.getStr.len > 0
  of JArray: j.len > 0
  of JObject: true

proc compare(op: string; a, b: JsonNode): bool =
  case op
  of "==": jsonEq(a, b)
  of "!=": not jsonEq(a, b)
  of "<", "<=", ">", ">=":
    var c: int
    if a.kind in {JInt, JFloat} and b.kind in {JInt, JFloat}: c = cmp(num(a), num(b))
    elif a.kind == JString and b.kind == JString: c = cmp(a.getStr, b.getStr)
    elif a.kind == JBool and b.kind == JBool: c = cmp(a.getBool, b.getBool)
    else: raise evalError("cannot compare " & $a & " " & op & " " & $b)
    case op
    of "<": c < 0
    of "<=": c <= 0
    of ">": c > 0
    else: c >= 0
  of "in": containsValue(b, a) or (b.kind == JArray and (block:
      var f = false
      for it in b:
        if jsonEq(it, a): f = true
      f))
  of "contains": containsValue(a, b)
  of "matches":
    if b.kind != JString: raise evalError("matches takes a pattern string")
    matchesRe(a, b.getStr)
  else: raise evalError("unknown operator " & op)

proc evalPath(p: Pred; env: Env): JsonNode =
  let head = p.parts[0].name
  if env.vars.hasKey(head):
    let v = env.vars[head]
    if p.parts.len == 1: return v
    let part = p.parts[1]
    let prop = (if part.dynamic: env.params[part.name].getStr else: part.name)
    if not v.hasKey(prop): raise evalError("'" & prop & "' was not read for " & head)
    return v[prop]
  if env.params.hasKey(head): return env.params[head]
  if env.selfProps != nil and env.selfProps.hasKey(head): return env.selfProps[head]
  raise evalError("'" & head & "' has no value")

proc evalPred(p: Pred; env: Env): JsonNode =
  case p.kind
  of pdOr:
    for t in p.terms:
      if truthy(evalPred(t, env)): return %true
    %false
  of pdAnd:
    for t in p.terms:
      if not truthy(evalPred(t, env)): return %false
    %true
  of pdNot: %(not truthy(evalPred(p.operand, env)))
  of pdLit: p.lit
  of pdPath: evalPath(p, env)
  of pdCount: %(env.children.getOrDefault(p.countRole).len)
  of pdCmp: %compare(p.op, evalPred(p.lhs, env), evalPred(p.rhs, env))
  of pdQuant:
    let items = env.children.getOrDefault(p.ofRole)
    var results: seq[bool]
    if p.adjacent:
      for k in 0 ..< items.len - 1:
        var e = env
        e.vars[p.binder] = items[k]
        e.vars[p.binder2] = items[k + 1]
        results.add truthy(evalPred(p.body, e))
    else:
      for it in items:
        var e = env
        e.vars[p.binder] = it
        results.add truthy(evalPred(p.body, e))
    case p.quant
    of qEvery: (for r in results: (if not r: return %false)); %true
    of qSome: (for r in results: (if r: return %true)); %false
    of qNone: (for r in results: (if r: return %false)); %true

proc evalAssertion*(decl: AssertionDecl; args: seq[Arg]; selfProps: JsonNode;
                    children: ChildValues): bool =
  var env = Env(selfProps: selfProps, children: children)
  for k, prm in decl.sig.params:
    let a = args[k]
    env.params[prm] = case a.kind
      of argNumber: (if '.' in a.text: %parseFloat(a.text) else: %parseBiggestInt(a.text))
      else: %a.text
  truthy(evalPred(decl.pred, env))

proc evalSyncPredicate*(pred: Pred; selfProps: JsonNode; children: ChildValues): bool =
  truthy(evalPred(pred, Env(selfProps: selfProps, children: children)))

proc walkUsed(p: Pred; vars: Table[string, string]; selfOut: var seq[string];
              childOut: var Table[string, seq[string]]; params: Table[string, string]) =
  case p.kind
  of pdOr, pdAnd:
    for t in p.terms: walkUsed(t, vars, selfOut, childOut, params)
  of pdNot: walkUsed(p.operand, vars, selfOut, childOut, params)
  of pdCmp:
    walkUsed(p.lhs, vars, selfOut, childOut, params)
    walkUsed(p.rhs, vars, selfOut, childOut, params)
  of pdQuant:
    var inner = vars
    inner[p.binder] = p.ofRole
    if p.adjacent: inner[p.binder2] = p.ofRole
    discard childOut.mgetOrPut(p.ofRole, @[])
    walkUsed(p.body, inner, selfOut, childOut, params)
  of pdCount: discard childOut.mgetOrPut(p.countRole, @[])
  of pdLit: discard
  of pdPath:
    let head = p.parts[0].name
    if vars.hasKey(head):
      if p.parts.len > 1:
        let part = p.parts[1]
        let prop = (if part.dynamic: params.getOrDefault(part.name, "") else: part.name)
        if prop != "" and prop notin childOut.mgetOrPut(vars[head], @[]):
          childOut[vars[head]].add prop
    elif not params.hasKey(head) and head notin selfOut:
      selfOut.add head

proc propertiesUsed*(p: Pred; selfOut: var seq[string]; childOut: var Table[string, seq[string]];
                     params: Table[string, string] = initTable[string, string]()) =
  ## Which properties a predicate reads, so the runner reads exactly those.
  walkUsed(p, initTable[string, string](), selfOut, childOut, params)
