## A reader for the YAML 1.2 subset scenario and pack files use.
##
## Scenario files are standard YAML so that any YAML tool reads them. This module
## reads the subset the format needs and refuses, by name, the YAML features it
## does not support, rather than reading them approximately:
##
## - Supported: block mappings and sequences (including a sequence at the same
##   indentation as its mapping key, and compact mappings inside sequence items),
##   flow mappings and sequences (also across lines), plain, single-quoted and
##   double-quoted scalars, literal (`|`) and folded (`>`) block scalars with
##   chomping indicators, comments, a leading `---` and a trailing `...`.
## - Refused: anchors (`&`), aliases (`*`), tags (`!`), explicit keys (`?`),
##   directives (`%`), several documents in one file, tabs used for indentation,
##   duplicate mapping keys.
##
## Plain scalars are resolved with the YAML 1.2 core schema: `null`, `~` and the
## empty value are null; `true`/`false` (in the three spellings) are booleans;
## decimal, `0o` and `0x` integers; decimal and exponent floats, `.inf`, `.nan`.
## Everything else, and every quoted scalar, is a string.
##
## Every node carries the line and column (1-based) where it starts, so that
## diagnostics can point into the file.

import std/[json, strutils]
from std/unicode import Rune, toUTF8

type
  YamlError* = object of CatchableError
    line*, col*: int

  YKind* = enum
    yNull, yBool, yInt, yFloat, yString, ySeq, yMap

  YNode* = ref object
    line*, col*: int
    case kind*: YKind
    of yNull: discard
    of yBool: b*: bool
    of yInt: i*: BiggestInt
    of yFloat: f*: float
    of yString:
      s*: string
      quoted*: bool  ## written quoted (or as a block scalar) in the source
    of ySeq: items*: seq[YNode]
    of yMap:
      keys*: seq[YNode]      ## in source order; always yString after reading
      values*: seq[YNode]

  Parser = object
    src: string
    pos: int
    lineStarts: seq[int]

proc lineCol(p: Parser; at: int): (int, int) =
  var lo = 0
  var hi = p.lineStarts.high
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if p.lineStarts[mid] <= at: lo = mid else: hi = mid - 1
  (lo + 1, at - p.lineStarts[lo] + 1)

proc fail(p: Parser; at: int; msg: string) {.noreturn.} =
  let (l, c) = p.lineCol(at)
  var e = newException(YamlError, $l & ":" & $c & ": " & msg)
  e.line = l
  e.col = c
  raise e

proc node(p: Parser; at: int; kind: YKind): YNode =
  let (l, c) = p.lineCol(at)
  case kind
  of yNull: YNode(kind: yNull, line: l, col: c)
  of ySeq: YNode(kind: ySeq, line: l, col: c)
  of yMap: YNode(kind: yMap, line: l, col: c)
  else: raise newException(Defect, "node(): scalar kinds are built by resolve")

proc eof(p: Parser): bool {.inline.} = p.pos >= p.src.len
proc cur(p: Parser): char {.inline.} = (if p.pos < p.src.len: p.src[p.pos] else: '\0')
proc peekAt(p: Parser; k: int): char {.inline.} =
  (if p.pos + k < p.src.len: p.src[p.pos + k] else: '\0')

proc isBreak(c: char): bool {.inline.} = c in {'\n', '\r', '\0'}
proc isBlank(c: char): bool {.inline.} = c in {' ', '\t'}
proc isBlankOrBreak(c: char): bool {.inline.} = c.isBlank or c.isBreak

const flowIndicators = {',', '[', ']', '{', '}'}

proc colOf(p: Parser; at: int): int = p.lineCol(at)[1] - 1  ## 0-based column

proc skipToLineEnd(p: var Parser) =
  while not p.eof and not p.cur.isBreak: inc p.pos

proc skipBreak(p: var Parser) =
  if p.cur == '\r': inc p.pos
  if p.cur == '\n': inc p.pos

