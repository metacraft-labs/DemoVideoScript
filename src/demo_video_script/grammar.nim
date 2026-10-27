## The small grammars inside scenario strings: names, key names and chords,
## durations, locators, assertion invocations, anchors and signatures.
##
## Each parser here accepts exactly the language of the corresponding regular
## expression in the published JSON Schemas (`tools/generate_schemas.py`), so
## the schema and the parser agree on every string; `tests/schema_agreement.py`
## checks it over the corpus.

import std/[strutils, unicode]

type
  GrammarError* = object of CatchableError

  Modifier* = enum
    modCtrl = "Ctrl", modShift = "Shift", modAlt = "Alt", modMeta = "Meta", modMod = "Mod"

  Chord* = object
    modifiers*: set[Modifier]
    key*: string            ## a canonical named key, or one character

  Platform* = enum
    platLinux = "linux", platMacos = "macos", platWindows = "windows"

  SegmentKind* = enum
    segRole, segFocused, segAncestor

  KeyValue* = tuple[key, value: string]

  Segment* = object
    kind*: SegmentKind
    role*: string           ## segRole: the role; segAncestor: the ancestor role
    keys*: seq[KeyValue]    ## semantic keys, in written order
    ordinal*: int           ## [#n]; 0 when absent

  Locator* = object
    segments*: seq[Segment]

  ArgKind* = enum
    argString, argNumber, argWord

  Arg* = object
    kind*: ArgKind
    text*: string           ## the string's value, the number's text, or the word

  Invocation* = object
    name*: string
    args*: seq[Arg]
    hasParens*: bool

  Signature* = object
    name*: string
    params*: seq[string]

const
  NamedKeys* = ["Enter", "Esc", "Tab", "Backspace", "Delete", "Insert", "Home", "End",
                "PageUp", "PageDown", "Up", "Down", "Left", "Right", "Space", "Plus",
                "Ctrl", "Shift", "Alt", "Meta", "Mod",
                "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
                "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22",
                "F23", "F24"]

proc gfail(msg: string) {.noreturn.} =
  raise newException(GrammarError, msg)

# --- names ---------------------------------------------------------------------

proc isName*(s: string): bool =
  ## `[a-z][a-z0-9-]*`
  if s.len == 0 or s[0] notin {'a'..'z'}: return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc isScenarioName*(s: string): bool =
  ## `[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)*`
  if s.len == 0: return false
  for part in s.split('/'):
    if part.len == 0 or part[0] notin {'a'..'z', '0'..'9'}: return false
    for c in part:
      if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc isDottedName*(s: string): bool =
  ## `NAME(\.NAME)*` — sync conditions and bound operations.
  if s.len == 0: return false
  for part in s.split('.'):
    if not part.isName: return false
  true

proc isExtName*(s: string): bool =
  ## `NAME\.NAME(\.NAME)*` — an extension step: backend, then the step.
  s.isDottedName and s.count('.') >= 1

# --- keys and chords ---------------------------------------------------------------

proc isSingleKeyChar*(s: string): bool =
  ## One code point that is not ASCII space or control, DEL, or '+'.
  if s.len == 0 or s.runeLen != 1: return false
  let r = s.runeAt(0).int
  not (r <= 0x20 or r == 0x7f or r == ord('+'))

proc isKeyName*(s: string): bool =
  s in NamedKeys or s.isSingleKeyChar

proc parseModifier(s: string): Modifier =
  case s
  of "Ctrl": modCtrl
  of "Shift": modShift
  of "Alt": modAlt
  of "Meta": modMeta
  of "Mod": modMod
  else: gfail("unknown modifier '" & s & "' (Ctrl, Shift, Alt, Meta, Mod)")

proc parseChord*(s: string): Chord =
  ## `(MOD\+)*KEY`. A '+' key is spelled `Plus`.
  if s.len == 0: gfail("empty chord")
  let parts = s.split('+')
  for k in 0 ..< parts.high:
    result.modifiers.incl parseModifier(parts[k])
  let key = parts[^1]
  if not key.isKeyName:
    gfail("unknown key '" & key & "' in '" & s & "' (named keys: " & NamedKeys.join(", ") &
      ", or one character; '+' is spelled Plus)")
  result.key = key

proc parseChordSequence*(s: string): seq[Chord] =
  ## Chords separated by single spaces: `Ctrl+K Ctrl+C`.
  if s.len == 0: gfail("empty chord sequence")
  for part in s.split(' '):
    if part.len == 0: gfail("chords are separated by one space: '" & s & "'")
    result.add parseChord(part)

