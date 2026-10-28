#!/usr/bin/env python3
"""DVS-7 verification gate: test-run recordings and documentation captures.

Each arm is a defect in where a recording goes, which runs are kept, what a
deterministic capture checks, how a citation resolves, or how a lane judges
its runs; the kill command builds the binaries and runs the recordings suite
(real runs of the reference backend, in process and over JSON lines).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REC = "src/demo_video_script/recordings.nim"
CLI = "src/demo_video_script/cli.nim"
R = "src/demo_video_script/runner.nim"

ARMS = [
    Arm("C1", REC, "    if k < policy.runs: continue", "    if k < policy.runs - 1: continue",
        "retention keeping one run too few"),
    Arm("C2", REC, "    if r.failed and r.started >= horizon: continue", "    discard horizon",
        "retention deleting a failure younger than the horizon"),
    Arm("C3", CLI, "      group = runGroupDir(buildDir, sc.name, name)",
        "      group = runGroupDir(getTempDir(), sc.name, name)",
        "a recording written outside the build directory"),
    Arm("C4", REC, "    if d.isInside(loc):", "    if false:",
        "a recording allowed into a shared state directory"),
    Arm("C5", R, "    elif readFile(f) != readFile(g):", "    elif false:",
        "a volatile region ignored"),
    Arm("C6", R, "          args[\"mask\"] = r.pinnedInstances()\n",
        "          discard\n", "a declared volatile region not masked"),
    Arm("C7", R, "    let took = (if opts.deterministic: 0.0 else: sr.endMs - sr.startMs)",
        "    let took = sr.endMs - sr.startMs", "the machine's time in a deterministic timeline"),
    Arm("C8", REC, '    if s{"kind"}.getStr == "capture" and s{"name"}.getStr == capture:',
        '    if s{"kind"}.getStr == "capture":', "a citation resolved without its capture name"),
    Arm("C9", CLI, "      of roUnsupported:\n        if applicable:",
        "      of roUnsupported:\n        if false:",
        "a lane passing an unexpected unsupported"),
    Arm("C10", R, '        writeFile(opts.runDir / "failure" / "backend.log",',
        '        if false: writeFile(opts.runDir / "failure" / "backend.log",',
        "a failure bundle without the backend's log"),
]

if __name__ == "__main__":
    main("dvs7", ROOT, ARMS, ["just", "build", "test-recordings"])