proc skipInlineSpace(p: var Parser) =
  ## Spaces (and tabs, which are allowed as separation inside a line).
  while p.cur.isBlank: inc p.pos

proc atComment(p: Parser): bool =
  p.cur == '#' and (p.pos == 0 or p.src[p.pos - 1].isBlankOrBreak)

proc skipBlankLines(p: var Parser) =
  ## Advance past empty lines and comment lines, leaving `pos` at the first
  ## content character of the next content line (or at EOF). Tabs at the start
  ## of a content line are an error (YAML forbids them as indentation).
  while not p.eof:
    let lineStart = p.pos
    var q = p.pos
    while q < p.src.len and p.src[q] == ' ': inc q
    if q < p.src.len and p.src[q] == '\t':
      var r = q
      while r < p.src.len and p.src[r].isBlank: inc r
      if r < p.src.len and not p.src[r].isBreak and p.src[r] != '#':
        p.fail(q, "a tab is used for indentation; YAML allows only spaces")
      q = r
    p.pos = q
    if p.eof: return
    if p.cur.isBreak:
      p.skipBreak()
      continue
    if p.cur == '#':
      p.skipToLineEnd()
      p.skipBreak()
      continue
    discard lineStart
    return

proc skipTrailing(p: var Parser) =
  ## After a value on a line: spaces, an optional comment, the line break.
  p.skipInlineSpace()
  if p.atComment: p.skipToLineEnd()
  if not p.eof and not p.cur.isBreak:
    p.fail(p.pos, "unexpected content after a value: '" & $p.cur & "'")

proc refuseUnsupported(p: Parser) =
  case p.cur
  of '&': p.fail(p.pos, "anchors (&) are not supported in scenario files")
  of '*': p.fail(p.pos, "aliases (*) are not supported in scenario files")
  of '!': p.fail(p.pos, "tags (!) are not supported in scenario files")
  of '%': p.fail(p.pos, "directives (%) are not supported in scenario files")
  of '?':
    if p.peekAt(1).isBlankOrBreak:
      p.fail(p.pos, "explicit keys (?) are not supported in scenario files")
  of '@', '`': p.fail(p.pos, "'" & $p.cur & "' is reserved and cannot start a plain scalar")
  else: discard

# --- scalar resolution ------------------------------------------------------

proc isDecInt(s: string): bool =
  var k = 0
  if k < s.len and s[k] in {'-', '+'}: inc k
  if k >= s.len: return false
  for j in k ..< s.len:
    if s[j] notin Digits: return false
  true

proc isFloatLit(s: string): bool =
  var k = 0
  if k < s.len and s[k] in {'-', '+'}: inc k
  var digits = 0
  while k < s.len and s[k] in Digits: inc k; inc digits
  var frac = false
  if k < s.len and s[k] == '.':
    frac = true
    inc k
    while k < s.len and s[k] in Digits: inc k; inc digits
  if digits == 0: return false
  var expo = false
  if k < s.len and s[k] in {'e', 'E'}:
    expo = true
    inc k
    if k < s.len and s[k] in {'-', '+'}: inc k
    var ed = 0
    while k < s.len and s[k] in Digits: inc k; inc ed
    if ed == 0: return false
  k == s.len and (frac or expo)

