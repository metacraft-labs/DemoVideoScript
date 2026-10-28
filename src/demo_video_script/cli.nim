## The DemoVideoScript command line, as a library: `dvs` is this with no
## in-process backends, and an adapter written in Nim links it with its own
## backend so that `run` and `conformance` reach it in process.
##
##   lint <scenario>… [--pack <pack.yaml>] [--json]
##   lint --pack <pack.yaml>              lint the pack on its own
##   parse <scenario>                     print the normalised scenario as JSON
##   schema scenario|pack|backend-protocol print a published JSON Schema
##   run <scenario> --pack <pack.yaml> --backend <name | cmd:PROGRAM [ARG…]>
##       [--mode fast|realistic|virtual] [--seed N] [--record off|on-failure|always]
##       [--out DIR | --build DIR] [--keep-runs N] [--keep-failure-days D]
##       [--deterministic [--env NAME=VALUE]… [--pin LOCATOR]… [--pixel-threshold SSIM]]
##       [--json]
##   conformance --pack <pack.yaml> --backend <…> [--defect NAME=<backend>]…
##       [--modes fast,realistic] <scenario>…
##   lane <lane.yaml> [--build DIR]       run a test lane against its expectations
##   capture-path scenario=<name> capture=<name> [--backend NAME] [--build DIR]
##   capture-path scenario=<name> steps=<from>..<to> [--backend NAME] [--build DIR]
##                                        resolve a citation to a file (and a span)
##
## Exit status of `lint`: 0 clean, 1 warnings only, 2 errors, 64 usage.
## Exit status of `run`: 0 passed, 1 failed, 3 unsupported, 2 error, 64 usage.

import std/[os, json, strutils, algorithm, tables, times]
import ./yaml, ./model, ./scenario, ./pack, ./lint, ./emit, ./backend, ./runner, ./jsonlines,
  ./recordings

type BackendFactory* = proc (): Backend

const
  ScenarioSchema = staticRead("../../schemas/v1/scenario.schema.json")
  PackSchema = staticRead("../../schemas/v1/pack.schema.json")
  ProtocolSchema = staticRead("../../schemas/v1/backend-protocol.schema.json")
  Usage = """usage:
  dvs lint <scenario>... [--pack <pack.yaml>] [--json]
  dvs lint --pack <pack.yaml> [--json]
  dvs parse <scenario>
  dvs schema scenario|pack|backend-protocol
  dvs run <scenario> --pack <pack.yaml> --backend <name | cmd:PROGRAM [ARG...]>
      [--mode fast|realistic|virtual] [--seed N] [--record off|on-failure|always]
      [--out DIR | --build DIR] [--keep-runs N] [--keep-failure-days D]
      [--deterministic [--env NAME=VALUE]... [--pin LOCATOR]... [--pixel-threshold SSIM]]
      [--json]
  dvs conformance --pack <pack.yaml> --backend <...> [--defect NAME=<backend>]...
      [--modes fast,realistic] <scenario>...
  dvs lane <lane.yaml> [--build DIR]
  dvs capture-path scenario=<name> capture=<name> [--backend NAME] [--build DIR]
  dvs capture-path scenario=<name> steps=<from>..<to> [--backend NAME] [--build DIR]
"""

proc usage() {.noreturn.} =
  stderr.write Usage
  quit 64

proc sortDiags(ds: var Diagnostics) =
  ds.sort(proc (a, b: Diagnostic): int =
    result = cmp(a.file, b.file)
    if result == 0: result = cmp(a.line, b.line)
    if result == 0: result = cmp(a.col, b.col)
    if result == 0: result = cmp(a.rule, b.rule))

proc toJson(d: Diagnostic): JsonNode =
  %*{"rule": d.rule, "severity": $d.severity,
     "phase": (if d.phase == phStructural: "structural" else: "semantic"),
     "file": d.file, "line": d.line, "col": d.col, "message": d.message}

