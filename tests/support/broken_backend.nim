## A backend that breaks the protocol on purpose, for the transport tests.
##
## It is the one stand-in in this repository's tests, and it is not a mock: it
## does not imitate a working backend's answers for the runner to pass; it is a
## real process speaking the real protocol until it misbehaves in the named
## way, so that the runner's handling of a broken backend is exercised over a
## real pipe.
##
##   broken_backend non-json|exit|exit-later|silent|wrong-id|unsettled|slow-stage|slow-settle
##
## `exit-later` works for the first step that locates a target and exits, as
## `exit` does, at the second: the backend dies in the middle of a scenario,
## with steps before it that passed and steps after it that are not run.
##
## `unsettled` is a backend whose application never settles: it locates the
## one target a step names and takes the input, and then answers every
## `settled` with "not met" — the runner's settle timeout is what ends the
## step.
##
## `slow-settle` is a backend whose application keeps redrawing for 7 s after
## every input, as a heavy redraw on a loaded machine does, and then settles.
## Its `settled` waits as a backend's does, until the deadline or the settle,
## and reports the application still changing (`progress`) when the deadline
## comes first: past a fixed 5 s bound, and within the runner's settle cap.
##
## `slow-stage` is a backend whose stage takes 1.5 s, as one that records a
## program or starts a large application takes long; after it, it works. Its stage
## refuses a call without the run's time limit (`$timeoutMs`), so a run that
## passes shows the limit arrived.

import std/[json, os, monotimes, times]

const RedrawMs = 7000   ## `slow-settle`: how long the application redraws after an input

let mode = (if paramCount() >= 1: paramStr(1) else: "non-json")
var locates = 0
var lastInput = getMonoTime()
var line: string
while stdin.readLine(line):
  let req = parseJson(line)
  let id = req["id"]
  case req["call"].getStr
  of "hello":
    echo $(%*{"id": id, "ok": true, "backend": "broken", "version": "1", "platform": "linux",
              "capabilities": ["input.key", "input.pointer.click", "observe.text"], "units": "cell"})
  of "stage":
    if mode == "slow-stage":
      if req{"with"}{"$timeoutMs"}.getInt(0) <= 0:
        echo $(%*{"id": id, "ok": false,
                  "error": {"kind": "stage", "message": "the stage call carries no $timeoutMs"}})
        stdout.flushFile()
        continue
      sleep(1500)
    echo $(%*{"id": id, "ok": true})
  of "end-stage":
    echo $(%*{"id": id, "ok": true})
  of "locate":
    inc locates
    if mode in ["unsettled", "slow-stage", "slow-settle"] or mode == "exit-later" and locates == 1:
      echo $(%*{"id": id, "ok": true, "outcome": "one", "instance": "0", "role": "search-field"})
      stdout.flushFile()
      continue
    case mode
    of "non-json": echo "this is not a protocol line"
    of "exit", "exit-later":
      stderr.writeLine "broken_backend: exiting in the middle of a step"
      quit 3
    of "silent": sleep(60_000)
    of "wrong-id": echo $(%*{"id": id.getInt + 7, "ok": true, "outcome": "none"})
    else: discard
  of "send":
    lastInput = getMonoTime()
    echo $(%*{"id": id, "ok": true})
  of "await":
    if mode == "slow-settle":
      let left = RedrawMs - (getMonoTime() - lastInput).inMilliseconds
      let timeout = req{"timeoutMs"}.getInt(5000)
      if left <= timeout:
        sleep(int(max(0, left)))
        echo $(%*{"id": id, "ok": true, "met": true})
      else:
        sleep(timeout)
        echo $(%*{"id": id, "ok": true, "met": false, "progress": true})
    else:
      echo $(%*{"id": id, "ok": true, "met": mode != "unsettled"})
  of "shutdown":
    echo $(%*{"id": id, "ok": true})
    quit 0
  else:
    echo $(%*{"id": id, "ok": true})
  stdout.flushFile()