proc resolvePlain(p: Parser; at: int; text: string): YNode =
  let (l, c) = p.lineCol(at)
  case text
  of "", "~", "null", "Null", "NULL":
    return YNode(kind: yNull, line: l, col: c)
  of "true", "True", "TRUE":
    return YNode(kind: yBool, b: true, line: l, col: c)
  of "false", "False", "FALSE":
    return YNode(kind: yBool, b: false, line: l, col: c)
  of ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF":
    return YNode(kind: yFloat, f: Inf, line: l, col: c)
  of "-.inf", "-.Inf", "-.INF":
    return YNode(kind: yFloat, f: NegInf, line: l, col: c)
  of ".nan", ".NaN", ".NAN":
    return YNode(kind: yFloat, f: NaN, line: l, col: c)
  else: discard
  try:
    if text.isDecInt:
      return YNode(kind: yInt, i: parseBiggestInt(text), line: l, col: c)
    if text.len > 2 and text.startsWith("0x") and text[2..^1].allCharsInSet(HexDigits):
      return YNode(kind: yInt, i: fromHex[BiggestInt](text), line: l, col: c)
    if text.len > 2 and text.startsWith("0o") and text[2..^1].allCharsInSet({'0'..'7'}):
      return YNode(kind: yInt, i: fromOct[BiggestInt](text), line: l, col: c)
    if text.isFloatLit:
      return YNode(kind: yFloat, f: parseFloat(text), line: l, col: c)
  except ValueError:
    p.fail(at, "number out of range: " & text)
  YNode(kind: yString, s: text, line: l, col: c)

proc strNode(p: Parser; at: int; text: string; quoted: bool): YNode =
  let (l, c) = p.lineCol(at)
  YNode(kind: yString, s: text, quoted: quoted, line: l, col: c)

# --- quoted scalars ---------------------------------------------------------

proc foldQuotedBreak(p: var Parser; buf: var string) =
  ## Inside a quoted scalar at a line break: trailing spaces before it are
  ## dropped by the caller; a single break folds to a space, N>1 breaks to N-1
  ## newlines; leading spaces of the continuation line are dropped.
  var breaks = 0
  while not p.eof and (p.cur.isBreak or p.cur.isBlank):
    if p.cur.isBreak:
      inc breaks
      p.skipBreak()
    else:
      inc p.pos
  if breaks <= 1: buf.add ' '
  else:
    for _ in 1 ..< breaks: buf.add '\n'

proc trimTrailingBlanks(buf: var string) =
  while buf.len > 0 and buf[^1] in {' ', '\t'}: buf.setLen(buf.len - 1)

proc parseSingleQuoted(p: var Parser): YNode =
  let start = p.pos
  inc p.pos
  var buf = ""
  while true:
    if p.eof: p.fail(start, "unterminated single-quoted scalar")
    let c = p.cur
    if c == '\'':
      if p.peekAt(1) == '\'':
        buf.add '\''
        p.pos += 2
      else:
        inc p.pos
        break
    elif c.isBreak:
      buf.trimTrailingBlanks()
      p.foldQuotedBreak(buf)
    else:
      buf.add c
      inc p.pos
  p.strNode(start, buf, true)

proc parseDoubleQuoted(p: var Parser): YNode =
  let start = p.pos
  inc p.pos
  var buf = ""
  while true:
    if p.eof: p.fail(start, "unterminated double-quoted scalar")
    let c = p.cur
    if c == '"':
      inc p.pos
      break
    elif c == '\\':
      let e = p.peekAt(1)
      p.pos += 2
      case e
      of '0': buf.add '\0'
      of 'a': buf.add '\a'
      of 'b': buf.add '\b'
      of 't', '\t': buf.add '\t'
      of 'n': buf.add '\n'
      of 'v': buf.add '\v'
      of 'f': buf.add '\f'
      of 'r': buf.add '\r'
      of 'e': buf.add '\e'
      of ' ': buf.add ' '
      of '"': buf.add '"'
      of '/': buf.add '/'
      of '\\': buf.add '\\'
      of 'N': buf.add "\u0085"
      of '_': buf.add " "
      of 'L': buf.add " "
      of 'P': buf.add " "
      of 'x', 'u', 'U':
        let n = (if e == 'x': 2 elif e == 'u': 4 else: 8)
        if p.pos + n > p.src.len: p.fail(p.pos - 2, "truncated escape")
        let hex = p.src[p.pos ..< p.pos + n]
        if not hex.allCharsInSet(HexDigits): p.fail(p.pos - 2, "bad escape \\" & e & hex)
        let code = fromHex[int](hex)
        if code > 0x10FFFF: p.fail(p.pos - 2, "escape beyond Unicode: \\" & e & hex)
        buf.add toUTF8(Rune(code))
        p.pos += n
      of '\n', '\r':
        # escaped line break: join without a space
        dec p.pos
        p.skipBreak()
        while p.cur.isBlank: inc p.pos
      else:
        p.fail(p.pos - 2, "unknown escape \\" & e)
    elif c.isBreak:
      buf.trimTrailingBlanks()
      p.foldQuotedBreak(buf)
    else:
      buf.add c
      inc p.pos
  p.strNode(start, buf, true)