proc cmdLint(args: seq[string]) =
  var files: seq[string]
  var packPath = ""
  var asJson = false
  var k = 0
  while k < args.len:
    let a = args[k]
    if a == "--pack":
      inc k
      if k >= args.len: usage()
      packPath = args[k]
    elif a.startsWith("--pack="): packPath = a[7 .. ^1]
    elif a == "--json": asJson = true
    elif a.startsWith("-"): usage()
    else: files.add a
    inc k
  if files.len == 0 and packPath == "": usage()
  var all: Diagnostics
  var pack: Pack = nil
  if packPath != "":
    if not fileExists(packPath):
      stderr.writeLine "dvs: no such pack file: " & packPath
      quit 2
    let (p, pd) = parsePackFile(packPath)
    all.add pd
    if not pd.hasErrors:
      pack = p
      all.add lintPack(p)
  for f in files:
    if not fileExists(f):
      stderr.writeLine "dvs: no such scenario file: " & f
      quit 2
    let (sc, d) = parseScenarioFile(f)
    all.add d
    if not d.hasErrors:
      all.add lintScenario(sc, pack)
  all.sortDiags()
  var errors, warnings = 0
  for d in all:
    if d.severity == sevError: inc errors else: inc warnings
  if asJson:
    var a = newJArray()
    for d in all: a.add d.toJson
    echo $(%*{"diagnostics": a, "errors": errors, "warnings": warnings})
  else:
    for d in all: echo $d
    if all.len > 0:
      stderr.writeLine $errors & " error(s), " & $warnings & " warning(s)"
  if errors > 0: quit 2
  if warnings > 0: quit 1
  quit 0

proc cmdParse(args: seq[string]) =
  if args.len != 1: usage()
  if not fileExists(args[0]):
    stderr.writeLine "dvs: no such scenario file: " & args[0]
    quit 2
  let (sc, d) = parseScenarioFile(args[0])
  if d.hasErrors:
    for x in d: stderr.writeLine $x
    quit 2
  echo emitScenario(sc).pretty

proc openBackend*(spec: string; builtins: Table[string, BackendFactory]): Backend =
  ## `name` of an in-process backend, or `cmd:PROGRAM ARG…` for one spoken to
  ## over JSON lines.
  if spec.startsWith("cmd:"):
    let parts = spec[4 .. ^1].splitWhitespace
    if parts.len == 0: raise newException(ValueError, "cmd: needs a program")
    return spawnJsonLinesBackend(parts[0], parts[1 .. ^1])
  if builtins.hasKey(spec): return builtins[spec]()
  var known: seq[string]
  for k in builtins.keys: known.add k
  raise newException(ValueError, "unknown backend '" & spec & "'" &
    (if known.len > 0: " (in process: " & known.join(", ") & ")" else: "") &
    "; use cmd:PROGRAM for an out-of-process backend")

proc resultJson*(r: RunResult): JsonNode =
  var steps = newJArray()
  for s in r.steps: steps.add stepJson(s)
  var uns = newJArray()
  for u in r.unsupported: uns.add %*{"step": u.path, "capability": u.capability}
  %*{"outcome": $r.outcome, "message": r.message, "scenario": r.scenario,
     "backend": r.backend, "mode": $r.mode, "runDir": r.runDir, "steps": steps,
     "unsupported": uns, "timingDependent": r.timingDependent, "media": r.media}

proc loadForRun(scenarioPath, packPath: string): (Scenario, Pack) =
  let (p, pd) = parsePackFile(packPath)
  if pd.hasErrors:
    for d in pd: stderr.writeLine $d
    quit 2
  let (sc, d) = parseScenarioFile(scenarioPath)
  if d.hasErrors:
    for x in d: stderr.writeLine $x
    quit 2
  (sc, p)

proc runOne*(scenarioPath: string; pack: Pack; sc: Scenario; b: Backend;
             opts: RunOptions): RunResult =
  var o = opts
  o.scenarioDir = scenarioPath.absolutePath.parentDir
  try:
    result = runScenario(sc, pack, b, o)
  finally:
    if b.close != nil: b.close()

proc buildDirDefault(): string = getEnv("BUILD_DIR", "build")

