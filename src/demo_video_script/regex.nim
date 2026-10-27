## The regular expressions of the `matches` matcher and predicate operator.
##
## A small backtracking engine over Unicode code points, so the runner has no
## run-time library dependency and every backend's values are matched the same
## way. The supported syntax is the common subset:
##
##   literals, `.` (any code point but a newline), `[abc]`, `[a-z]`, `[^…]`,
##   `\d \w \s \D \W \S`, escaped metacharacters, `^` and `$`, groups `( … )`
##   and `(?: … )`, alternation `|`, and the greedy quantifiers `* + ? {n}
##   {n,} {n,m}`.
##
## A pattern is searched for anywhere in the subject unless anchored. Anything
## else (backreferences, lookaround, lazy quantifiers, flags) is refused when
## the pattern is compiled, never matched approximately.

import std/unicode

type
  RegexError* = object of CatchableError

  NodeKind = enum
    nkChar, nkAny, nkClass, nkStart, nkEnd, nkGroup, nkAlt

  ClassItem = object
    lo, hi: int32           ## a range; for \d \w \s, lo = -1 and hi names the class
    negatedShort: bool

  Node = ref object
    kind: NodeKind
    ch: int32
    items: seq[ClassItem]
    negated: bool
    alts: seq[seq[Node]]    ## nkGroup / nkAlt: alternatives, each a sequence
    minRep, maxRep: int     ## quantifier; maxRep = -1 for unbounded

  Regex* = object
    alts: seq[seq[Node]]
    source*: string

  RParser = object
    r: seq[Rune]
    i: int
    src: string

proc fail(p: RParser; msg: string) {.noreturn.} =
  raise newException(RegexError, "regular expression /" & p.src & "/: " & msg &
    " (at " & $(p.i + 1) & ")")

proc atEnd(p: RParser): bool = p.i >= p.r.len
proc peek(p: RParser): int32 = (if p.i < p.r.len: int32(p.r[p.i]) else: -1)

const
  shortD = 1'i32
  shortW = 2'i32
  shortS = 3'i32

