## A backend's detached helper does not outlive the run (Linux).
##
## The backend here is the reference application's (`dvs-refapp`), started by
## a shell that first starts a DETACHED `sleep` in a session of its own — what
## WebDriverIO does with ChromeDriver — and then becomes the backend (`exec`),
## so the helper is the backend's child. The scenario runs to its end; the
## backend exits without stopping the helper. Afterwards the helper must be
## gone. CONTROL: with `DVS_KEEP_ORPHANS=1` it is still running, so the check
## can fail.
##
## No stand-ins: the built `dvs` and `dvs-refapp`, a real scenario, real
## processes.

import std/[os, posix, strutils, unittest]

let root = currentSourcePath().parentDir.parentDir
let binDir = getEnv("DVS_BIN_DIR", root / "build/bin")
let dvs = binDir / "dvs"
let refapp = binDir / "dvs-refapp"

proc alive(pid: int): bool =
  ## Running, and not a zombie waiting to be collected.
  if kill(pid.Pid, 0) != 0: return false
  try:
    let s = readFile("/proc/" & $pid & "/stat")
    return s[s.rfind(')') + 2] != 'Z'
  except IOError:
    return false

proc runWithHelper(keepOrphans: bool): int =
  let dir = getTempDir() / ("dvs-orphans-" & $getpid())
  createDir(dir)
  defer: removeDir(dir)
  let pidFile = dir / "helper.pid"
  let wrapper = dir / "backend.sh"
  writeFile(wrapper, "#!/bin/bash\n" &
    "setsid sleep 600 </dev/null >/dev/null 2>&1 &\n" &
    "echo $! > " & quoteShell(pidFile) & "\n" &
    "exec " & quoteShell(refapp) & "\n")
  # The run's output goes to a file: a helper that outlives the run keeps
  # whatever it inherited open, and a pipe would never reach end of file.
  let log = dir / "run.log"
  let cmd = (if keepOrphans: "DVS_KEEP_ORPHANS=1 " else: "") &
    quoteShell(dvs) & " run " &
    quoteShell(root / "conformance/scenarios/archive-from-keyboard.yaml") &
    " --pack " & quoteShell(root / "conformance/pack/notes-app.pack.yaml") &
    " --backend " & quoteShell("cmd:bash " & wrapper) &
    " </dev/null >" & quoteShell(log) & " 2>&1"
  let code = execShellCmd(cmd)
  check code == 0
  if code != 0: echo readFile(log)
  parseInt(readFile(pidFile).strip)

proc runWithOrphans(dir: string): tuple[traced, untraced: string] =
  ## A backend that, before it starts, leaves two orphans in sessions of their
  ## own while the run goes on: one traced by a process that stays (what rr
  ## does with a replay's checkpoints) and one not.  It waits past several
  ## reaper passes (2 s each), records which are still running, and becomes
  ## the backend.
  let wrapper = dir / "backend.sh"
  writeFile(wrapper, "#!/bin/bash\n" &
    "python3 " & quoteShell(root / "tests/support/trace_orphan.py") & " " &
      quoteShell(dir / "traced.pid") & " &\n" &
    "bash -c 'setsid sleep 600 </dev/null >/dev/null 2>&1 & echo $! > " &
      quoteShell(dir / "untraced.pid") & "'\n" &
    "for i in $(seq 50); do [ -s " & quoteShell(dir / "traced.pid") & " ] && break; sleep 0.1; done\n" &
    "sleep 7\n" &
    "for k in traced untraced; do p=$(cat " & quoteShell(dir) & "/$k.pid); " &
      "if [ -d /proc/$p ] && ! grep -q '^State:.*Z' /proc/$p/status; then echo running; else echo gone; fi > " &
      quoteShell(dir) & "/$k.state; done\n" &
    "exec " & quoteShell(refapp) & "\n")
  let log = dir / "run.log"
  let code = execShellCmd(quoteShell(dvs) & " run " &
    quoteShell(root / "conformance/scenarios/archive-from-keyboard.yaml") &
    " --pack " & quoteShell(root / "conformance/pack/notes-app.pack.yaml") &
    " --backend " & quoteShell("cmd:bash " & wrapper) &
    " </dev/null >" & quoteShell(log) & " 2>&1")
  check code == 0
  if code != 0: echo readFile(log)
  for k in ["traced", "untraced"]:
    try: discard kill(parseInt(readFile(dir / (k & ".pid")).strip).Pid, SIGKILL)
    except CatchableError: discard
  (readFile(dir / "traced.state").strip, readFile(dir / "untraced.state").strip)

when defined(linux):
  suite "an orphan reparented to dvs during the run":
    test "is left to its tracer when traced, and stopped when not":
      let dir = getTempDir() / ("dvs-traced-orphan-" & $getpid())
      createDir(dir)
      defer: removeDir(dir)
      let (traced, untraced) = runWithOrphans(dir)
      # The untraced one is the control: the reaper ran, and stops a
      # detached orphan, so a traced one still running was spared by the rule.
      check untraced == "gone"
      check traced == "running"

  suite "a backend's detached helper":
    test "is stopped when the run ends":
      let helper = runWithHelper(keepOrphans = false)
      var gone = false
      for _ in 0 ..< 50:
        if not alive(helper):
          gone = true
          break
        sleep(100)
      if not gone: discard kill(helper.Pid, SIGKILL)
      check gone

    test "CONTROL: survives the run when orphans are kept":
      let helper = runWithHelper(keepOrphans = true)
      sleep(1000)
      check alive(helper)
      discard kill(helper.Pid, SIGKILL)
