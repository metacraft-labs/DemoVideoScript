## The runner against the reference backend, in process (`dvs-ref`) and over
## JSON lines (`dvs-refapp`), through the built command-line binaries: every
## check runs real processes over real files.
##
## The one stand-in is tests/support/broken_backend.nim, a real process that
## breaks the protocol on purpose; its header says why it is not a mock.

import std/[json, os, osproc, strutils, unittest, streams, sequtils, strtabs]
import demo_video_script/[scenario, backend, runner, jsonlines]
from demo_video_script/pack as packmod import parsePackFile

let root = currentSourcePath().parentDir.parentDir
let bin = getEnv("DVS_BIN_DIR", root / "build/bin")
let dvsRef = bin / "dvs-ref"
let refapp = bin / "dvs-refapp"
let broken = bin / "broken-backend"
let pack = root / "conformance/pack/notes-app.pack.yaml"

proc run(args: openArray[string]; env: openArray[(string, string)] = []): tuple[output: string, code: int] =
  var e = newStringTable()
  for k, v in envPairs(): e[k] = v
  for (k, v) in env: e[k] = v
  let p = startProcess(dvsRef, args = args, env = e, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

proc runJson(scenario, backend: string; extra: seq[string] = @[];
             env: openArray[(string, string)] = []): JsonNode =
  let (o, _) = run(@["run", scenario, "--pack", pack, "--backend", backend, "--json",
                     "--record", "off"] & extra, env)
  for line in o.splitLines:
    if line.startsWith("{"): return parseJson(line)
  raise newException(ValueError, "no result: " & o)

proc statuses(r: JsonNode): seq[string] =
  for s in r["steps"]: result.add s["path"].getStr & ":" & s["status"].getStr

suite "the runner on the reference backend":
  test "the corpus passes in process and over JSON lines, with identical step results":
    for f in walkFiles(root / "conformance/scenarios/*.yaml"):
      checkpoint f
      let a = runJson(f, "refapp")
      let b = runJson(f, "cmd:" & refapp)
      check a["outcome"].getStr == "passed"
      check b["outcome"].getStr == "passed"
      check statuses(a) == statuses(b)

  test "an inapplicable scenario is unsupported, names the capability, and runs nothing":
    let tmp = getTempDir() / "dvs-unsupported-" & $getCurrentProcessId()
    createDir(tmp)
    defer: removeDir(tmp)
    copyFile(root / "tests/runner/unsupported-ext.yaml", tmp / "s.yaml")
    let r = runJson(tmp / "s.yaml", "refapp")
    check r["outcome"].getStr == "unsupported"
    check r["unsupported"][0]["capability"].getStr == "ext.termassert"
    check r["unsupported"][0]["step"].getStr == "2"
    check not fileExists(tmp / "stage-ran.txt")   # the stage never ran
    check r["steps"].len == 0

  test "a missing drag is unsupported where the scenario has no alternative, and the alternative runs where it has one":
    let r = runJson(root / "conformance/scenarios/drag-to-reorder.yaml", "refapp-no-drag")
    check r["outcome"].getStr == "unsupported"
    check r["unsupported"][0]["capability"].getStr == "input.pointer.drag"
    let t = runJson(root / "conformance/scenarios/presentation-tour.yaml", "refapp-no-drag")
    check t["outcome"].getStr == "passed"
    var variants: seq[string]
    for s in t["steps"]:
      if s.hasKey("variant"): variants.add s["variant"].getStr
    check variants == @["input.pointer.drag"]

  test "applicability is known from the hello alone, before anything runs":
    let (sc, _) = parseScenarioFile(root / "conformance/scenarios/drag-to-reorder.yaml")
    let (pk, _) = parsePackFile(pack)
    var hello = Hello(backend: "probe", capabilities: @["input.key", "input.chord",
      "input.text", "input.pointer.click", "observe.text", "observe.geometry"])
    let missing = applicability(sc, pk, hello)
    check missing.len > 0
    var caps: seq[string]
    for m in missing: caps.add m.capability
    check "input.pointer.drag" in caps
    hello.capabilities.add "input.pointer.drag"
    hello.capabilities.add "input.pointer.move"
    check applicability(sc, pk, hello).len == 0

  test "a staged session is driven on, step by step, without staging it again":
    let (sc, _) = parseScenarioFile(root / "conformance/scenarios/rename-through-dialog.yaml")
    let (pk, _) = parsePackFile(pack)
    let b = spawnJsonLinesBackend(refapp)
    defer: b.close()
    var first = sc
    first.steps = sc.steps[0 .. 1]
    let opts = RunOptions(mode: tmFast, scenarioDir: root / "conformance/scenarios")
    check runScenario(first, pk, b, opts).outcome == roPassed
    # the rest, one step at a time, on the same session
    var staged = opts
    staged.staged = true
    for k in 2 ..< sc.steps.len:
      var one = sc
      one.steps = @[sc.steps[k]]
      let r = runScenario(one, pk, b, staged)
      checkpoint $k & ": " & r.message
      check r.outcome == roPassed

  test "a dwell that the scenario depends on: green in realistic mode, red in fast mode, reported":
    let fast = runJson(root / "tests/runner/dwell-dependent.yaml", "refapp", @["--mode", "fast"])
    let real = runJson(root / "tests/runner/dwell-dependent.yaml", "refapp", @["--mode", "realistic"])
    check fast["outcome"].getStr == "failed"
    check real["outcome"].getStr == "passed"
    check fast["timingDependent"].getBool
    check real["timingDependent"].getBool

  test "a wait never passes by timing out, and reports the last observed state":
    let r = runJson(root / "tests/runner/wait-timeout.yaml", "refapp")
    check r["outcome"].getStr == "failed"
    let s = r["steps"][0]
    check s["status"].getStr == "failed"
    check "never held" in s["message"].getStr
    check "count is 3" in s["message"].getStr
    check r["steps"][1]["status"].getStr == "not-run"

  test "a chord bound to nothing fails; it never falls back to invoking the operation":
    let r = runJson(root / "tests/runner/chord-unbound.yaml", "refapp")
    check r["outcome"].getStr == "failed"
    check "nothing is bound" in r["steps"][0]["message"].getStr

  test "a key the backend cannot deliver is refused, not replaced":
    let r = runJson(root / "tests/runner/meta-refused.yaml", "refapp")
    check r["outcome"].getStr == "failed"
    check "refused" in r["steps"][0]["message"].getStr

  test "each planted defect turns at least one scenario red":
    let files = toSeq(walkFiles(root / "conformance/scenarios/*.yaml"))
    for d in ["stale-read", "off-by-one", "early-sync", "read-side-effect"]:
      var red = 0
      for f in files:
        let r = runJson(f, "refapp-" & d, @["--probe-reads"])
        if r["outcome"].getStr in ["failed", "error"]: inc red
      checkpoint d
      check red > 0

  test "a read with a side effect is named as one (reads are probed twice)":
    let r = runJson(root / "conformance/scenarios/archive-from-keyboard.yaml",
                    "refapp-read-side-effect", @["--probe-reads"])
    check r["outcome"].getStr == "failed"
    check "a read has a side effect" in $r["steps"]

  test "realistic runs with the same seed pace identically; another seed paces differently":
    let tmp = getTempDir() / "dvs-seed-" & $getCurrentProcessId()
    createDir(tmp)
    defer: removeDir(tmp)
    proc timings(seed, name: string): seq[string] =
      let t = tmp / name
      discard runJson(root / "conformance/scenarios/presentation-tour.yaml", "cmd:" & refapp,
                      @["--mode", "realistic", "--seed", seed], [("DVS_PROTOCOL_TRANSCRIPT", t)])
      for line in lines(t):
        if line.startsWith("> ") and "\"timing\"" in line:
          result.add $parseJson(line[2 .. ^1])["action"]["timing"]
    let a = timings("7", "a")
    let b = timings("7", "b")
    let c = timings("8", "c")
    check a.len > 0
    check a == b
    check a != c

  test "the stage channel closes before the first step, and every input is followed by settled":
    let t = getTempDir() / "dvs-order-" & $getCurrentProcessId()
    defer: removeFile(t)
    let r = runJson(root / "conformance/scenarios/presentation-tour.yaml", "cmd:" & refapp,
                    env = [("DVS_PROTOCOL_TRANSCRIPT", t)])
    check r["outcome"].getStr == "passed"
    var calls: seq[JsonNode]
    for line in lines(t):
      if line.startsWith("> "): calls.add parseJson(line[2 .. ^1])
    var endStage = -1
    var lastStage = -1
    var firstStep = -1
    for k, c in calls:
      case c["call"].getStr
      of "stage": lastStage = k
      of "end-stage": endStage = k
      of "locate", "send", "read":
        if firstStep < 0: firstStep = k
      else: discard
    check lastStage >= 0 and endStage > lastStage and firstStep > endStage
    var sends, settledAfter = 0
    for k, c in calls:
      if c["call"].getStr == "send" and not c["action"].hasKey("ext"):
        inc sends
        if k + 1 < calls.len and calls[k + 1]["call"].getStr == "await" and
            calls[k + 1]["condition"].getStr == "settled":
          inc settledAfter
    # (the one input with `settle: false` is followed by an explicit wait on settled)
    check sends == 5
    check settledAfter == sends

suite "recordings":
  test "a recorded run leaves a manifest, per-step state and stills":
    let dir = getTempDir() / "dvs-rec-" & $getCurrentProcessId()
    defer: removeDir(dir)
    let (o, code) = run(["run", root / "conformance/scenarios/archive-from-keyboard.yaml",
                         "--pack", pack, "--backend", "refapp", "--record", "always", "--out", dir])
    checkpoint o
    check code == 0
    let m = parseFile(dir / "manifest.json")
    check m["format"].getStr == "demo-video-script.run.v1"
    check m["outcome"].getStr == "passed"
    check m["backend"]["backend"].getStr == "refapp"
    check m["steps"].len == 9
    for s in m["steps"]:
      check s["endMs"].getFloat >= s["startMs"].getFloat
    check m["steps"][1]["resolved"]["target"]["role"].getStr == "note"
    check m["steps"][4]["resolved"]["chord"].getStr == "Ctrl+d"
    check m["steps"][6]["observed"]["values"]["count"].getInt == 2
    check fileExists(dir / "steps/1-state.json")
    check fileExists(dir / "steps/9-after-archive.txt")
    check "Groceries" notin readFile(dir / "steps/9-after-archive.txt")

  test "a failing run keeps its recording by default, with the failing observation":
    let dir = getTempDir() / "dvs-fail-" & $getCurrentProcessId()
    defer: removeDir(dir)
    let (o, code) = run(["run", root / "tests/runner/wait-timeout.yaml", "--pack", pack,
                         "--backend", "refapp", "--out", dir])
    check code == 1
    check ("recording: " & dir) in o
    check fileExists(dir / "manifest.json")
    check fileExists(dir / "failure/observation.json")
    check fileExists(dir / "failure/surface.txt")
    check parseFile(dir / "manifest.json")["outcome"].getStr == "failed"

  test "a passing run leaves nothing unless asked":
    let dir = getTempDir() / "dvs-pass-" & $getCurrentProcessId()
    let (_, code) = run(["run", root / "conformance/scenarios/context-menu-pin.yaml", "--pack",
                         pack, "--backend", "refapp", "--out", dir])
    check code == 0
    check not dirExists(dir)

  test "virtual timing: recorded at fast speed, the realistic timeline computed":
    let r = runJson(root / "conformance/scenarios/presentation-tour.yaml", "refapp",
                    @["--mode", "virtual"])
    check r["outcome"].getStr == "passed"
    var actual, virt = 0.0
    for s in r["steps"]:
      actual = max(actual, s["endMs"].getFloat)
      virt = max(virt, s["virtualEndMs"].getFloat)
      check s["virtualEndMs"].getFloat >= s["virtualStartMs"].getFloat
    # the dwell (1 s), lead-ins and typing pace are on the timeline, not enacted
    check virt > actual + 1000
    check actual < 1000

  test "a recorded run notes where each callout points when it starts":
    let dir = getTempDir() / "dvs-callouts-" & $getCurrentProcessId()
    defer: removeDir(dir)
    let (o, code) = run(["run", root / "conformance/scenarios/presentation-tour.yaml", "--pack",
                         pack, "--backend", "refapp", "--record", "always", "--out", dir])
    check code == 0
    let m = parseFile(dir / "manifest.json")
    var found: seq[JsonNode]
    for st in m["steps"]:
      if st.hasKey("resolved") and st["resolved"].hasKey("callouts"):
        found.add %*{"path": st["path"], "callouts": st["resolved"]["callouts"]}
    checkpoint o
    # the beat's callout starts with the beat's first step
    check found.len == 1
    check found[0]["path"].getStr == "2.1"
    let c = found[0]["callouts"][0]
    check c["locator"].getStr == "note-list/note[title=\"Recipes\"]"
    check c["text"].getStr == "This one"
    check c["outcome"].getStr == "one"
    check c["geometry"]["w"].getFloat > 0

suite "the JSON-lines transport":
  for mode in ["non-json", "exit", "silent", "wrong-id"]:
    test "a backend that answers '" & mode & "' yields an error naming it":
      let r = runJson(root / "tests/runner/broken-backend.yaml", "cmd:" & broken & " " & mode,
                      env = [("DVS_BACKEND_TIMEOUT_MS", "1500")])
      check r["outcome"].getStr == "error"
      check "broken" in r["message"].getStr or "broken" in $r["steps"]
      if mode == "exit":
        # reported as an exit, with the backend's own last words
        check "exited with status 3" in $r["steps"]
        check "exiting in the middle of a step" in $r["steps"]

  test "the stage channel closes: a stage call after end-stage is refused":
    let p = startProcess(refapp, options = {})
    p.inputStream.write("""{"id":1,"call":"end-stage"}""" & "\n" &
                        """{"id":2,"call":"stage","use":"launch-app","with":{}}""" & "\n" &
                        """{"id":3,"call":"shutdown"}""" & "\n")
    p.inputStream.flush()
    let lines = p.outputStream.readAll().strip.splitLines
    discard p.waitForExit()
    p.close()
    check parseJson(lines[0])["ok"].getBool
    let second = parseJson(lines[1])
    check not second["ok"].getBool
    check second["error"]["kind"].getStr == "stage-closed"