proc parseKey*(s: string): string =
  if not s.isKeyName:
    if '+' in s and s.len > 1:
      gfail("'" & s & "' is a chord; a key step sends one key — use chord:")
    gfail("unknown key '" & s & "' (named keys: " & NamedKeys.join(", ") & ", or one character)")
  s

proc `$`*(c: Chord): string =
  for m in Modifier:
    if m in c.modifiers: result.add $m & "+"
  result.add c.key

proc `$`*(cs: seq[Chord]): string =
  for k, c in cs:
    if k > 0: result.add ' '
    result.add $c

proc resolveMod*(c: Chord; platform: Platform): Chord =
  ## `Mod` is the platform's primary modifier: Meta on macOS, Ctrl elsewhere.
  result = c
  if modMod in c.modifiers:
    result.modifiers.excl modMod
    result.modifiers.incl (if platform == platMacos: modMeta else: modCtrl)

# --- durations -----------------------------------------------------------------

proc parseDurationText*(s: string): int64 =
  ## `[0-9]+(\.[0-9]+)?(ms|s|m)` → milliseconds (rounded to the nearest).
  var unitLen = 0
  var factor = 0.0
  if s.endsWith("ms"): (unitLen = 2; factor = 1.0)
  elif s.endsWith("s"): (unitLen = 1; factor = 1000.0)
  elif s.endsWith("m"): (unitLen = 1; factor = 60_000.0)
  else: gfail("a duration ends in ms, s or m: '" & s & "'")
  let num = s[0 ..< s.len - unitLen]
  if num.len == 0 or num[0] notin Digits or num[^1] notin Digits:
    gfail("bad duration '" & s & "'")
  var dots = 0
  for c in num:
    if c == '.': inc dots
    elif c notin Digits: gfail("bad duration '" & s & "'")
  if dots > 1: gfail("bad duration '" & s & "'")
  int64(parseFloat(num) * factor + 0.5)

proc formatDuration*(ms: int64): string =
  if ms mod 1000 == 0: $(ms div 1000) & "s"
  else: $ms & "ms"

# --- quoted strings inside locators and invocations -----------------------------

proc readQuoted(s: string; i: var int): string =
  ## `"([^"\\]|\\.)*"` — the escape keeps the next character verbatim.
  if i >= s.len or s[i] != '"': gfail("expected '\"' at " & $(i + 1) & " in '" & s & "'")
  inc i
  while true:
    if i >= s.len: gfail("unterminated string in '" & s & "'")
    let c = s[i]
    if c == '"':
      inc i
      return
    if c == '\\':
      if i + 1 >= s.len: gfail("unterminated string in '" & s & "'")
      result.add s[i + 1]
      i += 2
    else:
      result.add c
      inc i

proc readName(s: string; i: var int): string =
  let st = i
  if i >= s.len or s[i] notin {'a'..'z'}:
    gfail("expected a name at " & $(i + 1) & " in '" & s & "'")
  while i < s.len and s[i] in {'a'..'z', '0'..'9', '-'}: inc i
  s[st ..< i]

proc quote*(v: string): string =
  result = "\""
  for c in v:
    if c in {'"', '\\'}: result.add '\\'
    result.add c
  result.add '"'

# --- locators -------------------------------------------------------------------

proc parseLocator*(s: string): Locator =
  ## `(focused|SEG)(/(ancestor\(NAME\)|SEG))*`, `SEG = NAME(\[SEL\])?`,
  ## `SEL = #n | NAME="…"(, *NAME="…")*`. No coordinates, no backend selectors.
  if s.len == 0: gfail("empty locator")
  var i = 0
  var first = true
  while true:
    var seg: Segment
    if first and s.continuesWith("focused", i) and
        (i + 7 == s.len or s[i + 7] == '/'):
      seg = Segment(kind: segFocused)
      i += 7
    elif not first and s.continuesWith("ancestor(", i):
      i += 9
      seg = Segment(kind: segAncestor, role: readName(s, i))
      if i >= s.len or s[i] != ')': gfail("expected ')' in '" & s & "'")
      inc i
    else:
      seg = Segment(kind: segRole, role: readName(s, i))
      if i < s.len and s[i] == '[':
        inc i
        if i < s.len and s[i] == '#':
          inc i
          let st = i
          if i >= s.len or s[i] notin {'1'..'9'}:
            gfail("an ordinal is [#n] with n >= 1, in '" & s & "'")
          while i < s.len and s[i] in Digits: inc i
          seg.ordinal = parseInt(s[st ..< i])
        else:
          while true:
            let k = readName(s, i)
            if i >= s.len or s[i] != '=': gfail("expected '=' after key '" & k & "' in '" & s & "'")
            inc i
            let v = readQuoted(s, i)
            seg.keys.add (k, v)
            if i < s.len and s[i] == ',':
              inc i
              while i < s.len and s[i] == ' ': inc i
              continue
            break
        if i >= s.len or s[i] != ']': gfail("expected ']' in '" & s & "'")
        inc i
    result.segments.add seg
    first = false
    if i == s.len: break
    if s[i] != '/': gfail("unexpected '" & $s[i] & "' at " & $(i + 1) & " in locator '" & s & "'")
    inc i

