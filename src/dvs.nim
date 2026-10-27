## `dvs` — the DemoVideoScript command line.
##
##   dvs lint <scenario>… [--pack <pack.yaml>] [--json]
##   dvs lint --pack <pack.yaml>            lint the pack on its own
##   dvs parse <scenario>                   print the normalised scenario as JSON
##   dvs schema scenario|pack               print a published JSON Schema
##
## Exit status of `lint`: 0 clean, 1 warnings only, 2 errors, 64 usage.

import std/[os, json, strutils, algorithm]
import demo_video_script

const
  ScenarioSchema = staticRead("../schemas/v1/scenario.schema.json")
  PackSchema = staticRead("../schemas/v1/pack.schema.json")
  Usage = """usage:
  dvs lint <scenario>... [--pack <pack.yaml>] [--json]
  dvs lint --pack <pack.yaml> [--json]
  dvs parse <scenario>
  dvs schema scenario|pack
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

proc main() =
  let args = commandLineParams()
  if args.len == 0: usage()
  case args[0]
  of "lint": cmdLint(args[1 .. ^1])
  of "parse": cmdParse(args[1 .. ^1])
  of "schema":
    if args.len != 2: usage()
    case args[1]
    of "scenario": stdout.write ScenarioSchema
    of "pack": stdout.write PackSchema
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

when isMainModule: main()
