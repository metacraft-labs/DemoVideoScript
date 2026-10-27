## A backend that breaks the protocol on purpose, for the transport tests.
##
## It is the one stand-in in this repository's tests, and it is not a mock: it
## does not imitate a working backend's answers for the runner to pass; it is a
## real process speaking the real protocol until it misbehaves in the named
## way, so that the runner's handling of a broken backend is exercised over a
## real pipe.
##
##   broken_backend non-json|exit|silent|wrong-id

import std/[json, os, strutils]

let mode = (if paramCount() >= 1: paramStr(1) else: "non-json")
var line: string
while stdin.readLine(line):
  let req = parseJson(line)
  let id = req["id"]
  case req["call"].getStr
  of "hello":
    echo $(%*{"id": id, "ok": true, "backend": "broken", "version": "1", "platform": "linux",
              "capabilities": ["input.key", "input.pointer.click", "observe.text"], "units": "cell"})
  of "stage", "end-stage":
    echo $(%*{"id": id, "ok": true})
  of "locate":
    case mode
    of "non-json": echo "this is not a protocol line"
    of "exit":
      stderr.writeLine "broken_backend: exiting in the middle of a step"
      quit 3
    of "silent": sleep(60_000)
    of "wrong-id": echo $(%*{"id": id.getInt + 7, "ok": true, "outcome": "none"})
    else: discard
  of "shutdown":
    echo $(%*{"id": id, "ok": true})
    quit 0
  else:
    echo $(%*{"id": id, "ok": true})
  stdout.flushFile()
