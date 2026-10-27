## The predicate language of named assertions and sync predicates.
##
##   pred    := or
##   or      := and ("or" and)*
##   and     := unary ("and" unary)*
##   unary   := "not" unary | quant | cmp
##   quant   := ("every" | "some" | "none") binding ":" pred
##   binding := ROLE | NAME "of" ROLE | "adjacent" "pair" "(" NAME "," NAME ")" "of" ROLE
##   cmp     := term (OP term)?
##   OP      := == != < <= > >= in contains matches
##   term    := literal | path | "count" "(" ROLE ")" | "(" pred ")"
##   path    := NAME ("." NAME | "[" NAME "]")*
##   literal := NUMBER | STRING | true | false
##
## Parsing is here; checking names against a pack is `checkPredicate`; the
## runner evaluates. A predicate has one implementation, evaluated by the runner
## over values a backend produced — never one copy per backend.

import std/[json, sequtils, strutils, sets, tables]
import ./model

type
  PredicateError* = object of CatchableError
    pos*: int

  TokKind = enum
    tkName, tkNum, tkStr, tkOp, tkPunct, tkEnd

  Tok = object
    kind: TokKind
    text: string
    pos: int

  PParser = object
    toks: seq[Tok]
    k: int

const
  PredicateKeywords* = ["every", "some", "none", "adjacent", "pair", "of", "and", "or", "not",
                        "count", "in", "contains", "matches", "true", "false"]

proc perr(pos: int; msg: string) {.noreturn.} =
  var e = newException(PredicateError, msg & " (at character " & $(pos + 1) & ")")
  e.pos = pos
  raise e

