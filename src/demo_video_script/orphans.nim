## What a backend leaves behind does not outlive the run (Linux).
##
## A backend's helpers — the ChromeDriver WebDriverIO starts DETACHED, the
## editor or server a binding starts — are its children. When the backend
## ends without stopping them (the runner gives it a few seconds after
## `shutdown`, then a SIGTERM; a crashed backend gets none), they are
## reparented and keep running, with their browsers, until someone notices:
## 22 ChromeDrivers on one host, some at 64 % CPU for 9 hours.
##
## `dvs` therefore makes itself the child subreaper of everything it starts
## (`PR_SET_CHILD_SUBREAPER`): an orphaned descendant becomes `dvs`'s child
## instead of init's. A child of `dvs` in another session than `dvs`'s is a
## detached helper whose starter has gone (the backends themselves share
## `dvs`'s session), and a reaper stops it, with its own children, within a
## couple of seconds — so a lane does not carry one scenario's leftovers
## through the next. When `dvs` exits, every descendant still running is
## stopped. `DVS_KEEP_ORPHANS=1` turns both off.

when defined(linux):
  import std/[exitprocs, os, posix, strutils]

  proc prctl(option: cint; arg2: culong): cint {.importc, header: "<sys/prctl.h>", varargs.}
  const PrSetChildSubreaper = 36.cint

  type ProcInfo = object
    pid, ppid, session: int
    state: char

  proc procInfo(pid: int): ProcInfo =
    ## /proc/<pid>/stat: `pid (comm) state ppid pgrp session …`; comm may
    ## hold spaces and parentheses, so fields are read after the last ')'.
    result.pid = -1
    try:
      let s = readFile("/proc/" & $pid & "/stat")
      let close = s.rfind(')')
      if close < 0: return
      let f = s[close + 2 .. ^1].splitWhitespace
      if f.len < 4: return
      result = ProcInfo(pid: pid, state: f[0][0], ppid: parseInt(f[1]), session: parseInt(f[3]))
    except CatchableError:
      discard

  proc allProcs(): seq[ProcInfo] =
    for kind, path in walkDir("/proc"):
      if kind != pcDir: continue
      let name = path.extractFilename
      if name.len == 0 or not name.allCharsInSet(Digits): continue
      let info = procInfo(parseInt(name))
      if info.pid > 0: result.add info

  proc descendantsOf(procs: seq[ProcInfo]; pid: int): seq[int] =
    for p in procs:
      if p.ppid == pid:
        result.add descendantsOf(procs, p.pid)
        result.add p.pid

  proc stop(procs: seq[ProcInfo]; pid: int) =
    ## `pid` and everything under it, then collect `pid` (it is our child).
    for d in descendantsOf(procs, pid):
      discard kill(d.Pid, SIGKILL)
    discard kill(pid.Pid, SIGKILL)
    var status: cint
    discard waitpid(pid.Pid, status, 0)

  proc reapDetachedOrphans*() =
    ## Stop every child of this process that lives in another session: a
    ## detached helper reparented here when the backend that started it ended.
    let me = getpid().int
    let mySession = getsid(0).int
    let procs = allProcs()
    for p in procs:
      if p.ppid != me or p.session == mySession: continue
      stop(procs, p.pid)

  proc stopAllDescendants*() =
    ## At exit: nothing this process started is left running. Twice: a
    ## backend that exits during the first pass hands its helpers to this
    ## process only after the pass has read the process table.
    let me = getpid().int
    for pass in 0 .. 1:
      if pass > 0: sleep(100)
      let procs = allProcs()
      for p in procs:
        if p.ppid == me: stop(procs, p.pid)

  var reaper: Thread[int]

  proc reaperLoop(intervalMs: int) {.thread.} =
    while true:
      sleep(intervalMs)
      reapDetachedOrphans()

  proc installOrphanReaper*(intervalMs = 2000) =
    if getEnv("DVS_KEEP_ORPHANS") == "1": return
    discard prctl(PrSetChildSubreaper, 1.culong)
    addExitProc(stopAllDescendants)
    createThread(reaper, reaperLoop, intervalMs)
else:
  proc installOrphanReaper*(intervalMs = 2000) = discard