# --- plain scalars ----------------------------------------------------------

proc plainEndsHere(p: Parser; inFlow: bool): bool =
  let c = p.cur
  if c.isBreak: return true
  if c == ':' and (p.peekAt(1).isBlankOrBreak or (inFlow and p.peekAt(1) in flowIndicators)):
    return true
  if c == '#' and p.pos > 0 and p.src[p.pos - 1].isBlank: return true
  if inFlow and c in flowIndicators: return true
  false

proc readPlainLine(p: var Parser; inFlow: bool): string =
  let s = p.pos
  while not p.eof and not p.plainEndsHere(inFlow): inc p.pos
  result = p.src[s ..< p.pos]
  result.trimTrailingBlanks()

proc parsePlain(p: var Parser; inFlow: bool; minIndent: int): YNode =
  ## A plain scalar. In block context it may continue on following lines that
  ## are indented more than `minIndent` and do not start a comment; in flow
  ## context on any following line. Lines fold with a single space.
  let start = p.pos
  p.refuseUnsupported()
  let c0 = p.cur
  if c0 in {'-', '?', ':'} and p.peekAt(1).isBlankOrBreak:
    p.fail(p.pos, "a plain scalar cannot start with '" & $c0 & " '")
  if c0 in flowIndicators or c0 in {'#', '|', '>', '\'', '"'}:
    p.fail(p.pos, "a plain scalar cannot start with '" & $c0 & "'")
  var text = p.readPlainLine(inFlow)
  while true:
    # continuation?
    if not p.cur.isBreak: break
    let save = p.pos
    var q = p.pos
    var breaks = 0
    var contCol = 0
    while q < p.src.len:
      if p.src[q] == '\r': inc q
      if q < p.src.len and p.src[q] == '\n':
        inc q
        inc breaks
        contCol = 0
        while q < p.src.len and p.src[q].isBlank: inc q; inc contCol
        if q < p.src.len and p.src[q] in {'\n', '\r'}: continue
      break
    if q >= p.src.len or p.src[q] == '#':
      p.pos = save
      break
    if not inFlow and contCol <= minIndent:
      p.pos = save
      break
    # a continuation must not look like a mapping key or a document marker
    p.pos = q
    if (p.src.continuesWith("---", q) or p.src.continuesWith("...", q)) and contCol == 0:
      p.pos = save
      break
    if not inFlow:
      var r = q
      var looksLikeKey = false
      while r < p.src.len and not p.src[r].isBreak:
        if p.src[r] == ':' and (r + 1 >= p.src.len or p.src[r + 1].isBlankOrBreak):
          looksLikeKey = true
          break
        if p.src[r] == '#' and p.src[r - 1].isBlank: break
        inc r
      if looksLikeKey or (p.src[q] == '-' and (q + 1 >= p.src.len or p.src[q + 1].isBlankOrBreak)):
        p.pos = save
        break
    elif p.cur in flowIndicators or (p.cur == ':' and p.peekAt(1).isBlankOrBreak):
      break
    let more = p.readPlainLine(inFlow)
    if more.len == 0:
      p.pos = save
      break
    if breaks <= 1: text.add ' '
    else:
      for _ in 1 ..< breaks: text.add '\n'
    text.add more
  p.resolvePlain(start, text)

# --- block scalars ----------------------------------------------------------

