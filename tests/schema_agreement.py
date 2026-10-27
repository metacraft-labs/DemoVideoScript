#!/usr/bin/env python3
"""The published JSON Schemas and the Nim parser agree, and so do the YAML readers.

For every scenario and pack file in the conformance corpus and the test fixtures:

1. An independent YAML 1.2 reader (ruamel.yaml, safe loader) and the Nim reader
   (`dvs yaml`) read the same tree, or both refuse the file.
2. An independent JSON Schema validator (jsonschema, Draft 2020-12) and the Nim
   parser (`dvs lint --json`, structural diagnostics only) give the same verdict.

Files under tests/schema/refused-yaml/ are valid YAML that the Nim reader refuses
by name (anchors, aliases, tags, explicit keys, several documents); for them the
test checks that ruamel reads them and the Nim reader names the feature.

No mocks: both sides are real implementations reading real files. Usage:

    python3 tests/schema_agreement.py <path-to-dvs-binary>
"""
import io
import json
import math
import subprocess
import sys
from pathlib import Path

import jsonschema
from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError

ROOT = Path(__file__).resolve().parent.parent
DVS = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "build" / "bin" / "dvs")

SCENARIO = json.loads((ROOT / "schemas/v1/scenario.schema.json").read_text())
PACK = json.loads((ROOT / "schemas/v1/pack.schema.json").read_text())
VALIDATORS = {
    "scenario": jsonschema.Draft202012Validator(SCENARIO),
    "pack": jsonschema.Draft202012Validator(PACK),
}
STRUCTURAL = {"yaml", "version", "schema", "L1"}


def files():
    for p in sorted((ROOT / "conformance").rglob("*.yaml")):
        yield p
    for p in sorted((ROOT / "tests" / "lint").rglob("*.yaml")):
        yield p
    for d in ("valid", "invalid"):
        for p in sorted((ROOT / "tests" / "schema" / d).glob("*.yaml")):
            yield p


def kind_of(p: Path) -> str:
    return "pack" if p.name.endswith(".pack.yaml") else "scenario"


def ref_read(p: Path):
    yaml = YAML(typ="safe", pure=True)
    yaml.allow_duplicate_keys = False
    try:
        docs = list(yaml.load_all(io.StringIO(p.read_text())))
    except YAMLError as e:
        return None, str(e).splitlines()[0]
    if len(docs) != 1:
        return None, f"{len(docs)} documents"
    return docs[0], None


def nim_read(p: Path):
    r = subprocess.run([DVS, "yaml", str(p)], capture_output=True, text=True)
    out = json.loads(r.stdout)
    if r.returncode != 0:
        return None, out["error"]
    return out, None


def same(a, b) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if isinstance(a, float) and math.isnan(a):
            return isinstance(b, float) and math.isnan(b)
        return a == b and isinstance(a, int) == isinstance(b, int)
    if isinstance(a, dict) and isinstance(b, dict):
        return list(a.keys()) == list(b.keys()) and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def nim_structural_errors(p: Path):
    args = [DVS, "lint", "--json"]
    args += ["--pack", str(p)] if kind_of(p) == "pack" else [str(p)]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode == 64 or not r.stdout.strip():
        raise SystemExit(f"dvs lint failed on {p}: {r.stderr}")
    diags = json.loads(r.stdout)["diagnostics"]
    return [d for d in diags if d["severity"] == "error" and d["phase"] == "structural"]


def main() -> int:
    failures = []
    counts = {"valid": 0, "invalid": 0, "yaml-invalid": 0}
    for p in files():
        rel = p.relative_to(ROOT)
        ref, ref_err = ref_read(p)
        nim, nim_err = nim_read(p)
        if (ref_err is None) != (nim_err is None):
            failures.append(f"{rel}: YAML readers disagree: ruamel={ref_err or 'ok'}, dvs={nim_err or 'ok'}")
            continue
        if ref_err is not None:
            counts["yaml-invalid"] += 1
            if not nim_structural_errors(p):
                failures.append(f"{rel}: not YAML, but dvs lint reports no structural error")
            continue
        if not same(ref, nim):
            failures.append(f"{rel}: YAML readers read different trees:\n  ruamel: {json.dumps(ref)}\n  dvs:    {json.dumps(nim)}")
            continue
        schema_errors = list(VALIDATORS[kind_of(p)].iter_errors(ref))
        parser_errors = nim_structural_errors(p)
        if bool(schema_errors) != bool(parser_errors):
            failures.append(
                f"{rel}: schema says {'invalid' if schema_errors else 'valid'}"
                f" ({schema_errors[0].message if schema_errors else ''}),"
                f" parser says {'invalid' if parser_errors else 'valid'}"
                f" ({parser_errors[0]['message'] if parser_errors else ''})")
            continue
        expect_invalid = "schema/invalid" in str(rel) or rel.name == "l1-bad.yaml"
        if expect_invalid != bool(schema_errors):
            failures.append(f"{rel}: expected {'invalid' if expect_invalid else 'valid'}, both say otherwise")
            continue
        counts["invalid" if schema_errors else "valid"] += 1
    refused = sorted((ROOT / "tests" / "schema" / "refused-yaml").glob("*.yaml"))
    words = {"anchor": "anchors", "tag": "tags", "explicit-key": "explicit keys",
             "two-documents": "several documents"}
    for p in refused:
        rel = p.relative_to(ROOT)
        yaml = YAML(typ="safe", pure=True)
        try:
            list(yaml.load_all(io.StringIO(p.read_text())))
        except YAMLError as e:
            failures.append(f"{rel}: expected valid YAML, ruamel refused it: {e}")
            continue
        _, nim_err = nim_read(p)
        if nim_err is None or words[p.stem] not in nim_err:
            failures.append(f"{rel}: dvs must refuse it naming '{words[p.stem]}', said: {nim_err}")
    for f in failures:
        print("FAIL", f)
    print(f"schema agreement: {counts['valid']} valid, {counts['invalid']} invalid, "
          f"{counts['yaml-invalid']} not YAML, {len(refused)} refused by name; "
          f"{len(failures)} disagreement(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
