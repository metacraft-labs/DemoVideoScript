## A backend that breaks the protocol on purpose, for the transport tests.
##
## It is the one stand-in in this repository's tests, and it is not a mock: it
## does not imitate a working backend's answers for the runner to pass; it is a
## real process speaking the real protocol until it misbehaves in the named
## way, so that the runner's handling of a broken backend is exercised over a
## real pipe.
##
##   broken_backend non-json|exit|silent|wrong-id|unsettled|slow-stage
##
## `unsettled` is a backend whose application never settles: it locates the
## one target a step names and takes the input, and then answers every
## `settled` with "not met" — the runner's settle timeout is what ends the
## step.
##
## `slow-stage` is a backend whose stage takes 1.5 s, as one that records a
## program or starts a large application takes long; after it, it works. Its stage
## refuses a call without the run's time limit (`$timeoutMs`), so a run that
## passes shows the limit arrived.

import std/[json, os]

let mode = (if paramCount() >= 1: paramStr(1) else: "non-json")
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
    if mode in ["unsettled", "slow-stage"]:
      echo $(%*{"id": id, "ok": true, "outcome": "one", "instance": "0", "role": "search-field"})
      stdout.flushFile()
      continue
    case mode
    of "non-json": echo "this is not a protocol line"
    of "exit":
      stderr.writeLine "broken_backend: exiting in the middle of a step"
      quit 3
    of "silent": sleep(60_000)
    of "wrong-id": echo $(%*{"id": id.getInt + 7, "ok": true, "outcome": "none"})
    else: discard
  of "await":
    echo $(%*{"id": id, "ok": true, "met": mode != "unsettled"})
  of "shutdown":
    echo $(%*{"id": id, "ok": true})
    quit 0
  else:
    echo $(%*{"id": id, "ok": true})
  stdout.flushFile()