proc parseBlockScalar(p: var Parser; parentIndent: int): YNode =
  let start = p.pos
  let literal = p.cur == '|'
  inc p.pos
  var chomp = 'c'   # c = clip, s = strip, k = keep
  var explicitIndent = 0
  for _ in 0 .. 1:
    if p.cur in {'-', '+'}:
      chomp = (if p.cur == '-': 's' else: 'k')
      inc p.pos
    elif p.cur in {'1'..'9'}:
      explicitIndent = ord(p.cur) - ord('0')
      inc p.pos
  p.skipTrailing()
  p.skipBreak()
  # collect lines
  var lines: seq[string]
  var indent = (if explicitIndent > 0: parentIndent + explicitIndent else: -1)
  while not p.eof:
    let ls = p.pos
    var q = ls
    while q < p.src.len and p.src[q] == ' ': inc q
    let ind = q - ls
    let blank = q >= p.src.len or p.src[q].isBreak
    if blank:
      lines.add ""
      p.pos = q
      if p.eof: break
      p.skipBreak()
      continue
    if indent < 0:
      if ind <= parentIndent: break
      indent = ind
    if ind < indent:
      break
    p.pos = ls + indent
    let s = p.pos
    p.skipToLineEnd()
    lines.add p.src[s ..< p.pos]
    if not p.eof: p.skipBreak()
  # the trailing blank lines belong to chomping
  var trailing = 0
  while lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
    inc trailing
  # rewind past trailing blank lines so the caller sees the next content line
  var body = ""
  if literal:
    body = lines.join("\n")
  else:
    var k = 0
    while k < lines.len:
      let l = lines[k]
      if k > 0:
        let prev = lines[k - 1]
        if l.len == 0: body.add '\n'
        elif prev.len == 0 or prev[0] == ' ' or l[0] == ' ': body.add '\n'
        else: body.add ' '
      body.add l
      inc k
  if lines.len > 0:
    case chomp
    of 'c': body.add '\n'
    of 'k':
      body.add '\n'
      for _ in 0 ..< trailing: body.add '\n'
    else: discard
  p.strNode(start, body, true)

# --- flow collections ---------------------------------------------------------

proc skipFlowSpace(p: var Parser) =
  while not p.eof:
    if p.cur.isBlank or p.cur.isBreak: inc p.pos
    elif p.atComment: p.skipToLineEnd()
    else: break

proc parseFlowNode(p: var Parser): YNode

proc keyString(p: Parser; k: YNode): YNode =
  case k.kind
  of yString: k
  of yNull: YNode(kind: yString, s: "", line: k.line, col: k.col)
  of yBool: YNode(kind: yString, s: $k.b, line: k.line, col: k.col)
  of yInt: YNode(kind: yString, s: $k.i, line: k.line, col: k.col)
  of yFloat: YNode(kind: yString, s: $k.f, line: k.line, col: k.col)
  else:
    var e = newException(YamlError, $k.line & ":" & $k.col & ": a mapping key must be a scalar")
    e.line = k.line
    e.col = k.col
    raise e

proc addPair(p: Parser; m: YNode; k, v: YNode; at: int) =
  let ks = p.keyString(k)
  for existing in m.keys:
    if existing.s == ks.s:
      var e = newException(YamlError, $ks.line & ":" & $ks.col &
        ": duplicate mapping key '" & ks.s & "' (first at line " & $existing.line & ")")
      e.line = ks.line
      e.col = ks.col
      raise e
  m.keys.add ks
  m.values.add v

proc parseFlowScalarOrNode(p: var Parser): YNode =
  case p.cur
  of '[', '{': p.parseFlowNode()
  of '"': p.parseDoubleQuoted()
  of '\'': p.parseSingleQuoted()
  else: p.parsePlain(inFlow = true, minIndent = -1)

