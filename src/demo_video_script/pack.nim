## Reading a pack's backend-neutral part (role declarations, pack sync
## conditions, flows, stage signatures) into the typed model.
##
## Structural diagnostics are exactly `pack.schema.json`. Semantic ones, rule
## "pack", check what a schema cannot: that the root and every child is a
## declared role, that keys are declared properties, and that every predicate
## parses and names only what the pack declares.

import std/[strutils, tables, sets]
import ./model, ./yaml, ./scenario, ./predicates

const AffordanceNames* = ["click", "double-click", "context-click", "drag-source",
                          "drop-target", "wheel", "text-entry", "focusable"]

proc parsePropType*(s: string): PropType =
  if s.startsWith("enum{"):
    return PropType(kind: ptEnum, values: s[5 ..< s.len - 1].split(','))
  PropType(kind: parseEnum[PropKind](s))

proc `$`*(t: PropType): string =
  if t.kind == ptEnum: "enum{" & t.values.join(",") & "}" else: $t.kind

proc semantic(c: var Ctx; n: YNode; msg: string) =
  c.report(n, "pack", msg, sevError, phSemantic)

proc parseSyncMap(c: var Ctx; n: YNode; what: string): OrderedTable[string, SyncDecl] =
  if n.kind != yMap:
    c.structural(n, what & " must be a mapping of sync condition names")
    return
  for k, v in n.pairs:
    if not k.s.isDottedName:
      c.structural(k, "'" & k.s & "' is not a sync condition name")
      continue
    var d = SyncDecl(name: k.s, line: k.line, col: k.col)
    if v.kind == yString:
      if v.s.len == 0:
        c.structural(v, "a sync predicate is a non-empty string, or ~ when the binding detects it")
        continue
      d.text = v.s
    elif v.kind != yNull:
      c.structural(v, "a sync condition is a predicate string, or ~ when the binding detects it")
      continue
    result[k.s] = d

