#!/usr/bin/env python3
"""DVS-2 verification gate: the runner, the protocol and the reference backend.

Each arm is a defect in the runner's own semantics (capability check, stage
boundary, synchronisation, matching, timing) or in the transport, and must turn
`just test` red. See mutation_engine.py for the protocol.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
R = "src/demo_video_script/runner.nim"
E = "src/demo_video_script/eval.nim"
J = "src/demo_video_script/jsonlines.nim"
A = "conformance/refapp/refapp_backend.nim"

CHECK = '''  if missing.len > 0:
    r.res.unsupported = missing
    var parts: seq[string]
    for u in missing: parts.add "step " & u.path & " needs " & u.capability
    finish(roUnsupported, "not applicable on backend '" & r.hello.backend & "': " & parts.join("; "))
'''
STAGE = '''  # the stage, then the stage channel closes
  try:
    for call in sc.stage:
      var args = (if call.args == nil: newJObject() else: call.args.toJson)
      args["$base"] = %opts.scenarioDir
      b.stage(call.use, args)
    b.endStage()
  except BackendError as e:
    finish(roError, "stage: " & e.msg)
'''

ARMS = [
    Arm("R1", R, CHECK + STAGE, STAGE + CHECK, "the capability check moved after the stage"),
    Arm("R2", R, "      b.stage(call.use, args)\n    b.endStage()",
        "      b.stage(call.use, args)\n    discard", "the stage channel left open"),
    Arm("R3", R, "  if not s.settle: return\n", "  return\n", "the implicit settled removed"),
    Arm("R4", R, "      if not evalMatcher(m, vals[p]):", "      if evalMatcher(m, vals[p]):",
        "a matcher's verdict inverted"),
    Arm("R5", E, "  of relAbove: a.y + a.h <= b.y + t", "  of relAbove: b.y + b.h <= a.y + t",
        "a geometry relation's comparison swapped"),
    Arm("R6", R, '    finish(roUnsupported, "not applicable', '    finish(roPassed, "not applicable',
        "unsupported reported as passed"),
    Arm("R7", R, '      fail("waited " & $timeout & " ms; the condition never held: " & last)',
        "      return", "a wait that passes on timeout"),
    Arm("R8", R, "if s.dwell > 0 and opts.mode == tmRealistic:", "if s.dwell > 0:",
        "dwell enacted in fast mode"),
    Arm("R9", R, "  r.opts.seed * 1_000_003 + r.seedCounter", "  1_000_003 + r.seedCounter",
        "the pacing seed ignored"),
    Arm("R10", E, "    of qEvery: (for r in results: (if not r: return %false)); %true",
        "    of qEvery: %true", "a named assertion's quantifier always true"),
    Arm("R11", R, "  if o.absent == 1:", "  if o.absent == 2:", "absent no longer observed"),
    Arm("R12", R, "    if again != result:", "    if false:",
        "the side-effect probe of reads disabled"),
    Arm("J1", J, 'j{"id"}.getInt(-1) != c.nextId or', "false or",
        "a response to another request accepted"),
    Arm("J2", J, "        c.dead = true\n        c.drainErr()",
        "        c.dead = false\n        c.drainErr()\n        return \"\"",
        "a backend's exit read as an empty answer"),
    Arm("A1", A, "    if st.stageClosed:", "    if false:", "the backend accepts stage calls after end-stage"),
]

if __name__ == "__main__":
    main("dvs2", ROOT, ARMS, ["just", "test"])