proc parseFlowNode(p: var Parser): YNode =
  let start = p.pos
  if p.cur == '[':
    result = p.node(start, ySeq)
    inc p.pos
    while true:
      p.skipFlowSpace()
      if p.eof: p.fail(start, "unterminated flow sequence")
      if p.cur == ']':
        inc p.pos
        break
      let item = p.parseFlowScalarOrNode()
      p.skipFlowSpace()
      if p.cur == ':':
        p.fail(p.pos, "single-pair mappings inside a flow sequence are not supported; use { key: value }")
      result.items.add item
      if p.cur == ',':
        inc p.pos
      elif p.cur != ']':
        p.fail(p.pos, "expected ',' or ']' in a flow sequence")
  elif p.cur == '{':
    result = p.node(start, yMap)
    inc p.pos
    while true:
      p.skipFlowSpace()
      if p.eof: p.fail(start, "unterminated flow mapping")
      if p.cur == '}':
        inc p.pos
        break
      let kat = p.pos
      if p.cur in {'[', '{'}: p.fail(p.pos, "a mapping key must be a scalar")
      let k = p.parseFlowScalarOrNode()
      p.skipFlowSpace()
      var v: YNode
      if p.cur == ':':
        inc p.pos
        p.skipFlowSpace()
        if p.cur in {',', '}'}:
          v = p.node(p.pos, yNull)
        else:
          v = p.parseFlowScalarOrNode()
        p.skipFlowSpace()
      else:
        v = p.node(p.pos, yNull)
      p.addPair(result, k, v, kat)
      if p.cur == ',':
        inc p.pos
      elif p.cur != '}':
        if p.cur in {']', '['}:
          p.fail(p.pos, "'" & $p.cur & "' inside a flow mapping; a locator inside { … } must be quoted")
        p.fail(p.pos, "expected ',' or '}' in a flow mapping")
  else:
    p.fail(p.pos, "expected a flow collection")

# --- block structure ----------------------------------------------------------

proc looksLikeBlockKey(p: Parser): bool =
  ## Whether the content at `pos` is `key:` followed by a blank, a break or EOF.
  var q = p.pos
  if q >= p.src.len: return false
  let c = p.src[q]
  if c == '"' or c == '\'':
    # skip the quoted scalar
    inc q
    while q < p.src.len:
      if p.src[q] == c:
        if c == '\'' and q + 1 < p.src.len and p.src[q + 1] == '\'':
          q += 2
          continue
        break
      if c == '"' and p.src[q] == '\\': inc q
      if p.src[q].isBreak: return false
      inc q
    inc q
    while q < p.src.len and p.src[q].isBlank: inc q
    return q < p.src.len and p.src[q] == ':' and
      (q + 1 >= p.src.len or p.src[q + 1].isBlankOrBreak)
  if c in flowIndicators or c in {'#', '|', '>'}: return false
  if c == '-' and (q + 1 >= p.src.len or p.src[q + 1].isBlankOrBreak): return false
  while q < p.src.len and not p.src[q].isBreak:
    if p.src[q] == ':' and (q + 1 >= p.src.len or p.src[q + 1].isBlankOrBreak):
      return true
    if p.src[q] == '#' and q > 0 and p.src[q - 1].isBlank: return false
    inc q
  false

proc isSeqEntry(p: Parser): bool =
  p.cur == '-' and p.peekAt(1).isBlankOrBreak

proc parseBlockNode(p: var Parser; parentIndent: int): YNode
proc parseBlockMapping(p: var Parser; indent: int): YNode
proc parseBlockSequence(p: var Parser; indent: int): YNode

proc parseInlineValue(p: var Parser; parentIndent: int): YNode =
  ## A value that starts on the current line (after `key: ` or `- `).
  p.refuseUnsupported()
  case p.cur
  of '|', '>':
    result = p.parseBlockScalar(parentIndent)
    return
  of '[', '{':
    result = p.parseFlowNode()
  of '"':
    result = p.parseDoubleQuoted()
  of '\'':
    result = p.parseSingleQuoted()
  else:
    result = p.parsePlain(inFlow = false, minIndent = parentIndent)
  p.skipTrailing()