proc parsePackNode*(root: YNode; file: string): (Pack, Diagnostics) =
  var c = Ctx(file: file)
  let pack = Pack(file: file)
  if root == nil or root.kind != yMap:
    c.structural(root, "a pack file is a mapping (pack, name, root, roles, …)")
    return (pack, c.diags)
  let ver = root.get("pack")
  if ver == nil:
    c.structural(root, "missing 'pack: 1' (the format version)")
  elif not ver.isNumber:
    c.structural(ver, "'pack' is the format version number, found " & ver.kindName)
  elif ver.numValue != 1.0:
    c.report(ver, "version", "pack format version " & ver.scalarText &
      " is not implemented; this parser implements version 1")
    return (pack, c.diags)
  discard c.checkKeys(root, ["pack", "name", "summary", "root", "roles", "sync", "flows", "stages"],
    "a pack")
  for req in ["name", "root", "roles"]:
    if root.get(req) == nil: c.structural(root, "missing '" & req & "'")
  for k, v in root.pairs:
    case k.s
    of "name":
      if v.kind == yString and v.s.isName: pack.name = v.s
      else: c.structural(v, "pack name must be a name ([a-z][a-z0-9-]*)")
    of "summary":
      if v.kind == yString: pack.summary = v.s
      else: c.structural(v, "summary must be a string")
    of "root":
      if v.kind == yString and v.s.isName: pack.root = v.s
      else: c.structural(v, "root must be a role name")
    of "roles":
      if v.kind != yMap or v.keys.len == 0:
        c.structural(v, "roles must be a non-empty mapping of role declarations")
        continue
      for rk, rv in v.pairs:
        if not rk.s.isName:
          c.structural(rk, "role name '" & rk.s & "' is not a name ([a-z][a-z0-9-]*)")
          continue
        let role = Role(name: rk.s, line: rk.line, col: rk.col)
        pack.roles[rk.s] = role
        if rv.kind != yMap:
          c.structural(rv, "role '" & rk.s & "' must be a mapping")
          continue
        discard c.checkKeys(rv, ["keys", "properties", "children", "affordances", "anchors",
                                 "assertions", "sync"], "role '" & rk.s & "'")
        for fk, fv in rv.pairs:
          case fk.s
          of "keys":
            if fv.kind != ySeq:
              c.structural(fv, "keys is a list of property names")
              continue
            for it in fv.items:
              if it.kind != yString or not it.s.isName:
                c.structural(it, "a key is a property name")
              elif it.s in role.keys:
                c.structural(it, "key '" & it.s & "' listed twice")
              else: role.keys.add it.s
          of "properties":
            if fv.kind != yMap:
              c.structural(fv, "properties is a mapping from name to type")
              continue
            for pk, pv in fv.pairs:
              if not pk.s.isName:
                c.structural(pk, "'" & pk.s & "' is not a property name")
              elif pv.kind != yString or not pv.s.isTypeName:
                c.structural(pv, "property '" & pk.s & "': type is text, lines, bool, int, " &
                  "number, record, list<record> or enum{a,b}")
              else:
                role.properties[pk.s] = parsePropType(pv.s)
          of "children":
            if fv.kind != yMap:
              c.structural(fv, "children is a mapping from role to one, optional or many")
              continue
            for ck, cv in fv.pairs:
              if not ck.s.isName:
                c.structural(ck, "'" & ck.s & "' is not a role name")
              elif cv.kind != yString or cv.s notin ["one", "optional", "many"]:
                c.structural(cv, "multiplicity is one, optional or many")
              else:
                role.children[ck.s] = parseEnum[Multiplicity](cv.s)
          of "affordances":
            if fv.kind != ySeq:
              c.structural(fv, "affordances is a list (" & AffordanceNames.join(", ") & ")")
              continue
            for it in fv.items:
              if it.kind != yString or it.s notin AffordanceNames:
                c.structural(it, "unknown affordance (" & AffordanceNames.join(", ") & ")")
              else:
                let a = parseEnum[Affordance](it.s)
                if a in role.affordances: c.structural(it, "affordance '" & it.s & "' listed twice")
                role.affordances.incl a
          of "anchors":
            if fv.kind != ySeq:
              c.structural(fv, "anchors is a list of names or name(params)")
              continue
            var seen: HashSet[string]
            for it in fv.items:
              if it.kind != yString:
                c.structural(it, "an anchor is a name or name(params)")
                continue
              try:
                let sig = parseSignature(it.s)
                if it.s in seen: c.structural(it, "anchor '" & it.s & "' listed twice")
                seen.incl it.s
                role.anchors.add sig
              except GrammarError as e:
                c.structural(it, "anchor: " & e.msg)
          of "assertions":
            if fv.kind != yMap:
              c.structural(fv, "assertions is a mapping from name(params) to a predicate")
              continue
            for ak, av in fv.pairs:
              var sig: Signature
              try: sig = parseSignature(ak.s)
              except GrammarError as e:
                c.structural(ak, "assertion signature: " & e.msg)
                continue
              if av.kind != yString or av.s.len == 0:
                c.structural(av, "an assertion is a predicate string")
                continue
              role.assertions[sig.name] = AssertionDecl(sig: sig, text: av.s,
                                                       line: av.line, col: av.col)
          of "sync":
            role.sync = c.parseSyncMap(fv, "sync of role '" & rk.s & "'")
          else: discard
    of "sync":
      pack.sync = c.parseSyncMap(v, "sync")
    of "flows":
      if v.kind != yMap:
        c.structural(v, "flows is a mapping from name(params) to steps")
        continue
      for fk, fv in v.pairs:
        var sig: Signature
        try: sig = parseSignature(fk.s)
        except GrammarError as e:
          c.structural(fk, "flow signature: " & e.msg)
          continue
        if fv.kind != ySeq:
          c.structural(fv, "a flow is a list of steps")
          continue
        var bad = false
        for it in fv.items:
          if it.kind != yMap:
            c.structural(it, "a flow step must be a mapping")
            bad = true
        if not bad:
          pack.flows[sig.name] = FlowDecl(sig: sig, body: fv, line: fk.line, col: fk.col)
    of "stages":
      if v.kind != yMap:
        c.structural(v, "stages is a mapping from name to { params }")
        continue
      for sk, sv in v.pairs:
        if not sk.s.isName:
          c.structural(sk, "stage name '" & sk.s & "' is not a name")
          continue
        var d = StageDecl(name: sk.s, line: sk.line, col: sk.col)
        if sv.kind == yMap:
          discard c.checkKeys(sv, ["params", "summary"], "stage '" & sk.s & "'")
          let s = sv.get("summary")
          if s != nil and s.kind != yString: c.structural(s, "summary must be a string")
          let ps = sv.get("params")
          if ps != nil:
            if ps.kind != yMap:
              c.structural(ps, "params is a mapping from name to type")
            else:
              for pk, pv in ps.pairs:
                if not pk.s.isName: c.structural(pk, "'" & pk.s & "' is not a parameter name")
                elif pv.kind != yString or not pv.s.isTypeName:
                  c.structural(pv, "parameter '" & pk.s & "': not a type")
                else: d.params[pk.s] = parsePropType(pv.s)
        elif sv.kind != yNull:
          c.structural(sv, "a stage is { params } or ~")
        pack.stages[sk.s] = d
    else: discard
  # --- semantic checks -----------------------------------------------------------
  if not c.diags.hasStructuralErrors:
    if pack.root != "" and not pack.roles.hasKey(pack.root):
      c.semantic(root.get("root"), "root '" & pack.root & "' is not a declared role")
    for role in pack.roles.values:
      for ch in role.children.keys:
        if not pack.roles.hasKey(ch):
          c.report(YNode(kind: yNull, line: role.line, col: role.col), "pack",
            "role '" & role.name & "' has child '" & ch & "', which is not a declared role",
            sevError, phSemantic)
      for k in role.keys:
        if not role.properties.hasKey(k):
          c.report(YNode(kind: yNull, line: role.line, col: role.col), "pack",
            "role '" & role.name & "' is keyed by '" & k & "', which is not one of its properties",
            sevError, phSemantic)
      for name, a in role.assertions.mpairs:
        try:
          a.pred = parsePredicate(a.text)
          var problems: seq[string]
          var dyn: seq[tuple[param, role: string]]
          checkPredicate(pack, role.name, a.sig.params, a.pred, problems, dyn)
          for pr in problems:
            c.report(YNode(kind: yNull, line: a.line, col: a.col), "L7",
              "assertion '" & role.name & "." & name & "': " & pr, sevError, phSemantic)
        except PredicateError as e:
          c.report(YNode(kind: yNull, line: a.line, col: a.col), "pack",
            "assertion '" & role.name & "." & name & "': " & e.msg, sevError, phSemantic)
      for name, sd in role.sync.mpairs:
        if sd.text == "": continue
        try:
          sd.pred = parsePredicate(sd.text)
          var problems: seq[string]
          var dyn: seq[tuple[param, role: string]]
          checkPredicate(pack, role.name, [], sd.pred, problems, dyn)
          for pr in problems:
            c.report(YNode(kind: yNull, line: sd.line, col: sd.col), "L7",
              "sync '" & role.name & "." & name & "': " & pr, sevError, phSemantic)
        except PredicateError as e:
          c.report(YNode(kind: yNull, line: sd.line, col: sd.col), "pack",
            "sync '" & role.name & "." & name & "': " & e.msg, sevError, phSemantic)
    for name, sd in pack.sync.mpairs:
      if sd.text == "": continue
      try:
        sd.pred = parsePredicate(sd.text)
        var problems: seq[string]
        var dyn: seq[tuple[param, role: string]]
        checkPredicate(pack, pack.root, [], sd.pred, problems, dyn)
        for pr in problems:
          c.report(YNode(kind: yNull, line: sd.line, col: sd.col), "L7",
            "sync '" & name & "': " & pr, sevError, phSemantic)
      except PredicateError as e:
        c.report(YNode(kind: yNull, line: sd.line, col: sd.col), "pack",
          "sync '" & name & "': " & e.msg, sevError, phSemantic)
  (pack, c.diags)

proc parsePackText*(text, file: string): (Pack, Diagnostics) =
  var root: YNode
  try: root = readYaml(text)
  except YamlError as e:
    var msg = e.msg
    let colon = msg.find(": ")
    if colon >= 0: msg = msg[colon + 2 .. ^1]
    return (Pack(file: file), @[Diagnostic(rule: "yaml", severity: sevError,
      phase: phStructural, file: file, line: e.line, col: e.col, message: msg)])
  parsePackNode(root, file)

proc parsePackFile*(path: string): (Pack, Diagnostics) = parsePackText(readFile(path), path)