proc cmdRun(args: seq[string]; builtins: Table[string, BackendFactory]) =
  var scenarioPath, packPath, backendSpec, outDir = ""
  var buildDir = buildDirDefault()
  var retention = DefaultRetention
  var opts = RunOptions(mode: tmFast, record: rpOnFailure, seed: 1)
  var asJson = false
  var k = 0
  while k < args.len:
    let a = args[k]
    template value(): string =
      inc k
      if k >= args.len: usage()
      args[k]
    case a
    of "--pack": packPath = value()
    of "--backend": backendSpec = value()
    of "--mode": opts.mode = parseEnum[TimingMode](value())
    of "--seed": opts.seed = parseBiggestInt(value())
    of "--record": opts.record = parseEnum[RecordPolicy](value())
    of "--out": outDir = value()
    of "--build": buildDir = value()
    of "--keep-runs": retention.runs = parseInt(value())
    of "--keep-failure-days": retention.failureDays = parseFloat(value())
    of "--timeout": opts.timeoutMs = parseInt(value())
    of "--probe-reads": opts.probeReads = true
    of "--deterministic": opts.deterministic = true
    of "--env":
      let v = value()
      let eq = v.find('=')
      if eq <= 0: usage()
      opts.environment.add (v[0 ..< eq], v[eq + 1 .. ^1])
    of "--pin": opts.pinned.add value()
    of "--pixel-threshold": opts.pixelThreshold = parseFloat(value())
    of "--json": asJson = true
    else:
      if a.startsWith("-") or scenarioPath != "": usage()
      scenarioPath = a
    inc k
  if scenarioPath == "" or packPath == "" or backendSpec == "": usage()
  if (opts.environment.len > 0 or opts.pinned.len > 0) and not opts.deterministic:
    stderr.writeLine "dvs: --env and --pin configure a deterministic capture (--deterministic)"
    quit 64
  let (sc, pack) = loadForRun(scenarioPath, packPath)
  var b: Backend
  try: b = openBackend(backendSpec, builtins)
  except CatchableError as e:
    stderr.writeLine "dvs: " & e.msg
    quit 2
  var group = ""
  if opts.record != rpOff:
    opts.runId = newRunId()
    if outDir == "":
      var name = backendSpec.split({':', ' ', '/'})[^1]
      try: name = b.hello().backend
      except CatchableError: discard
      group = runGroupDir(buildDir, sc.name, name)
      outDir = group / opts.runId
    try: checkRunDir(outDir)
    except RunDirError as e:
      if b.close != nil: b.close()
      stderr.writeLine "dvs: " & e.msg
      quit 2
  opts.runDir = outDir
  let r = runOne(scenarioPath, pack, sc, b, opts)
  if group != "": discard prune(group, retention)
  if asJson: echo $resultJson(r)
  else:
    for s in r.steps:
      let mark = case s.status
        of ssPassed: "ok  "
        of ssFailed: "FAIL"
        of ssNotRun: "--  "
      echo mark, " ", s.path, " ", s.kind, (if s.message != "": ": " & s.message else: "")
    echo $r.outcome, (if r.message != "": ": " & r.message else: "")
    for d in r.diagnostics: stderr.writeLine $d
  if r.outcome in {roFailed, roError} and dirExists(r.runDir):
    # every failed run's recording is named, whatever the output format
    (if asJson: stderr else: stdout).writeLine "recording: ", r.runDir
  case r.outcome
  of roPassed: quit 0
  of roFailed: quit 1
  of roUnsupported: quit 3
  of roError: quit 2