proc tokenize(s: string): seq[Tok] =
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in Whitespace:
      inc i
    elif c in {'a'..'z', 'A'..'Z', '_'}:
      let st = i
      while i < s.len and s[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: inc i
      # a trailing '-' belongs to no name
      while i > st + 1 and s[i - 1] == '-': dec i
      result.add Tok(kind: tkName, text: s[st ..< i], pos: st)
    elif c in Digits or (c == '-' and i + 1 < s.len and s[i + 1] in Digits and
        (result.len == 0 or (result[^1].kind in {tkOp, tkPunct} and
                             result[^1].text notin [")", "]"]) or
         (result[^1].kind == tkName and result[^1].text in PredicateKeywords))):
      let st = i
      inc i
      while i < s.len and s[i] in Digits: inc i
      if i < s.len and s[i] == '.' and i + 1 < s.len and s[i + 1] in Digits:
        inc i
        while i < s.len and s[i] in Digits: inc i
      result.add Tok(kind: tkNum, text: s[st ..< i], pos: st)
    elif c == '"':
      let st = i
      inc i
      var v = ""
      while true:
        if i >= s.len: perr(st, "unterminated string")
        if s[i] == '"':
          inc i
          break
        if s[i] == '\\' and i + 1 < s.len:
          v.add s[i + 1]
          i += 2
        else:
          v.add s[i]
          inc i
      result.add Tok(kind: tkStr, text: v, pos: st)
    elif c in {'=', '!', '<', '>'}:
      let st = i
      if i + 1 < s.len and s[i + 1] == '=':
        result.add Tok(kind: tkOp, text: s[i .. i + 1], pos: st)
        i += 2
      elif c in {'<', '>'}:
        result.add Tok(kind: tkOp, text: $c, pos: st)
        inc i
      else:
        perr(st, "unknown operator '" & $c & "' (==, !=, <, <=, >, >=)")
    elif c in {'(', ')', '[', ']', ',', ':', '.'}:
      result.add Tok(kind: tkPunct, text: $c, pos: i)
      inc i
    else:
      perr(i, "unexpected character '" & $c & "'")
  result.add Tok(kind: tkEnd, text: "", pos: s.len)

proc peek(p: PParser): Tok = p.toks[p.k]
proc next(p: var PParser): Tok =
  result = p.toks[p.k]
  if p.k < p.toks.high: inc p.k

proc isWord(t: Tok; w: string): bool = t.kind == tkName and t.text == w
proc isPunct(t: Tok; w: string): bool = t.kind == tkPunct and t.text == w

proc expectPunct(p: var PParser; w: string) =
  let t = p.next
  if not t.isPunct(w): perr(t.pos, "expected '" & w & "'")

proc expectWord(p: var PParser; w: string) =
  let t = p.next
  if not t.isWord(w): perr(t.pos, "expected '" & w & "'")

proc expectName(p: var PParser; what: string): string =
  let t = p.next
  if t.kind != tkName or (t.text in PredicateKeywords and t.text != "count"):
    perr(t.pos, "expected " & what)
  t.text

proc parseOr(p: var PParser): Pred

proc parseTerm(p: var PParser): Pred =
  let t = p.peek
  case t.kind
  of tkNum:
    discard p.next
    if '.' in t.text: return Pred(kind: pdLit, lit: %parseFloat(t.text), pos: t.pos)
    return Pred(kind: pdLit, lit: %parseBiggestInt(t.text), pos: t.pos)
  of tkStr:
    discard p.next
    return Pred(kind: pdLit, lit: %t.text, pos: t.pos)
  of tkPunct:
    if t.text == "(":
      discard p.next
      result = p.parseOr()
      p.expectPunct(")")
      return
    perr(t.pos, "unexpected '" & t.text & "'")
  of tkName:
    if t.text in ["true", "false"]:
      discard p.next
      return Pred(kind: pdLit, lit: %(t.text == "true"), pos: t.pos)
    if t.text == "count" and p.toks[p.k + 1].isPunct("("):
      discard p.next
      discard p.next
      let role = p.expectName("a role name")
      p.expectPunct(")")
      return Pred(kind: pdCount, countRole: role, pos: t.pos)
    if t.text in PredicateKeywords and t.text != "count":
      perr(t.pos, "unexpected keyword '" & t.text & "'")
    discard p.next
    result = Pred(kind: pdPath, pos: t.pos, parts: @[PathPart(name: t.text)])
    while true:
      if p.peek.isPunct("."):
        discard p.next
        result.parts.add PathPart(name: p.expectName("a property name"))
      elif p.peek.isPunct("["):
        discard p.next
        result.parts.add PathPart(name: p.expectName("a parameter name"), dynamic: true)
        p.expectPunct("]")
      else: break
  of tkOp, tkEnd:
    perr(t.pos, if t.kind == tkEnd: "unexpected end of predicate" else: "unexpected '" & t.text & "'")

proc parseCmp(p: var PParser): Pred =
  let lhs = p.parseTerm()
  let t = p.peek
  var op = ""
  if t.kind == tkOp: op = t.text
  elif t.kind == tkName and t.text in ["in", "contains", "matches"]: op = t.text
  if op == "": return lhs
  discard p.next
  Pred(kind: pdCmp, op: op, lhs: lhs, rhs: p.parseTerm(), pos: t.pos)

proc parseUnary(p: var PParser): Pred =
  let t = p.peek
  if t.isWord("not"):
    discard p.next
    return Pred(kind: pdNot, operand: p.parseUnary(), pos: t.pos)
  if t.kind == tkName and t.text in ["every", "some", "none"]:
    discard p.next
    result = Pred(kind: pdQuant, quant: parseEnum[QuantKind](t.text), pos: t.pos)
    if p.peek.isWord("adjacent"):
      discard p.next
      p.expectWord("pair")
      p.expectPunct("(")
      result.adjacent = true
      result.binder = p.expectName("a variable name")
      p.expectPunct(",")
      result.binder2 = p.expectName("a variable name")
      p.expectPunct(")")
      p.expectWord("of")
      result.ofRole = p.expectName("a role name")
    else:
      let first = p.expectName("a role or variable name")
      if p.peek.isWord("of"):
        discard p.next
        result.binder = first
        result.ofRole = p.expectName("a role name")
      else:
        result.binder = first
        result.ofRole = first
    p.expectPunct(":")
    result.body = p.parseOr()
    return
  p.parseCmp()

proc parseAnd(p: var PParser): Pred =
  let first = p.parseUnary()
  if not p.peek.isWord("and"): return first
  result = Pred(kind: pdAnd, terms: @[first], pos: first.pos)
  while p.peek.isWord("and"):
    discard p.next
    result.terms.add p.parseUnary()

proc parseOr(p: var PParser): Pred =
  let first = p.parseAnd()
  if not p.peek.isWord("or"): return first
  result = Pred(kind: pdOr, terms: @[first], pos: first.pos)
  while p.peek.isWord("or"):
    discard p.next
    result.terms.add p.parseAnd()

proc parsePredicate*(s: string): Pred =
  var p = PParser(toks: tokenize(s))
  result = p.parseOr()
  if p.peek.kind != tkEnd:
    perr(p.peek.pos, "unexpected '" & p.peek.text & "' after the predicate")

proc `$`*(p: Pred): string =
  case p.kind
  of pdOr: p.terms.mapIt($it).join(" or ")
  of pdAnd: p.terms.mapIt($it).join(" and ")
  of pdNot: "not " & $p.operand
  of pdQuant:
    var b = $p.quant & " "
    if p.adjacent: b.add "adjacent pair (" & p.binder & ", " & p.binder2 & ") of " & p.ofRole
    elif p.binder == p.ofRole: b.add p.ofRole
    else: b.add p.binder & " of " & p.ofRole
    "(" & b & ": " & $p.body & ")"
  of pdCmp: $p.lhs & " " & p.op & " " & $p.rhs
  of pdLit: $p.lit
  of pdPath:
    var r = p.parts[0].name
    for k in 1 ..< p.parts.len:
      if p.parts[k].dynamic: r.add "[" & p.parts[k].name & "]"
      else: r.add "." & p.parts[k].name
    r
  of pdCount: "count(" & p.countRole & ")"

# --- checking against a pack ------------------------------------------------------

type
  Scope = object
    selfRole: string
    vars: Table[string, string]     ## variable -> role
    params: HashSet[string]

type
  CheckCtx = object
    pack: Pack
    problems: seq[string]
    dynamicUses: seq[tuple[param, role: string]]

proc roleHasChild(pack: Pack; role, child: string): bool =
  pack.roles.hasKey(role) and pack.roles[role].children.hasKey(child)

proc hasProp(pack: Pack; role, prop: string): bool =
  if prop in ImplicitProperties: return true
  pack.roles.hasKey(role) and pack.roles[role].properties.hasKey(prop)

proc walk(cx: var CheckCtx; p: Pred; sc: Scope) =
  let pack = cx.pack
  case p.kind
  of pdOr, pdAnd:
    for t in p.terms: cx.walk(t, sc)
  of pdNot: cx.walk(p.operand, sc)
  of pdQuant:
    # the iterated role is a child of the role the predicate is declared on
    if not pack.roleHasChild(sc.selfRole, p.ofRole):
      cx.problems.add "'" & p.ofRole & "' is not a child role of '" & sc.selfRole & "'"
    var inner = sc
    inner.vars[p.binder] = p.ofRole
    if p.adjacent: inner.vars[p.binder2] = p.ofRole
    cx.walk(p.body, inner)
  of pdCmp:
    cx.walk(p.lhs, sc)
    cx.walk(p.rhs, sc)
  of pdLit: discard
  of pdCount:
    if not pack.roleHasChild(sc.selfRole, p.countRole):
      cx.problems.add "count(" & p.countRole & "): not a child role of '" & sc.selfRole & "'"
  of pdPath:
    let head = p.parts[0].name
    if sc.vars.hasKey(head):
      let role = sc.vars[head]
      if p.parts.len > 2:
        cx.problems.add "'" & $p & "': properties are leaves; one level of access only"
      if p.parts.len > 1:
        let part = p.parts[1]
        if part.dynamic:
          if part.name notin sc.params:
            cx.problems.add "'" & part.name & "' in " & head & "[" & part.name &
              "] is not a parameter"
          else: cx.dynamicUses.add (part.name, role)
        elif not pack.hasProp(role, part.name):
          cx.problems.add "'" & part.name & "' is not a property of role '" & role & "'"
    elif head in sc.params:
      if p.parts.len > 1: cx.problems.add "parameter '" & head & "' has no properties"
    elif pack.hasProp(sc.selfRole, head):
      if p.parts.len > 1: cx.problems.add "property '" & head & "' has no properties"
    else:
      cx.problems.add "'" & head & "' is not a variable, a parameter, or a property of role '" &
        sc.selfRole & "'"

proc checkPredicate*(pack: Pack; selfRole: string; params: openArray[string];
                     p: Pred; problems: var seq[string];
                     dynamicUses: var seq[tuple[param, role: string]]) =
  ## Every name resolves: bound variables to a child role of the role the
  ## predicate is declared on, properties to a declared property, parameters to
  ## a declared parameter. `dynamicUses` collects `x[param]` uses so that an
  ## invocation with a literal argument can be checked against the role.
  var sc = Scope(selfRole: selfRole)
  for x in params: sc.params.incl x
  var cx = CheckCtx(pack: pack)
  cx.walk(p, sc)
  problems.add cx.problems
  dynamicUses.add cx.dynamicUses
