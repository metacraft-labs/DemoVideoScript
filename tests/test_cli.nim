## The `dvs` command line, run as a real process over real files: the lint
## fixtures report exactly the diagnostics their header names, the conformance
## corpus is clean, the normalised form round-trips, versions are refused by
## number, and the published schemas are what `dvs schema` prints.
##
## No stand-ins: every check runs the built binary (`DVS_BIN`, default
## build/bin/dvs) on files in this repository or written to a temporary
## directory.

import std/[json, os, osproc, sequtils, strutils, unittest, algorithm, sets, streams]

let root = currentSourcePath().parentDir.parentDir
let dvs = getEnv("DVS_BIN", root / "build/bin/dvs")
let notesPack = root / "conformance/pack/notes-app.pack.yaml"

proc run(args: openArray[string]): tuple[output: string, code: int] =
  let p = startProcess(dvs, args = args, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

proc runJson(args: openArray[string]): tuple[diags: JsonNode, code: int] =
  let p = startProcess(dvs, args = @args & @["--json"], options = {})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (parseJson(output)["diagnostics"], code)

proc expected(path: string): seq[string] =
  let first = readFile(path).splitLines()[0]
  doAssert first.startsWith("# expect:"), path & " has no '# expect:' header"
  for w in first["# expect:".len .. ^1].splitWhitespace: result.add w
  result.sort()

proc reported(diags: JsonNode): seq[string] =
  var s: HashSet[string]
  for d in diags: s.incl d["rule"].getStr & ":" & $d["line"].getInt
  result = toSeq(s)
  result.sort()

suite "dvs lint":
  test "binary exists":
    check fileExists(dvs)

  test "every scenario lint fixture reports exactly its expected diagnostics":
    var n = 0
    for f in walkFiles(root / "tests/lint/*.yaml"):
      let (diags, _) = runJson(["lint", "--pack", notesPack, f])
      checkpoint f
      check reported(diags) == expected(f)
      inc n
    check n >= 20

  test "every pack lint fixture reports exactly its expected diagnostics":
    var n = 0
    for f in walkFiles(root / "tests/lint/packs/*.pack.yaml"):
      let (diags, _) = runJson(["lint", "--pack", f])
      checkpoint f
      check reported(diags) == expected(f)
      inc n
    check n >= 4

  test "a stage call in steps is named as one":
    let (diags, _) = runJson(["lint", "--pack", notesPack, root / "tests/lint/l1-bad.yaml"])
    var named = false
    for d in diags:
      if d["line"].getInt == 9 and "stage procedure" in d["message"].getStr: named = true
    check named

  test "the conformance corpus is clean":
    let files = toSeq(walkFiles(root / "conformance/scenarios/*.yaml"))
    check files.len >= 9
    let (output, code) = run(@["lint", "--pack", notesPack] & files)
    checkpoint output
    check code == 0
    check output.strip == ""

  test "exit status: 1 for warnings only, 2 for errors, 64 for usage":
    check run(["lint", "--pack", notesPack, root / "tests/lint/l4-bad.yaml"]).code == 1
    check run(["lint", "--pack", notesPack, root / "tests/lint/l2-bad.yaml"]).code == 2
    check run(["lint"]).code == 64
    check run(["frobnicate"]).code == 64

  test "a version this parser does not implement is refused by number":
    let (output, code) = run(["lint", root / "tests/schema/invalid/version-two.yaml"])
    check code == 2
    check "version 2 is not implemented" in output
    check output.count("error") == 2  # the diagnostic and the summary: nothing else was read

suite "dvs parse":
  test "the normalised form round-trips for every corpus scenario":
    let tmp = getTempDir() / "dvs-roundtrip-" & $getCurrentProcessId()
    createDir(tmp)
    defer: removeDir(tmp)
    for f in walkFiles(root / "conformance/scenarios/*.yaml"):
      let (first, c1) = run(["parse", f])
      checkpoint f
      check c1 == 0
      let j = tmp / extractFilename(f) & ".json"
      writeFile(j, first)
      let (second, c2) = run(["parse", j])
      check c2 == 0
      check second == first

suite "dvs schema":
  test "prints the published schemas":
    check run(["schema", "scenario"]).output == readFile(root / "schemas/v1/scenario.schema.json")
    check run(["schema", "pack"]).output == readFile(root / "schemas/v1/pack.schema.json")