proc cmdLane(args: seq[string]; builtins: Table[string, BackendFactory]) =
  ## A lane (§4.9 rule 3): the (scenario, backend) pairs it expects to be
  ## applicable and the ones it expects `unsupported`. An unexpected
  ## `unsupported` fails the lane; an expected one is listed in its summary.
  var lanePath = ""
  var buildDir = buildDirDefault()
  var k = 0
  while k < args.len:
    case args[k]
    of "--build":
      inc k
      if k >= args.len: usage()
      buildDir = args[k]
    else:
      if args[k].startsWith("-") or lanePath != "": usage()
      lanePath = args[k]
    inc k
  if lanePath == "": usage()
  let base = lanePath.absolutePath.parentDir
  let lane = readYamlFile(lanePath).toJson
  if lane{"lane"}.getInt(0) != 1:
    stderr.writeLine "dvs: " & lanePath & ": not a lane file (expected `lane: 1`)"
    quit 2
  proc at(p: string): string = (if p.isAbsolute: p else: base / p)
  let packPath = at(lane{"pack"}.getStr)
  let spec = lane{"backend"}.getStr
  let backendSpec = spec
  var modes: seq[TimingMode]
  for m in lane{"modes"}.getElems: modes.add parseEnum[TimingMode](m.getStr)
  if modes.len == 0: modes = @[tmFast]
  var retention = DefaultRetention
  if lane{"retention"} != nil and lane["retention"].kind == JObject:
    retention.runs = lane["retention"]{"runs"}.getInt(retention.runs)
    retention.failureDays = lane["retention"]{"failure-days"}.getFloat(retention.failureDays)
  var expected: seq[(string, bool)]   # (file, applicable)
  for f in lane{"applicable"}.getElems: expected.add (at(f.getStr), true)
  for f in lane{"unsupported"}.getElems: expected.add (at(f.getStr), false)
  if expected.len == 0:
    stderr.writeLine "dvs: " & lanePath & ": the lane names no scenario"
    quit 2
  var problems, expectedUnsupported, failedRuns: seq[string]
  var passed = 0
  for (f, applicable) in expected:
    let (sc, pack) = loadForRun(f, packPath)
    for m in modes:
      let b = openBackend(backendSpec, builtins)
      var name = spec
      try: name = b.hello().backend
      except CatchableError: discard
      let group = runGroupDir(buildDir, sc.name, name)
      let runId = newRunId()
      let r = runOne(f, pack, sc, b, RunOptions(mode: m, record: rpOnFailure, seed: 1,
                                                  runId: runId, runDir: group / runId))
      discard prune(group, retention)
      echo alignLeft($r.outcome, 12), alignLeft($m, 10), sc.name,
        (if r.message != "" and r.outcome != roPassed: "  — " & r.message else: "")
      case r.outcome
      of roPassed:
        if applicable: inc passed
        else: problems.add sc.name & " (" & $m & "): passed, but the lane expects it unsupported" &
                " — its expectation is stale"
      of roUnsupported:
        if applicable:
          var caps: seq[string]
          for u in r.unsupported: caps.add u.capability
          problems.add sc.name & " (" & $m & "): unsupported, but the lane expects it to run (" &
            caps.join(", ") & ")"
        elif m == modes[0]:
          var caps: seq[string]
          for u in r.unsupported: caps.add u.capability
          expectedUnsupported.add sc.name & " (" & caps.join(", ") & ")"
      of roFailed, roError:
        problems.add sc.name & " (" & $m & "): " & $r.outcome & ": " & r.message
        if dirExists(r.runDir): failedRuns.add r.runDir
  echo "lane ", lane{"name"}.getStr(lanePath.extractFilename), ": ", passed, " passed, ",
    expectedUnsupported.len, " unsupported as expected, ", problems.len, " problem(s)"
  for u in expectedUnsupported: echo "expected unsupported: ", u
  for p in problems: echo "PROBLEM ", p
  for d in failedRuns: echo "recording: ", d
  quit (if problems.len == 0: 0 else: 1)

proc cmdCapturePath(args: seq[string]) =
  ## Resolves a citation — a scenario and a capture name, or a step range of
  ## its cast — to the file the newest run produced. Never the reverse: a
  ## path is not a citation.
  var scenarioName, capture, steps, backendName = ""
  var buildDir = buildDirDefault()
  var k = 0
  while k < args.len:
    let a = args[k]
    if a == "--build" or a == "--backend":
      inc k
      if k >= args.len: usage()
      if a == "--build": buildDir = args[k] else: backendName = args[k]
    elif a.startsWith("scenario="): scenarioName = a[9 .. ^1]
    elif a.startsWith("capture="): capture = a[8 .. ^1]
    elif a.startsWith("steps="): steps = a[6 .. ^1]
    else: usage()
    inc k
  if scenarioName == "" or (capture == "") == (steps == ""): usage()
  let run = newestRun(buildDir, scenarioName, backendName)
  if run == "":
    stderr.writeLine "dvs: no recorded run of '" & scenarioName & "' under " & runsRoot(buildDir)
    quit 1
  try:
    if capture != "":
      for p in capturePaths(run, capture): echo p
    else:
      let parts = steps.split("..")
      if parts.len != 2: usage()
      let span = castSpan(run, parseInt(parts[0]), parseInt(parts[1]))
      echo $(%*{"file": span.file, "fromMs": span.fromMs, "toMs": span.toMs,
                "virtual": span.virtual})
  except KeyError as e:
    stderr.writeLine "dvs: " & e.msg
    quit 1