proc parseValueAfterIndicator(p: var Parser; indent: int; allowSameIndentSeq: bool): YNode =
  ## Called after `key:` or `- `, with `pos` on the rest of the line.
  p.skipInlineSpace()
  if p.atComment: p.skipToLineEnd()
  if p.eof or p.cur.isBreak:
    let at = p.pos
    p.skipBlankLines()
    if p.eof: return p.node(at, yNull)
    let c = p.colOf(p.pos)
    if c > indent: return p.parseBlockNode(indent)
    if c == indent and allowSameIndentSeq and p.isSeqEntry:
      return p.parseBlockSequence(indent)
    return p.node(at, yNull)
  p.parseInlineValue(indent)

proc atDocumentMarker(p: Parser): bool =
  p.colOf(p.pos) == 0 and (p.src.continuesWith("---", p.pos) or
    p.src.continuesWith("...", p.pos)) and p.peekAt(3).isBlankOrBreak

proc parseBlockMapping(p: var Parser; indent: int): YNode =
  result = p.node(p.pos, yMap)
  while true:
    let kat = p.pos
    p.refuseUnsupported()
    if not p.looksLikeBlockKey:
      p.refuseUnsupported()
      p.fail(p.pos, "expected 'key: value' in a mapping")
    var k: YNode
    case p.cur
    of '"': k = p.parseDoubleQuoted()
    of '\'': k = p.parseSingleQuoted()
    else:
      let s = p.pos
      while not (p.cur == ':' and p.peekAt(1).isBlankOrBreak): inc p.pos
      var t = p.src[s ..< p.pos]
      t.trimTrailingBlanks()
      k = p.resolvePlain(s, t)
    p.skipInlineSpace()
    if p.cur != ':': p.fail(p.pos, "expected ':' after a mapping key")
    inc p.pos
    let v = p.parseValueAfterIndicator(indent, allowSameIndentSeq = true)
    p.addPair(result, k, v, kat)
    p.skipBlankLines()
    if p.eof: break
    let c = p.colOf(p.pos)
    if c < indent: break
    if c > indent: p.fail(p.pos, "bad indentation: expected column " & $(indent + 1))
    if p.isSeqEntry: break  # a sibling sequence belongs to the parent key
    if p.atDocumentMarker: break

proc parseBlockSequence(p: var Parser; indent: int): YNode =
  result = p.node(p.pos, ySeq)
  while true:
    if not p.isSeqEntry: p.fail(p.pos, "expected '- ' in a sequence")
    inc p.pos  # '-'
    p.skipInlineSpace()
    p.refuseUnsupported()
    if p.atComment or p.eof or p.cur.isBreak:
      result.items.add p.parseValueAfterIndicator(indent, allowSameIndentSeq = false)
    else:
      let c = p.colOf(p.pos)
      if p.isSeqEntry:
        result.items.add p.parseBlockSequence(c)
      elif p.looksLikeBlockKey:
        result.items.add p.parseBlockMapping(c)
      else:
        result.items.add p.parseInlineValue(indent)
    p.skipBlankLines()
    if p.eof: break
    let c = p.colOf(p.pos)
    if c < indent: break
    if c > indent: p.fail(p.pos, "bad indentation: expected column " & $(indent + 1))
    if p.atDocumentMarker or not p.isSeqEntry: break

proc parseBlockNode(p: var Parser; parentIndent: int): YNode =
  ## At the first content character of a line indented more than parentIndent.
  p.refuseUnsupported()
  let c = p.colOf(p.pos)
  if p.isSeqEntry: return p.parseBlockSequence(c)
  if p.cur notin {'[', '{', '|', '>'} and p.looksLikeBlockKey: return p.parseBlockMapping(c)
  if p.cur in {'|', '>'}: return p.parseBlockScalar(parentIndent)
  result = p.parseInlineValue(parentIndent)

