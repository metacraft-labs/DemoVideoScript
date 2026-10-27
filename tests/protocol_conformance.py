#!/usr/bin/env python3
"""Every message the runner and a backend exchange matches the published
backend-protocol schema, in both directions.

Runs the corpus against an out-of-process backend with a protocol transcript
(DVS_PROTOCOL_TRANSCRIPT) and validates every line with an independent JSON
Schema implementation. No stand-ins: the real runner talks to a real backend.

    python3 tests/protocol_conformance.py <dvs> <pack> <backend-command> <scenario>...
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import jsonschema

ROOT = Path(__file__).resolve().parent.parent
schema = json.loads((ROOT / "schemas/v1/backend-protocol.schema.json").read_text())
V = jsonschema.Draft202012Validator(schema)
req = jsonschema.Draft202012Validator({**schema, "oneOf": [{"$ref": "#/$defs/request"}]})
EMPTY = {"stage", "end-stage", "send", "shutdown"}


def response_validator(call):
    name = "empty" if call in EMPTY else call
    return jsonschema.Draft202012Validator(
        {**schema, "oneOf": [{"$ref": f"#/$defs/response-{name}"}, {"$ref": "#/$defs/response-error"}]})

dvs, pack, backend, *scenarios = sys.argv[1:]
bad = 0
count = 0
with tempfile.TemporaryDirectory() as d:
    t = Path(d) / "transcript"
    for mode in ("fast", "realistic"):
        for s in scenarios:
            subprocess.run([dvs, "run", s, "--pack", pack, "--backend", backend, "--mode", mode,
                            "--record", "off"], env={**os.environ, "DVS_PROTOCOL_TRANSCRIPT": str(t)},
                           capture_output=True)
    calls = {}
    for line in t.read_text().splitlines():
        direction, msg = line[:2], json.loads(line[2:])
        if direction == "> ":
            v = req
            calls[msg.get("id")] = msg.get("call")
        else:
            v = response_validator(calls.get(msg.get("id"), "?"))
        errs = list(v.iter_errors(msg))
        count += 1
        if errs:
            bad += 1
            print("INVALID", direction, line[2:200], "--", errs[0].message[:200])
print(f"protocol conformance: {count} messages, {bad} invalid")
sys.exit(1 if bad or count == 0 else 0)
