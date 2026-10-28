## `dvs-ref` — the `dvs` command line with the reference backend linked in
## process: `--backend refapp`, and one backend per planted defect
## (`refapp-stale-read`, `refapp-off-by-one`, `refapp-early-sync`,
## `refapp-read-side-effect`).

import std/tables
import demo_video_script/[backend, cli]
import ./refapp_backend

when isMainModule:
  var builtins = initTable[string, BackendFactory]()
  builtins["refapp"] = proc (): Backend = newRefappBackend()
  for d in [dfStaleRead, dfOffByOne, dfEarlySync, dfReadSideEffect]:
    let defect = d
    builtins["refapp-" & $d] = proc (): Backend = newRefappBackend(defect)
  builtins["refapp-no-drag"] = proc (): Backend =
    newRefappBackend(dfNone, @["input.pointer.drag"])
  builtins["refapp-no-mask"] = proc (): Backend =
    newRefappBackend(dfNone, @["record.mask"])
  dvsMain(builtins)