proc readYaml*(text: string): YNode =
  ## Reads one YAML document. Raises `YamlError` with a line and column.
  var p = Parser(src: text)
  p.lineStarts = @[0]
  for k, ch in text:
    if ch == '\n': p.lineStarts.add k + 1
  if text.len >= 3 and text.startsWith("\xEF\xBB\xBF"): p.pos = 3
  p.skipBlankLines()
  if p.src.continuesWith("---", p.pos) and p.colOf(p.pos) == 0 and p.peekAt(3).isBlankOrBreak:
    p.pos += 3
    p.skipInlineSpace()
    if p.atComment: p.skipToLineEnd()
    p.skipBlankLines()
  if p.eof:
    return p.node(p.pos, yNull)
  if p.cur == '%': p.refuseUnsupported()
  result = p.parseBlockNode(-1)
  p.skipBlankLines()
  if not p.eof:
    if p.src.continuesWith("...", p.pos) and p.colOf(p.pos) == 0:
      p.pos += 3
      p.skipBlankLines()
      if not p.eof: p.fail(p.pos, "content after the end of the document")
    elif p.src.continuesWith("---", p.pos) and p.colOf(p.pos) == 0:
      p.fail(p.pos, "several documents in one file are not supported")
    else:
      p.fail(p.pos, "unexpected content (check the indentation)")

proc readYamlFile*(path: string): YNode = readYaml(readFile(path))

# --- conversion and access ------------------------------------------------------

proc toJson*(n: YNode): JsonNode =
  case n.kind
  of yNull: newJNull()
  of yBool: newJBool(n.b)
  of yInt: newJInt(n.i)
  of yFloat: newJFloat(n.f)
  of yString: newJString(n.s)
  of ySeq:
    var a = newJArray()
    for it in n.items: a.add it.toJson
    a
  of yMap:
    var o = newJObject()
    for k in 0 ..< n.keys.len: o[n.keys[k].s] = n.values[k].toJson
    o

proc get*(n: YNode; key: string): YNode =
  ## The value for `key` in a mapping, or nil.
  if n == nil or n.kind != yMap: return nil
  for k in 0 ..< n.keys.len:
    if n.keys[k].s == key: return n.values[k]
  nil

proc keyNode*(n: YNode; key: string): YNode =
  if n == nil or n.kind != yMap: return nil
  for k in n.keys:
    if k.s == key: return k
  nil

proc has*(n: YNode; key: string): bool = n.get(key) != nil

iterator pairs*(n: YNode): (YNode, YNode) =
  if n != nil and n.kind == yMap:
    for k in 0 ..< n.keys.len: yield (n.keys[k], n.values[k])

proc kindName*(n: YNode): string =
  if n == nil: return "nothing"
  case n.kind
  of yNull: "null"
  of yBool: "a boolean"
  of yInt: "an integer"
  of yFloat: "a number"
  of yString: "a string"
  of ySeq: "a sequence"
  of yMap: "a mapping"

proc scalarText*(n: YNode): string =
  ## The source-level text of a scalar (numbers and booleans rendered back).
  case n.kind
  of yString: n.s
  of yInt: $n.i
  of yFloat: $n.f
  of yBool: $n.b
  of yNull: ""
  else: ""

proc fromJson*(j: JsonNode): YNode =
  ## A YNode with no source positions (line 0), for documents built in code.
  case j.kind
  of JNull: YNode(kind: yNull)
  of JBool: YNode(kind: yBool, b: j.bval)
  of JInt: YNode(kind: yInt, i: j.num)
  of JFloat: YNode(kind: yFloat, f: j.fnum)
  of JString: YNode(kind: yString, s: j.str)
  of JArray:
    var r = YNode(kind: ySeq)
    for it in j: r.items.add fromJson(it)
    r
  of JObject:
    var r = YNode(kind: yMap)
    for k, v in j: (r.keys.add YNode(kind: yString, s: k); r.values.add fromJson(v))
    r

