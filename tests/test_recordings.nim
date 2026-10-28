## Test-run recordings and documentation captures (§9): where a run directory
## goes and what a failed one holds, which runs the next one keeps, test lanes,
## deterministic captures and citations. Every check runs the built `dvs-ref`
## (the runner with the reference backend in process) or `dvs-refapp` (the same
## backend over JSON lines) on real files; the retention check builds a run
## history of real directories with real timestamps.

import std/[json, os, osproc, strutils, unittest, streams, strtabs, times, sequtils, algorithm]

let root = currentSourcePath().parentDir.parentDir
let bin = getEnv("DVS_BIN_DIR", root / "build/bin")
let dvsRef = bin / "dvs-ref"
let refapp = bin / "dvs-refapp"
let pack = root / "conformance/pack/notes-app.pack.yaml"
let here = root / "tests/recordings"

proc run(args: openArray[string]; env: openArray[(string, string)] = []): tuple[output: string, code: int] =
  var e = newStringTable()
  for k, v in envPairs(): e[k] = v
  for (k, v) in env: e[k] = v
  let p = startProcess(dvsRef, args = args, env = e, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

proc scratch(name: string): string =
  result = getTempDir() / ("dvs-rec-" & name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc runDirs(build, scenario, backend: string): seq[string] =
  let g = build / "scenario-runs" / scenario / backend
  if dirExists(g):
    for kind, p in walkDir(g):
      if kind == pcDir: result.add p
  result.sort()

suite "test-run recordings":
  test "a failing run leaves its recording under the build directory, and names it":
    let build = scratch("fail")
    defer: removeDir(build)
    for backend in ["refapp", "cmd:" & refapp]:
      let (o, code) = run(["run", here / "broken-expectation.yaml", "--pack", pack, "--backend",
                           backend], [("BUILD_DIR", build)])
      checkpoint o
      check code == 1
    let dirs = runDirs(build, "recordings-broken-expectation", "refapp")
    check dirs.len == 2
    for d in dirs:
      let m = parseJson(readFile(d / "manifest.json"))
      check m["outcome"].getStr == "failed"
      check m["runId"].getStr == d.lastPathPart
      check m["startedAt"].getStr.endsWith("Z")
      check fileExists(d / "steps/1-state.json")
      check fileExists(d / "steps/2-state.json")
      check fileExists(d / "steps/1-key.txt")
      check fileExists(d / "failure/observation.json")
      check parseJson(readFile(d / "failure/observation.json"))["step"]["index"].getInt == 2
      check fileExists(d / "failure/surface.txt")
      check fileExists(d / "failure/backend.log")
    # the runner prints where each failed run went
    let (o, _) = run(["run", here / "broken-expectation.yaml", "--pack", pack, "--backend", "refapp"],
                     [("BUILD_DIR", build)])
    let printed = o.splitLines.filterIt(it.startsWith("recording: "))
    check printed.len == 1
    check printed[0]["recording: ".len .. ^1] in runDirs(build, "recordings-broken-expectation", "refapp")

  test "a passing run leaves no recording unless asked":
    let build = scratch("pass")
    defer: removeDir(build)
    let f = root / "conformance/scenarios/archive-from-keyboard.yaml"
    check run(["run", f, "--pack", pack, "--backend", "refapp"], [("BUILD_DIR", build)]).code == 0
    check runDirs(build, "notes-archive-from-keyboard", "refapp").len == 0
    check run(["run", f, "--pack", pack, "--backend", "refapp", "--record", "always"],
              [("BUILD_DIR", build)]).code == 0
    let dirs = runDirs(build, "notes-archive-from-keyboard", "refapp")
    check dirs.len == 1
    check parseJson(readFile(dirs[0] / "manifest.json"))["outcome"].getStr == "passed"

  test "a recording is never written to the home directory or a shared state directory":
    let home = scratch("home")
    defer: removeDir(home)
    let f = root / "conformance/scenarios/archive-from-keyboard.yaml"
    for (dir, why) in [(home, "is not written to"),
                       (home / ".local/state/runs", "state directory"),
                       (home / ".config/runs", "configuration directory"),
                       (home / ".cache/runs", "cache directory")]:
      let (o, code) = run(["run", f, "--pack", pack, "--backend", "refapp", "--record", "always",
                           "--out", dir],
                          [("HOME", home), ("XDG_STATE_HOME", ""), ("XDG_CONFIG_HOME", ""),
                           ("XDG_CACHE_HOME", ""), ("XDG_DATA_HOME", "")])
      checkpoint o
      check code == 2
      check why in o
      check not fileExists(dir / "manifest.json")

  test "retention keeps the last five runs and every failure younger than seven days":
    let build = scratch("retention")
    defer: removeDir(build)
    let group = build / "scenario-runs/notes-archive-from-keyboard/refapp"
    # a history of real run directories: (age, outcome)
    let history = [(1.0, "passed"), (2.0, "failed"), (3.0, "passed"), (4.0, "passed"),
                   (5.0, "passed"),                       # the five newest
                   (6.0, "passed"), (30.0, "failed"),     # older than the five, failure < 7 days
                   (24.0 * 6.5, "failed"),                # 6.5 days: kept
                   (24.0 * 7.5, "failed"),                # 7.5 days: deleted
                   (24.0 * 9.0, "passed")]                # deleted
    let t0 = now().utc
    var names: seq[string]
    for (hoursAgo, outcome) in history:
      let t = t0 - initDuration(seconds = int64(hoursAgo * 3600))
      let id = t.format("yyyyMMdd'T'HHmmss'.'fff'Z'")
      createDir(group / id)
      writeFile(group / id / "manifest.json", $(%*{"outcome": outcome, "runId": id,
        "startedAt": t.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")}))
      names.add id
    # one more run, recorded: it is the newest, and the next run's retention applies
    let f = root / "conformance/scenarios/archive-from-keyboard.yaml"
    check run(["run", f, "--pack", pack, "--backend", "refapp", "--record", "always"],
              [("BUILD_DIR", build)]).code == 0
    var kept: seq[string]
    for kind, p in walkDir(group): kept.add p.lastPathPart
    # the new run, then the four newest of the history, then the failures within 7 days
    check names[0] in kept and names[1] in kept and names[2] in kept and names[3] in kept
    check names[4] notin kept     # sixth newest, passed
    check names[5] notin kept     # passed, not among the newest five
    check names[6] in kept        # failed 30 hours ago
    check names[7] in kept        # failed 6.5 days ago
    check names[8] notin kept     # failed 7.5 days ago
    check names[9] notin kept
    check kept.len == 7

suite "test lanes":
  test "an unsupported scenario the lane expects to run fails the lane":
    let build = scratch("lane1")
    defer: removeDir(build)
    let (o, code) = run(["lane", here / "expects-drag.lane.yaml", "--build", build])
    checkpoint o
    check code == 1
    check "PROBLEM notes/drag-to-reorder (fast): unsupported, but the lane expects it to run" in o
    check "input.pointer.drag" in o

  test "an unsupported scenario the lane expects is listed in its summary":
    let build = scratch("lane2")
    defer: removeDir(build)
    let (o, code) = run(["lane", here / "knows-no-drag.lane.yaml", "--build", build])
    checkpoint o
    check code == 0
    check "lane knows-no-drag: 1 passed, 1 unsupported as expected, 0 problem(s)" in o
    check "expected unsupported: notes/drag-to-reorder (input.pointer.drag)" in o

suite "documentation captures":
  test "a capture run with a live clock on screen fails unless the clock is declared":
    let build = scratch("volatile")
    defer: removeDir(build)
    let (o, code) = run(["run", here / "clock-capture.yaml", "--pack", pack, "--backend", "refapp",
                         "--record", "always", "--deterministic"], [("BUILD_DIR", build)])
    checkpoint o
    check code == 1
    check "an undeclared volatile region" in o
    check "lines 1" in o
    let (o2, code2) = run(["run", here / "clock-capture.yaml", "--pack", pack, "--backend", "refapp",
                           "--record", "always", "--deterministic", "--pin", "clock"],
                          [("BUILD_DIR", build)])
    checkpoint o2
    check code2 == 0

  test "two deterministic runs produce byte-identical captures":
    let build = scratch("identical")
    defer: removeDir(build)
    var files: seq[seq[string]]
    for i in 0 .. 1:
      let (o, code) = run(["run", here / "clock-capture.yaml", "--pack", pack, "--backend", "refapp",
                           "--record", "always", "--deterministic", "--pin", "clock",
                           "--env", "TZ=UTC", "--env", "LANG=C.UTF-8"], [("BUILD_DIR", build)])
      checkpoint o
      check code == 0
      sleep(1100)   # the clock moves on between the runs
      var fs: seq[string]
      for name in ["first-selected", "last-selected"]:
        let (p, c) = run(["capture-path", "scenario=recordings/clock-capture", "capture=" & name,
                          "--build", build])
        check c == 0
        fs.add p.strip
      files.add fs
    check files[0] != files[1]
    # the casts, on the virtual timeline, with the clock masked
    check readFile(files[0][0].parentDir.parentDir / "session.cast") ==
          readFile(files[1][0].parentDir.parentDir / "session.cast")
    for k in 0 .. 1:
      check readFile(files[0][k]) == readFile(files[1][k])
      check "#" in readFile(files[0][k]).splitLines[0]    # the clock, masked
    let m = parseJson(readFile(files[1][0].parentDir.parentDir / "manifest.json"))
    check m["deterministic"].getBool
    check m["mode"].getStr == "virtual"
    check m["environment"]["TZ"].getStr == "UTC"
    check m["pinned"] == %["clock"]

  test "declared volatile regions need a backend that masks them":
    let build = scratch("nomask")
    defer: removeDir(build)
    let (o, code) = run(["run", here / "clock-capture.yaml", "--pack", pack, "--backend",
                         "refapp-no-mask", "--record", "always", "--deterministic", "--pin", "clock"],
                        [("BUILD_DIR", build)])
    checkpoint o
    check code == 3
    check "--pin needs record.mask" in o

  test "a stopped clock is not volatile":
    let build = scratch("stopped")
    defer: removeDir(build)
    let (o, code) = run(["run", here / "stopped-clock-capture.yaml", "--pack", pack, "--backend",
                         "refapp", "--record", "always", "--deterministic"], [("BUILD_DIR", build)])
    checkpoint o
    check code == 0

  test "a citation resolves to the capture the named step produced":
    let build = scratch("cite")
    defer: removeDir(build)
    check run(["run", here / "clock-capture.yaml", "--pack", pack, "--backend", "refapp",
               "--record", "always", "--deterministic", "--pin", "clock"],
              [("BUILD_DIR", build)]).code == 0
    let (p, c) = run(["capture-path", "scenario=recordings/clock-capture", "capture=last-selected",
                      "--build", build])
    check c == 0
    let path = p.strip
    # the sixth step produced it
    check path.extractFilename == "6-last-selected.txt"
    check fileExists(path)
    let m = parseJson(readFile(path.parentDir.parentDir / "manifest.json"))
    check m["steps"][5]["name"].getStr == "last-selected"
    check m["steps"][5]["artifacts"][0].getStr == path
    # a capture no step produced is not resolved
    let (o2, c2) = run(["capture-path", "scenario=recordings/clock-capture", "capture=nothing",
                        "--build", build])
    check c2 == 1
    check "no step" in o2
    # a span of steps, on the virtual timeline of a deterministic run
    let (s, c3) = run(["capture-path", "scenario=recordings/clock-capture", "steps=2..4",
                       "--build", build])
    check c3 == 0
    let span = parseJson(s.strip.splitLines[^1])
    check span["virtual"].getBool
    check span["fromMs"].getFloat == m["steps"][1]["virtualStartMs"].getFloat
    check span["toMs"].getFloat == m["steps"][3]["virtualEndMs"].getFloat