proc isShort(c: int32; which: int32): bool =
  case which
  of shortD: c >= ord('0') and c <= ord('9')
  of shortW: (c >= ord('a') and c <= ord('z')) or (c >= ord('A') and c <= ord('Z')) or
             (c >= ord('0') and c <= ord('9')) or c == ord('_')
  of shortS: c in [32'i32, 9, 10, 13, 12, 11]
  else: false

proc parseEscape(p: var RParser; inClass: bool): ClassItem =
  ## After a backslash.
  if p.atEnd: p.fail("a trailing backslash")
  let c = p.peek
  inc p.i
  case char(c and 0x7f)
  of 'd': ClassItem(lo: -1, hi: shortD)
  of 'w': ClassItem(lo: -1, hi: shortW)
  of 's': ClassItem(lo: -1, hi: shortS)
  of 'D': ClassItem(lo: -1, hi: shortD, negatedShort: true)
  of 'W': ClassItem(lo: -1, hi: shortW, negatedShort: true)
  of 'S': ClassItem(lo: -1, hi: shortS, negatedShort: true)
  of 'n': ClassItem(lo: 10, hi: 10)
  of 't': ClassItem(lo: 9, hi: 9)
  of 'r': ClassItem(lo: 13, hi: 13)
  else:
    if c < 128 and char(c) in {'a'..'z', 'A'..'Z', '0'..'9'}:
      p.fail("unsupported escape \\" & $char(c))
    ClassItem(lo: c, hi: c)

proc parseAlts(p: var RParser; depth: int): seq[seq[Node]]

proc parseQuant(p: var RParser; n: Node) =
  n.minRep = 1
  n.maxRep = 1
  if p.atEnd: return
  let c = p.peek
  if c == ord('*'): (n.minRep = 0; n.maxRep = -1; inc p.i)
  elif c == ord('+'): (n.minRep = 1; n.maxRep = -1; inc p.i)
  elif c == ord('?'): (n.minRep = 0; n.maxRep = 1; inc p.i)
  elif c == ord('{'):
    inc p.i
    var a = 0
    var digits = 0
    while not p.atEnd and p.peek >= ord('0') and p.peek <= ord('9'):
      a = a * 10 + int(p.peek - ord('0'))
      inc p.i
      inc digits
    if digits == 0: p.fail("expected a number in {n,m}")
    n.minRep = a
    n.maxRep = a
    if p.peek == ord(','):
      inc p.i
      if p.peek == ord('}'): n.maxRep = -1
      else:
        var b = 0
        digits = 0
        while not p.atEnd and p.peek >= ord('0') and p.peek <= ord('9'):
          b = b * 10 + int(p.peek - ord('0'))
          inc p.i
          inc digits
        if digits == 0: p.fail("expected a number in {n,m}")
        if b < a: p.fail("{n,m} with m < n")
        n.maxRep = b
    if p.peek != ord('}'): p.fail("expected '}'")
    inc p.i
  else: return
  if not p.atEnd and p.peek in [ord('?'), ord('+')]:
    p.fail("lazy and possessive quantifiers are not supported")
  if n.kind in {nkStart, nkEnd}: p.fail("a quantifier on an anchor")

proc parseSeq(p: var RParser; depth: int): seq[Node] =
  while not p.atEnd:
    let c = p.peek
    if c == ord('|') or c == ord(')'): break
    var n: Node
    if c == ord('('):
      inc p.i
      if p.peek == ord('?'):
        inc p.i
        if p.peek != ord(':'): p.fail("only (?: … ) groups are supported")
        inc p.i
      n = Node(kind: nkGroup, alts: p.parseAlts(depth + 1))
      if p.peek != ord(')'): p.fail("an unclosed group")
      inc p.i
    elif c == ord('['):
      inc p.i
      n = Node(kind: nkClass)
      if p.peek == ord('^'):
        n.negated = true
        inc p.i
      var first = true
      while true:
        if p.atEnd: p.fail("an unclosed [")
        var x = p.peek
        if x == ord(']') and not first:
          inc p.i
          break
        first = false
        inc p.i
        var item: ClassItem
        if x == ord('\\'): item = p.parseEscape(true)
        else: item = ClassItem(lo: x, hi: x)
        if item.lo >= 0 and p.peek == ord('-') and p.i + 1 < p.r.len and
            int32(p.r[p.i + 1]) != ord(']'):
          inc p.i
          var y = p.peek
          inc p.i
          if y == ord('\\'):
            let e = p.parseEscape(true)
            if e.lo < 0: p.fail("a class shorthand cannot end a range")
            y = e.lo
          if y < item.lo: p.fail("a reversed range")
          item.hi = y
        n.items.add item
    elif c == ord('.'):
      inc p.i
      n = Node(kind: nkAny)
    elif c == ord('^'):
      inc p.i
      n = Node(kind: nkStart)
    elif c == ord('$'):
      inc p.i
      n = Node(kind: nkEnd)
    elif c == ord('\\'):
      inc p.i
      let e = p.parseEscape(false)
      if e.lo < 0 or e.lo != e.hi: n = Node(kind: nkClass, items: @[e])
      else: n = Node(kind: nkChar, ch: e.lo)
    elif c in [ord('*'), ord('+'), ord('?'), ord('{')]:
      p.fail("a quantifier with nothing to repeat")
    else:
      inc p.i
      n = Node(kind: nkChar, ch: c)
    p.parseQuant(n)
    result.add n

proc parseAlts(p: var RParser; depth: int): seq[seq[Node]] =
  result.add p.parseSeq(depth)
  while not p.atEnd and p.peek == ord('|'):
    inc p.i
    result.add p.parseSeq(depth)

proc compile*(pattern: string): Regex =
  var p = RParser(r: pattern.toRunes, src: pattern)
  result.alts = p.parseAlts(0)
  if not p.atEnd: p.fail("an unmatched ')'")
  result.source = pattern

# --- matching ---------------------------------------------------------------------

proc classHas(n: Node; c: int32): bool =
  var hit = false
  for it in n.items:
    if it.lo < 0:
      if isShort(c, it.hi) != it.negatedShort: hit = true
    elif c >= it.lo and c <= it.hi: hit = true
  hit != n.negated

proc matchOne(n: Node; s: seq[int32]; i: int): int =
  ## For single-width nodes: the next index, or -1.
  if i >= s.len: return -1
  case n.kind
  of nkChar: (if s[i] == n.ch: i + 1 else: -1)
  of nkAny: (if s[i] != 10: i + 1 else: -1)
  of nkClass: (if n.classHas(s[i]): i + 1 else: -1)
  else: -1

proc matchSeq(nodes: seq[Node]; k: int; s: seq[int32]; i: int;
              cont: proc (j: int): bool): bool

proc matchAlts(alts: seq[seq[Node]]; s: seq[int32]; i: int;
               cont: proc (j: int): bool): bool =
  for a in alts:
    if matchSeq(a, 0, s, i, cont): return true
  false

proc matchRep(n: Node; count: int; s: seq[int32]; i: int;
              cont: proc (j: int): bool): bool =
  ## Greedy: try one more repetition first, then stop.
  if n.maxRep < 0 or count < n.maxRep:
    case n.kind
    of nkGroup:
      let more = matchAlts(n.alts, s, i, proc (j: int): bool =
        if j == i and count >= n.minRep: return false   # no progress
        matchRep(n, count + 1, s, j, cont))
      if more: return true
    else:
      let j = matchOne(n, s, i)
      if j >= 0 and matchRep(n, count + 1, s, j, cont): return true
  count >= n.minRep and cont(i)

proc matchSeq(nodes: seq[Node]; k: int; s: seq[int32]; i: int;
              cont: proc (j: int): bool): bool =
  if k == nodes.len: return cont(i)
  let n = nodes[k]
  case n.kind
  of nkStart:
    i == 0 and matchSeq(nodes, k + 1, s, i, cont)
  of nkEnd:
    i == s.len and matchSeq(nodes, k + 1, s, i, cont)
  else:
    matchRep(n, 0, s, i, proc (j: int): bool = matchSeq(nodes, k + 1, s, j, cont))

proc find*(re: Regex; subject: string): bool =
  ## Whether the pattern matches anywhere in `subject`.
  var s: seq[int32]
  for r in subject.runes: s.add int32(r)
  for start in 0 .. s.len:
    if matchAlts(re.alts, s, start, proc (j: int): bool = true): return true
  false

proc matches*(pattern, subject: string): bool = compile(pattern).find(subject)