proc `$`*(seg: Segment): string =
  case seg.kind
  of segFocused: "focused"
  of segAncestor: "ancestor(" & seg.role & ")"
  of segRole:
    var r = seg.role
    if seg.ordinal > 0: r.add "[#" & $seg.ordinal & "]"
    elif seg.keys.len > 0:
      r.add '['
      for k, kv in seg.keys:
        if k > 0: r.add ", "
        r.add kv.key & "=" & quote(kv.value)
      r.add ']'
    r

proc `$`*(l: Locator): string =
  for k, seg in l.segments:
    if k > 0: result.add '/'
    result.add $seg

proc hasOrdinal*(l: Locator): bool =
  for s in l.segments:
    if s.ordinal > 0: return true
  false

# --- invocations, anchors, signatures ----------------------------------------------

proc readArg(s: string; i: var int): Arg =
  if i < s.len and s[i] == '"':
    return Arg(kind: argString, text: readQuoted(s, i))
  let st = i
  if i < s.len and s[i] == '-' and i + 1 < s.len and s[i + 1] in Digits: inc i
  if i < s.len and s[i] in Digits:
    var j = i
    while j < s.len and s[j] in Digits: inc j
    var isNum = true
    if j < s.len and s[j] == '.':
      if j + 1 < s.len and s[j + 1] in Digits:
        inc j
        while j < s.len and s[j] in Digits: inc j
      else: isNum = false
    if isNum and (j == s.len or s[j] in {',', ')', ' '}):
      i = j
      return Arg(kind: argNumber, text: s[st ..< j])
  i = st
  while i < s.len and s[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-'}: inc i
  if i == st: gfail("expected an argument at " & $(i + 1) & " in '" & s & "'")
  Arg(kind: argWord, text: s[st ..< i])

proc parseInvocation*(s: string): Invocation =
  ## `NAME(\((ARG(, *ARG)*)?\))?` — a named assertion or a parameterised anchor.
  var i = 0
  result.name = readName(s, i)
  if i == s.len: return
  if s[i] != '(': gfail("unexpected '" & $s[i] & "' in '" & s & "'")
  result.hasParens = true
  inc i
  if i < s.len and s[i] == ')':
    inc i
  else:
    while true:
      result.args.add readArg(s, i)
      if i < s.len and s[i] == ',':
        inc i
        while i < s.len and s[i] == ' ': inc i
        continue
      if i < s.len and s[i] == ')':
        inc i
        break
      gfail("expected ',' or ')' in '" & s & "'")
  if i != s.len: gfail("unexpected text after ')' in '" & s & "'")

proc parseSignature*(s: string): Signature =
  ## `NAME(\((NAME(, *NAME)*)?\))?` — a declared assertion, flow or anchor.
  var i = 0
  result.name = readName(s, i)
  if i == s.len: return
  if s[i] != '(': gfail("unexpected '" & $s[i] & "' in '" & s & "'")
  inc i
  if i < s.len and s[i] == ')':
    inc i
  else:
    while true:
      result.params.add readName(s, i)
      if i < s.len and s[i] == ',':
        inc i
        while i < s.len and s[i] == ' ': inc i
        continue
      if i < s.len and s[i] == ')':
        inc i
        break
      gfail("expected ',' or ')' in '" & s & "'")
  if i != s.len: gfail("unexpected text after ')' in '" & s & "'")

proc `$`*(a: Arg): string =
  case a.kind
  of argString: quote(a.text)
  of argNumber, argWord: a.text

proc `$`*(inv: Invocation): string =
  result = inv.name
  if inv.hasParens:
    result.add '('
    for k, a in inv.args:
      if k > 0: result.add ", "
      result.add $a
    result.add ')'

proc isTypeName*(s: string): bool =
  ## `text|lines|bool|int|number|record|list<record>|enum{v(,v)*}`
  case s
  of "text", "lines", "bool", "int", "number", "record", "list<record>": return true
  else: discard
  if not (s.startsWith("enum{") and s.endsWith("}")): return false
  let inner = s[5 ..< s.len - 1]
  if inner.len == 0: return false
  for v in inner.split(','):
    if v.len == 0: return false
    for c in v:
      if c notin {'a'..'z', '0'..'9', '-'}: return false
  true