proc cmdConformance(args: seq[string]; builtins: Table[string, BackendFactory]) =
  ## A backend is conformant (§12) when every scenario its capabilities admit
  ## passes in every mode, every other one is `unsupported` (never `passed`),
  ## and every planted-defect arm turns at least one scenario red.
  var packPath, backendSpec = ""
  var defects: seq[(string, string)]
  var modes = @[tmFast, tmRealistic]
  var files: seq[string]
  var k = 0
  while k < args.len:
    let a = args[k]
    template value(): string =
      inc k
      if k >= args.len: usage()
      args[k]
    case a
    of "--pack": packPath = value()
    of "--backend": backendSpec = value()
    of "--defect":
      let v = value()
      let eq = v.find('=')
      if eq < 0: usage()
      defects.add (v[0 ..< eq], v[eq + 1 .. ^1])
    of "--modes":
      modes.setLen(0)
      for m in value().split(','): modes.add parseEnum[TimingMode](m)
    else:
      if a.startsWith("-"): usage()
      files.add a
    inc k
  if packPath == "" or backendSpec == "" or files.len == 0: usage()
  var problems: seq[string]
  var passed, unsupported = 0
  for f in files:
    let (sc, pack) = loadForRun(f, packPath)
    var outcomes: seq[RunOutcome]
    for m in modes:
      let b = openBackend(backendSpec, builtins)
      let r = runOne(f, pack, sc, b, RunOptions(mode: m, record: rpOff, seed: 1,
                                                  probeReads: true))
      outcomes.add r.outcome
      echo alignLeft($r.outcome, 12), alignLeft($m, 10), sc.name,
        (if r.message != "" and r.outcome != roPassed: "  — " & r.message else: "")
      case r.outcome
      of roPassed: discard
      of roUnsupported:
        if r.unsupported.len == 0: problems.add sc.name & ": unsupported without naming a capability"
      else: problems.add sc.name & " (" & $m & "): " & $r.outcome & ": " & r.message
    if outcomes.len > 0 and outcomes[0] == roUnsupported: inc unsupported
    elif roPassed in outcomes: inc passed
    for o in outcomes:
      if (o == roUnsupported) != (outcomes[0] == roUnsupported):
        problems.add sc.name & ": unsupported in one mode and not in another"
  for (name, spec) in defects:
    var red = 0
    for f in files:
      let (sc, pack) = loadForRun(f, packPath)
      let b = openBackend(spec, builtins)
      let r = runOne(f, pack, sc, b, RunOptions(mode: tmFast, record: rpOff, seed: 1,
                                                  probeReads: true))
      if r.outcome in {roFailed, roError}: inc red
    echo "planted defect ", name, ": ", red, " scenario(s) red"
    if red == 0: problems.add "planted defect '" & name & "' turned no scenario red"
  echo passed, " passed, ", unsupported, " unsupported, ", problems.len, " problem(s)"
  for p in problems: echo "PROBLEM ", p
  quit (if problems.len == 0: 0 else: 1)

proc dvsMain*(builtins: Table[string, BackendFactory] = initTable[string, BackendFactory]()) =
  let args = commandLineParams()
  if args.len == 0: usage()
  case args[0]
  of "lint": cmdLint(args[1 .. ^1])
  of "parse": cmdParse(args[1 .. ^1])
  of "run": cmdRun(args[1 .. ^1], builtins)
  of "conformance": cmdConformance(args[1 .. ^1], builtins)
  of "lane": cmdLane(args[1 .. ^1], builtins)
  of "capture-path": cmdCapturePath(args[1 .. ^1])
  of "schema":
    if args.len != 2: usage()
    case args[1]
    of "scenario": stdout.write ScenarioSchema
    of "pack": stdout.write PackSchema
    of "backend-protocol": stdout.write ProtocolSchema
    else: usage()
  of "yaml":
    # Not part of the documented interface: prints how this reader reads a
    # YAML file, for the test that compares it with a reference YAML reader.
    if args.len != 2: usage()
    try:
      echo $readYamlFile(args[1]).toJson
    except YamlError as e:
      echo $(%*{"error": e.msg, "line": e.line, "col": e.col})
      quit 2
  of "--help", "-h", "help":
    stdout.write Usage
  else: usage()
