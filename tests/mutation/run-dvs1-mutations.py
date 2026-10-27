#!/usr/bin/env python3
"""DVS-1 verification gate: the format's parser, schema and linter.

Every arm is a defect the format's tests must notice. The kill command is the
full `just test` (unit suites, the command-line suite on the built binary, and
the schema/parser agreement check against independent reference
implementations). See mutation_engine.py for the protocol.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
G = "src/demo_video_script/grammar.nim"
S = "src/demo_video_script/scenario.nim"
L = "src/demo_video_script/lint.nim"

ARMS = [
    Arm("G1", G, "    result.modifiers.incl parseModifier(parts[k])",
        "    discard parseModifier(parts[k])", "a modifier dropped from a parsed chord"),
    Arm("G2", G, "(if platform == platMacos: modMeta else: modCtrl)",
        "(if platform == platMacos: modCtrl else: modMeta)", "Mod resolved to the wrong platform key"),
    Arm("G3", G, "            seg.keys.add (k, v)", "            seg.ordinal = 1",
        "a locator key parsed as an ordinal"),
    Arm("S1", S, "  elif ver.numValue != float(ImplementedVersion):", "  elif false:",
        "the version check removed"),
    Arm("S2", S, '    elif k.s in AnnotationKeys or k.s in ["settle", "steps", "with"]: discard',
        "    elif true: discard", "L1: an unknown step key accepted"),
    Arm("S3", S, '    elif k.s == "use" or k.s == "stage":', "    elif false:",
        "L1: a stage call in steps no longer named as one"),
    Arm("L2", L, "        if kv.key notin role.keys:", "        if false:",
        "L2: a locator key that is not a declared key accepted"),
    Arm("L2p", L, "    if not l.pack.roles[role].properties.hasKey(p):", "    if false:",
        "L2: an undeclared property observed"),
    Arm("L3", L, "  if aff notin l.pack.roles[role].affordances:", "  if false:",
        "L3: the affordance check removed"),
    Arm("L4", L, '      if seg.ordinal > 0:\n        l.warn(line, col, "L4"',
        '      if false:\n        l.warn(line, col, "L4"', "L4: an ordinal accepted without a warning"),
    Arm("L5", L, "if s.kind in InputKinds and not s.settle and next != nil",
        "if s.kind in InputKinds and s.settle and next != nil", "L5: the settle condition inverted"),
    Arm("L6", L, "if s.dwell >= 0 and next != nil", "if s.dwell > 100000 and next != nil",
        "L6: a dwell before an observation not warned"),
    Arm("L7", L, "  if not l.pack.sync.hasKey(name):", "  if false:",
        "L7: an undeclared sync condition accepted"),
    Arm("L8", L, "    if backend notin l.sc.requires:", "    if false:",
        "L8: an extension step without its backend accepted"),
    Arm("L9", L, 'proc known(name: string): bool = name == "" or ids.hasKey(name) or beats.hasKey(name)',
        "proc known(name: string): bool = true", "L9: a dangling narration anchor accepted"),
    Arm("L10", L, "    if role.name in rk:", "    if false:", "L10: a role named like a keyword accepted"),
    Arm("L11", L, '      if d.severity == sevError:\n        l.diags.add Diagnostic(rule: "L11"',
        '      if false:\n        l.diags.add Diagnostic(rule: "L11"', "L11: a flow violating L1 accepted"),
    Arm("L12", L, "      if captures.hasKey(s.name): dups.add", "      if false: dups.add",
        "L12: duplicate capture names accepted"),
    Arm("SC1", "tools/generate_schemas.py", "        variants.append(obj([name], props))",
        '        variants.append({**obj([name], props), "additionalProperties": True})',
        "the published schema's steps relaxed to accept unknown keys",
        pre=[["python3", "tools/generate_schemas.py"]],
        restore=["schemas/v1/scenario.schema.json", "schemas/v1/pack.schema.json"]),
]

if __name__ == "__main__":
    main("dvs1", ROOT, ARMS, ["just", "test"])
