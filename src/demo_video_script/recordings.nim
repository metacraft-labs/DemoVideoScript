## Test-run recordings and documentation captures (§9): where a run directory
## may be, which ones the next run keeps, and how a citation of a capture
## resolves to a file.
##
## A run directory is `<build>/scenario-runs/<scenario>/<backend>/<run-id>/`.
## It is never the user's home directory, nor inside a shared configuration,
## state, data or cache directory: a recording may hold whatever was on screen,
## and those directories are read by other programs and backed up.
##
## Retention (decision D8): the last `runs` run directories per
## (scenario, backend), and every failed one younger than `failureDays`;
## the rest is deleted by the next run that records.
##
## A page cites a capture by scenario and capture name — never by a path —
## and the path is looked up in the newest run's manifest, from the step that
## produced the capture.

import std/[json, os, strutils, times, algorithm, options]

type
  RetentionPolicy* = object
    runs*: int            ## the newest run directories kept, whatever their outcome
    failureDays*: float   ## failed runs younger than this are kept too

  RunDirError* = object of CatchableError

  CastSpan* = object
    file*: string         ## the cast (or video) of the run
    fromMs*, toMs*: float ## offsets on the media's own timeline
    virtual*: bool        ## offsets are virtual time (a deterministic run)

const DefaultRetention* = RetentionPolicy(runs: 5, failureDays: 7)

proc runsRoot*(buildDir: string): string = buildDir / "scenario-runs"

proc safeName*(s: string): string =
  ## A scenario or backend name as one path component.
  for c in s:
    result.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}: c else: '-')
  if result.len == 0 or result == "." or result == "..": result = "-"

proc runGroupDir*(buildDir, scenario, backend: string): string =
  runsRoot(buildDir) / safeName(scenario) / safeName(backend)

proc newRunId*(t = now().utc): string =
  t.format("yyyyMMdd'T'HHmmss'.'fff'Z'")

proc defaultRunDir*(buildDir, scenario, backend: string; runId = newRunId()): string =
  runGroupDir(buildDir, scenario, backend) / runId

proc isInside(path, dir: string): bool =
  let p = path.normalizedPath
  let d = dir.normalizedPath
  p == d or p.startsWith(d & DirSep)

proc refusedLocations(): seq[(string, string)] =
  ## The directories a recording must not go into, and what each one is.
  let home = getHomeDir().normalizedPath
  proc xdg(name, default: string): string =
    let v = getEnv(name)
    (if v.len > 0 and v.isAbsolute: v else: home / default).normalizedPath
  result = @[
    (xdg("XDG_CONFIG_HOME", ".config"), "the user's configuration directory"),
    (xdg("XDG_STATE_HOME", ".local/state"), "the user's state directory"),
    (xdg("XDG_DATA_HOME", ".local/share"), "the user's data directory"),
    (xdg("XDG_CACHE_HOME", ".cache"), "the user's cache directory")]
  for d in ["/etc", "/var", "/usr", "/nix", "/opt"]:
    result.add (d, "a shared system directory")

proc checkRunDir*(dir: string) =
  ## Raises `RunDirError` when a recording may not be written to `dir`.
  let d = dir.absolutePath.normalizedPath
  let home = getHomeDir().normalizedPath
  if d == home or d == home.parentDir or d == "/":
    raise newException(RunDirError, "a recording is not written to " & d &
      ": it goes under the build directory (<build>/scenario-runs/…)")
  for (loc, what) in refusedLocations():
    if d.isInside(loc):
      raise newException(RunDirError, "a recording is not written inside " & what & " (" &
        loc & "): it goes under the build directory (<build>/scenario-runs/…)")

# --- retention -------------------------------------------------------------------------

type RunEntry = object
  dir: string
  started: Time
  failed: bool

proc readEntry(dir: string): Option[RunEntry] =
  let m = dir / "manifest.json"
  if not fileExists(m): return none(RunEntry)
  var j: JsonNode
  try: j = parseFile(m)
  except CatchableError: return none(RunEntry)
  var started = getLastModificationTime(m)
  let s = j{"startedAt"}.getStr
  if s.len > 0:
    try: started = parse(s, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()).toTime
    except CatchableError: discard
  some(RunEntry(dir: dir, started: started,
                failed: j{"outcome"}.getStr in ["failed", "error"]))

proc prune*(groupDir: string; policy = DefaultRetention; now = getTime()): seq[string] =
  ## Deletes the run directories of one (scenario, backend) that `policy`
  ## does not keep, and returns them. A directory without a readable
  ## manifest is not a run and is left alone.
  if not dirExists(groupDir): return
  var runs: seq[RunEntry]
  for kind, path in walkDir(groupDir):
    if kind != pcDir: continue
    let e = readEntry(path)
    if e.isSome: runs.add e.get
  runs.sort(proc (a, b: RunEntry): int = cmp(b.started, a.started))   # newest first
  let horizon = now - initDuration(seconds = int64(policy.failureDays * 86400))
  for k, r in runs:
    if k < policy.runs: continue
    if r.failed and r.started >= horizon: continue
    removeDir(r.dir)
    result.add r.dir

# --- citations --------------------------------------------------------------------------

proc newestRun*(buildDir, scenario: string; backend = ""): string =
  ## The newest run directory of `scenario` (on `backend`, or on any) that has
  ## a manifest; "" when there is none.
  let root = runsRoot(buildDir) / safeName(scenario)
  if not dirExists(root): return ""
  var best: Option[RunEntry]
  for kind, b in walkDir(root):
    if kind != pcDir: continue
    if backend.len > 0 and b.lastPathPart != safeName(backend): continue
    for kind2, r in walkDir(b):
      if kind2 != pcDir: continue
      let e = readEntry(r)
      if e.isSome and (best.isNone or e.get.started > best.get.started): best = e
  if best.isSome: best.get.dir else: ""

proc capturePaths*(runDir, capture: string): seq[string] =
  ## The files of the capture named `capture`, from the step that produced it
  ## in `runDir`'s manifest. Raises `KeyError` when no step produced it.
  let j = parseFile(runDir / "manifest.json")
  for s in j{"steps"}.getElems:
    if s{"kind"}.getStr == "capture" and s{"name"}.getStr == capture:
      for a in s{"artifacts"}.getElems:
        let p = a.getStr
        result.add(if p.isAbsolute: p else: runDir / p)
      if result.len == 0:
        raise newException(KeyError, "the capture '" & capture & "' produced no file in " & runDir)
      return
  raise newException(KeyError, "no step of " & runDir / "manifest.json" &
    " produced a capture named '" & capture & "'")

proc castSpan*(runDir: string; fromStep, toStep: int): CastSpan =
  ## The span of the run's cast (or video) from the start of step `fromStep`
  ## to the end of step `toStep`, on the media's own timeline: virtual time in
  ## a deterministic run, else the run's own clock.
  let j = parseFile(runDir / "manifest.json")
  let media = j{"media"}.getElems
  if media.len == 0: raise newException(KeyError, "the run in " & runDir & " recorded no media")
  result.file = media[0].getStr
  result.virtual = j{"deterministic"}.getBool(false)
  let key0 = (if result.virtual: "virtualStartMs" else: "startMs")
  let key1 = (if result.virtual: "virtualEndMs" else: "endMs")
  let origin = j{"recordingStartMs"}.getFloat(0)
  var found = 0
  for s in j{"steps"}.getElems:
    let i = s{"index"}.getInt
    if i == fromStep:
      result.fromMs = s{key0}.getFloat - (if result.virtual: 0.0 else: origin)
      inc found
    if i == toStep:
      result.toMs = s{key1}.getFloat - (if result.virtual: 0.0 else: origin)
      inc found
  if found < 2 or toStep < fromStep:
    raise newException(KeyError, "no steps " & $fromStep & ".." & $toStep & " in " & runDir)
