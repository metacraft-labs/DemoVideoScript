#!/usr/bin/env python3
"""Generates the published JSON Schemas of the scenario format.

The schemas in schemas/v1/ are the published contract; this script is how they
are written, so that the regular expressions shared between them (key names,
chords, locators, durations) have one definition. `just lint` checks that the
committed schemas equal this script's output (`--check`).

The Nim parser implements the same grammar by hand; `tests/schema_agreement.py`
checks that the two agree on every corpus and fixture file.
"""
import json
import sys
from pathlib import Path

NAME = r"[a-z][a-z0-9-]*"
NAMED_KEYS = ["Enter","Esc","Tab","Backspace","Delete","Insert","Home","End","PageUp","PageDown",
              "Up","Down","Left","Right","Space","Plus","Ctrl","Shift","Alt","Meta","Mod"] + [f"F{i}" for i in range(24,0,-1)]
KEY = "(?:" + "|".join(NAMED_KEYS) + r"|[^\x00-\x20\x7f+])"
MOD = r"(?:Ctrl|Shift|Alt|Meta|Mod)"
CHORD1 = f"(?:{MOD}\\+)*{KEY}"
CHORDSEQ = f"^{CHORD1}(?: {CHORD1})*$"
KEYONLY = f"^{KEY}$"
STR = r'"(?:[^"\\]|\\.)*"'
SEL = rf"\[(?:#[1-9][0-9]*|{NAME}={STR}(?:, *{NAME}={STR})*)\]"
SEG = rf"{NAME}(?:{SEL})?"
LOC = rf"^(?:focused|{SEG})(?:/(?:ancestor\({NAME}\)|{SEG}))*$"
DUR = r"^[0-9]+(?:\.[0-9]+)?(?:ms|s|m)$"
ARG = rf"(?:{STR}|-?[0-9]+(?:\.[0-9]+)?|[A-Za-z0-9_.-]+)"
INVOKE = rf"^{NAME}(?:\((?:{ARG}(?:, *{ARG})*)?\))?$"
SYNC = rf"^{NAME}(?:\.{NAME})*$"
ANCHOR = rf"^{NAME}(?:\((?:{ARG}(?:, *{ARG})*)?\))?$"
SIG = rf"^{NAME}(?:\((?:{NAME}(?:, *{NAME})*)?\))?$"
TYPE = rf"^(?:text|lines|bool|int|number|record|list<record>|enum\{{[a-z0-9-]+(?:,[a-z0-9-]+)*\}})$"
SCEN = r"^[a-z0-9][a-z0-9-]*(?:/[a-z0-9][a-z0-9-]*)*$"

BASE = "https://github.com/metacraft-labs/DemoVideoScript/schemas/v1/"

CAPABILITIES = [
    "input.key", "input.chord", "input.text", "input.pointer.move", "input.pointer.click",
    "input.pointer.drag", "input.wheel", "input.hover",
    "observe.text", "observe.geometry", "observe.style", "observe.image", "observe.focus",
    "sync.event", "sync.visual-settle",
    "record.cast", "record.video", "record.still",
]
AFFORDANCES = ["click", "double-click", "context-click", "drag-source", "drop-target",
               "wheel", "text-entry", "focusable"]
PACE_PRESETS = ["texting", "quick", "thoughtful", "careful"]
RESERVED_OBS = ["at", "assert", "geometry", "role", "absent", "present"]
RELATIONS = ["above", "below", "left-of", "right-of", "inside", "overlaps", "aligned-left",
             "aligned-top", "spans-width-of", "spans-height-of"]


def scenario_schema():
    d = {}
    d["name"] = {"type": "string", "pattern": f"^{NAME}$"}
    d["duration"] = {"oneOf": [{"type": "string", "pattern": DUR},
                               {"type": "number", "minimum": 0}]}
    d["locator"] = {"type": "string", "pattern": LOC}
    d["anchor"] = {"type": "string", "pattern": ANCHOR}
    d["target"] = {"oneOf": [
        {"$ref": "#/$defs/locator"},
        {"type": "object", "required": ["at"], "additionalProperties": False,
         "properties": {"at": {"$ref": "#/$defs/locator"}, "anchor": {"$ref": "#/$defs/anchor"}}},
    ]}
    d["pace"] = {"oneOf": [
        {"enum": PACE_PRESETS},
        {"type": "object", "additionalProperties": False, "minProperties": 1,
         "properties": {
             "preset": {"enum": PACE_PRESETS},
             "key-mean": {"$ref": "#/$defs/duration"},
             "key-sigma": {"type": "number", "minimum": 0},
             "key-min": {"$ref": "#/$defs/duration"},
             "key-max": {"$ref": "#/$defs/duration"},
             "curvature": {"type": "number", "minimum": 0},
             "overshoot": {"type": "number", "minimum": 0},
             "commit-pause": {"$ref": "#/$defs/duration"},
             "seed": {"type": "integer"},
         }},
    ]}
    d["button"] = {"enum": ["left", "right", "middle"]}
    d["modifiers"] = {"type": "array", "uniqueItems": True,
                      "items": {"enum": ["Ctrl", "Shift", "Alt", "Meta", "Mod"]}}
    d["key"] = {"type": "string", "pattern": KEYONLY}
    d["chord"] = {"type": "string", "pattern": CHORDSEQ}
    d["span"] = {"type": "object", "required": ["text"], "additionalProperties": False,
                 "properties": {"text": {"type": "string"}, "from": {"$ref": "#/$defs/name"},
                                "to": {"$ref": "#/$defs/name"},
                                "voice": {"type": "string"}, "style": {"type": "string"}}}
    d["callout"] = {"type": "object", "required": ["at", "text"], "additionalProperties": False,
                    "properties": {"at": {"$ref": "#/$defs/locator"},
                                   "anchor": {"$ref": "#/$defs/anchor"},
                                   "text": {"type": "string"},
                                   "from": {"$ref": "#/$defs/name"}, "to": {"$ref": "#/$defs/name"}}}
    scalar = [{"type": "string"}, {"type": "number"}, {"type": "boolean"}, {"type": "null"}]
    d["matcher"] = {"oneOf": scalar + [
        {"type": "array"},
        {"type": "object", "minProperties": 1, "maxProperties": 1, "additionalProperties": False,
         "properties": {
             "equals": {},
             "contains": {},
             "matches": {"type": "string"},
             "one-of": {"type": "array", "minItems": 1},
             "lt": {"type": "number"}, "le": {"type": "number"},
             "gt": {"type": "number"}, "ge": {"type": "number"},
             "count": {"$ref": "#/$defs/matcher"},
             "subsequence": {"type": "array"},
             "unordered": {"type": "array"},
         }},
    ]}
    geo = {r: {"$ref": "#/$defs/locator"} for r in RELATIONS}
    geo["visible"] = {"type": "boolean"}
    d["geometry"] = {"type": "object", "minProperties": 1, "additionalProperties": False,
                     "properties": geo}
    d["invocation"] = {"type": "string", "pattern": INVOKE}
    d["observation"] = {
        "type": "object", "required": ["at"],
        "properties": {
            "at": {"$ref": "#/$defs/locator"},
            "assert": {"oneOf": [{"$ref": "#/$defs/invocation"},
                                 {"type": "array", "minItems": 1,
                                  "items": {"$ref": "#/$defs/invocation"}}]},
            "geometry": {"$ref": "#/$defs/geometry"},
            "role": {"$ref": "#/$defs/name"},
            "absent": {"type": "boolean"},
            "present": {"type": "boolean"},
        },
        "patternProperties": {f"^(?!(?:{'|'.join(RESERVED_OBS)})$){NAME}$": {"$ref": "#/$defs/matcher"}},
        "additionalProperties": False,
    }
    d["until"] = {"oneOf": [{"type": "string", "pattern": SYNC}, {"$ref": "#/$defs/observation"}]}

    annotations = {
        "id": {"$ref": "#/$defs/name"},
        "lead-in": {"$ref": "#/$defs/duration"},
        "dwell": {"$ref": "#/$defs/duration"},
        "chapter": {"type": "string"},
        "narration": {"$ref": "#/$defs/span"},
        "caption": {"$ref": "#/$defs/span"},
        "callout": {"oneOf": [{"$ref": "#/$defs/callout"},
                              {"type": "array", "items": {"$ref": "#/$defs/callout"}}]},
        "alternatives": {"type": "object", "minProperties": 1, "additionalProperties": False,
                         "properties": {c: {"$ref": "#/$defs/steps"} for c in CAPABILITIES}},
    }
    pointer_common = {"pace": {"$ref": "#/$defs/pace"}}

    def obj(required, props):
        return {"type": "object", "required": required, "additionalProperties": False,
                "properties": props}

    def target_obj(extra, required=("at",)):
        p = {"at": {"$ref": "#/$defs/locator"}, "anchor": {"$ref": "#/$defs/anchor"}}
        p.update(extra)
        return obj(list(required), p)

    actions = {
        "key": {"$ref": "#/$defs/key"},
        "chord": {"oneOf": [{"$ref": "#/$defs/chord"},
                            obj(["bound"], {"bound": {"type": "string", "pattern": SYNC}})]},
        "type": {"oneOf": [{"type": "string"},
                           obj(["text"], {"text": {"type": "string"}, **pointer_common})]},
        "press": {"oneOf": [{"$ref": "#/$defs/key"},
                            obj(["key"], {"key": {"$ref": "#/$defs/key"}}),
                            target_obj({"button": {"$ref": "#/$defs/button"}})]},
        "release": {"oneOf": [{"$ref": "#/$defs/key"},
                              obj(["key"], {"key": {"$ref": "#/$defs/key"}}),
                              target_obj({"button": {"$ref": "#/$defs/button"}})]},
        "move": {"oneOf": [{"$ref": "#/$defs/locator"}, target_obj(pointer_common)]},
        "hover": {"oneOf": [{"$ref": "#/$defs/locator"},
                            target_obj({"for": {"$ref": "#/$defs/duration"}, **pointer_common})]},
        "click": {"oneOf": [{"$ref": "#/$defs/locator"}, target_obj({
            "button": {"$ref": "#/$defs/button"},
            "count": {"type": "integer", "minimum": 1, "maximum": 3},
            "modifiers": {"$ref": "#/$defs/modifiers"}, **pointer_common})]},
        "drag": obj(["from", "to"], {
            "from": {"$ref": "#/$defs/target"}, "to": {"$ref": "#/$defs/target"},
            "via": {"type": "array", "items": {"$ref": "#/$defs/target"}},
            "button": {"$ref": "#/$defs/button"}, "modifiers": {"$ref": "#/$defs/modifiers"},
            **pointer_common}),
        "wheel": target_obj({"direction": {"enum": ["up", "down", "left", "right"]},
                             "amount": {"type": "integer", "minimum": 1}},
                            required=("at", "direction")),
    }
    variants = []
    for name, schema in actions.items():
        props = {name: schema, "settle": {"type": "boolean"}, **annotations}
        variants.append(obj([name], props))
    variants.append(obj(["expect"], {"expect": {"$ref": "#/$defs/observation"}, **annotations}))
    variants.append(obj(["wait"], {"wait": {"oneOf": [
        {"type": "string", "pattern": SYNC},
        obj(["until"], {"until": {"$ref": "#/$defs/until"},
                        "timeout": {"$ref": "#/$defs/duration"}})]}, **annotations}))
    variants.append(obj(["flow"], {"flow": {"$ref": "#/$defs/name"},
                                   "with": {"type": "object"}, **annotations}))
    variants.append(obj(["beat", "steps"], {"beat": {"$ref": "#/$defs/name"},
                                            "steps": {"$ref": "#/$defs/steps"}, **annotations}))
    variants.append(obj(["capture"], {"capture": obj(["name"], {
        "name": {"$ref": "#/$defs/name"}, "of": {"$ref": "#/$defs/locator"}}), **annotations}))
    variants.append(obj(["ext"], {"ext": {"type": "string", "pattern": rf"^{NAME}\.{NAME}(?:\.{NAME})*$"},
                                  "with": {"type": "object"}, **annotations}))
    d["step"] = {"oneOf": variants}
    d["steps"] = {"type": "array", "items": {"$ref": "#/$defs/step"}}
    d["stageCall"] = obj(["use"], {"use": {"$ref": "#/$defs/name"}, "with": {"type": "object"}})
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": BASE + "scenario.schema.json",
        "title": "DemoVideoScript scenario, format version 1",
        "type": "object",
        "required": ["scenario", "name", "steps"],
        "additionalProperties": False,
        "properties": {
            "scenario": {"const": 1},
            "name": {"type": "string", "pattern": SCEN},
            "pack": {"type": "string", "pattern": f"^{NAME}$"},
            "summary": {"type": "string"},
            "requires": {"type": "array", "uniqueItems": True, "items": {"$ref": "#/$defs/name"}},
            "stage": {"type": "array", "items": {"$ref": "#/$defs/stageCall"}},
            "steps": {"$ref": "#/$defs/steps"},
        },
        "$defs": d,
    }


def pack_schema():
    d = {}
    d["name"] = {"type": "string", "pattern": f"^{NAME}$"}
    d["type"] = {"type": "string", "pattern": TYPE}
    d["predicate"] = {"type": "string", "minLength": 1}
    d["role"] = {
        "type": "object", "additionalProperties": False,
        "properties": {
            "keys": {"type": "array", "uniqueItems": True, "items": {"$ref": "#/$defs/name"}},
            "properties": {"type": "object", "additionalProperties": False,
                           "patternProperties": {f"^{NAME}$": {"$ref": "#/$defs/type"}}},
            "children": {"type": "object", "additionalProperties": False,
                         "patternProperties": {f"^{NAME}$": {"enum": ["one", "optional", "many"]}}},
            "affordances": {"type": "array", "uniqueItems": True, "items": {"enum": AFFORDANCES}},
            "anchors": {"type": "array", "uniqueItems": True,
                        "items": {"type": "string", "pattern": SIG}},
            "assertions": {"type": "object", "additionalProperties": False,
                           "patternProperties": {SIG: {"$ref": "#/$defs/predicate"}}},
            "sync": {"$ref": "#/$defs/syncMap"},
        },
    }
    d["syncMap"] = {"type": "object", "additionalProperties": False,
                    "patternProperties": {SYNC: {"oneOf": [{"$ref": "#/$defs/predicate"},
                                                           {"type": "null"}]}}}
    d["stage"] = {"type": "object", "additionalProperties": False,
                  "properties": {"params": {"type": "object", "additionalProperties": False,
                                            "patternProperties": {f"^{NAME}$": {"$ref": "#/$defs/type"}}},
                                 "summary": {"type": "string"}}}
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": BASE + "pack.schema.json",
        "title": "DemoVideoScript pack (backend-neutral part), format version 1",
        "type": "object",
        "required": ["pack", "name", "root", "roles"],
        "additionalProperties": False,
        "properties": {
            "pack": {"const": 1},
            "name": {"$ref": "#/$defs/name"},
            "summary": {"type": "string"},
            "root": {"$ref": "#/$defs/name"},
            "roles": {"type": "object", "minProperties": 1, "additionalProperties": False,
                      "patternProperties": {f"^{NAME}$": {"$ref": "#/$defs/role"}}},
            "sync": {"$ref": "#/$defs/syncMap"},
            "flows": {"type": "object", "additionalProperties": False,
                      "$comment": "flow bodies are checked after parameter substitution (lint L11)",
                      "patternProperties": {SIG: {"type": "array",
                                                  "items": {"type": "object"}}}},
            "stages": {"type": "object", "additionalProperties": False,
                       "patternProperties": {f"^{NAME}$": {"oneOf": [{"$ref": "#/$defs/stage"},
                                                                     {"type": "null"}]}}},
        },
        "$defs": d,
    }


def protocol_schema():
    """Requests (runner -> backend) and responses (backend -> runner), one JSON
    object per line. Arms generate their types from this file."""
    d = {}
    d["segment"] = {"oneOf": [
        {"type": "object", "required": ["role"], "additionalProperties": False,
         "properties": {"role": {"type": "string", "pattern": f"^{NAME}$"},
                        "keys": {"type": "object", "additionalProperties": {"type": "string"}},
                        "ordinal": {"type": "integer", "minimum": 1}}},
        {"type": "object", "required": ["focused"], "additionalProperties": False,
         "properties": {"focused": {"const": True}}},
        {"type": "object", "required": ["ancestor"], "additionalProperties": False,
         "properties": {"ancestor": {"type": "string", "pattern": f"^{NAME}$"}}},
    ]}
    d["locator"] = {"type": "object", "required": ["segments"], "additionalProperties": False,
                    "properties": {"text": {"type": "string"},
                                   "parent": {"type": "string",
                                              "$comment": "resolve the segments among this instance's children"},
                                   "segments": {"type": "array", "items": {"$ref": "#/$defs/segment"}}}}
    d["geometry"] = {"type": "object", "required": ["x", "y", "w", "h"],
                     "properties": {"x": {"type": "number"}, "y": {"type": "number"},
                                    "w": {"type": "number"}, "h": {"type": "number"},
                                    "visible": {"type": "boolean"}}}
    req = lambda call, props, required=(): {
        "type": "object", "required": ["id", "call", *required], "additionalProperties": False,
        "properties": {"id": {"type": "integer"}, "call": {"const": call}, **props}}
    requests = [
        req("hello", {"protocol": {"const": 1}}, ["protocol"]),
        req("stage", {"use": {"type": "string", "pattern": f"^{NAME}$"},
                      "with": {"type": "object", "properties": {"$base": {"type": "string"}}}},
            ["use", "with"]),
        req("end-stage", {}),
        req("resolve-chord", {"operation": {"type": "string", "pattern": SYNC}}, ["operation"]),
        req("locate", {"locator": {"$ref": "#/$defs/locator"}}, ["locator"]),
        req("read", {"instance": {"type": "string"},
                     "properties": {"type": "array", "items": {"type": "string"}}},
            ["instance", "properties"]),
        req("send", {"action": {"type": "object",
                                "$comment": "a normalised input step (scenario.schema.json) with 'targets' "
                                            "(instance ids for target/from/to/via) and, in realistic runs, "
                                            "'timing' (keyDelaysMs; path and approach as [x, y, ms] points "
                                            "in the backend's units); or {ext, with}"}},
            ["action"]),
        req("await", {"condition": {"type": "string", "pattern": SYNC},
                      "instance": {"type": "string"},
                      "timeoutMs": {"type": "integer", "minimum": 0}},
            ["condition", "timeoutMs"]),
        req("record", {"op": {"enum": ["start", "mark", "still", "stop"]},
                       "dir": {"type": "string"}, "path": {"type": "string"},
                       "name": {"type": "string"}, "instance": {"type": "string"},
                       "step": {"type": "integer"}, "kind": {"type": "string"}},
            ["op"]),
        req("hit", {"x": {"type": "number"}, "y": {"type": "number"}}, ["x", "y"]),
        req("shutdown", {}),
    ]
    ok = lambda props, required=(): {
        "type": "object", "required": ["id", "ok", *required], "additionalProperties": False,
        "properties": {"id": {"type": "integer"}, "ok": {"const": True}, **props}}
    responses = {
        "error": {"type": "object", "required": ["id", "ok", "error"], "additionalProperties": False,
                  "properties": {"id": {"type": ["integer", "null"]}, "ok": {"const": False},
                                 "error": {"type": "object", "required": ["kind", "message"],
                                           "additionalProperties": False,
                                           "properties": {"kind": {"enum": [
                                               "unsupported", "refused", "not-found", "stage-closed",
                                               "stage", "protocol", "crashed", "internal"]},
                                               "message": {"type": "string"}}}}},
        "hello": ok({"backend": {"type": "string"}, "version": {"type": "string"},
                     "platform": {"enum": ["linux", "macos", "windows"]},
                     "capabilities": {"type": "array", "items": {"enum": CAPABILITIES}},
                     "bindings": {"type": ["object", "null"]},
                     "units": {"enum": ["cell", "px"]}},
                    ["backend", "capabilities", "units"]),
        "locate": ok({"outcome": {"enum": ["one", "none", "ambiguous"]},
                      "instance": {"type": "string"}, "role": {"type": "string"},
                      "candidates": {"type": "array", "items": {"type": "string"}}},
                     ["outcome"]),
        "read": ok({"values": {"type": "object",
                               "properties": {"geometry": {"$ref": "#/$defs/geometry"}}}},
                   ["values"]),
        "await": ok({"met": {"type": "boolean"}}, ["met"]),
        "resolve-chord": ok({"chord": {"type": ["string", "null"]}}, ["chord"]),
        "hit": ok({"locator": {"type": ["string", "null"]}}, ["locator"]),
        "record": ok({"files": {"type": "array", "items": {"type": "string"}}}, ["files"]),
        "empty": ok({}),
    }
    rdefs = {f"response-{k}": v for k, v in responses.items()}
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": BASE + "backend-protocol.schema.json",
        "title": "DemoVideoScript backend protocol, version 1 (JSON lines)",
        "$comment": "A response answers the request with the same id: response-<call> "
                    "(response-empty for stage, end-stage, send, shutdown) or response-error.",
        "$defs": {**d, **rdefs,
                  "request": {"oneOf": requests},
                  "response": {"anyOf": [{"$ref": f"#/$defs/{k}"} for k in rdefs]}},
        "oneOf": [{"$ref": "#/$defs/request"}, {"$ref": "#/$defs/response"}],
    }


def render(schema):
    return json.dumps(schema, indent=2, ensure_ascii=False) + "\n"


def main():
    out = Path(__file__).resolve().parent.parent / "schemas" / "v1"
    files = {"scenario.schema.json": render(scenario_schema()),
             "pack.schema.json": render(pack_schema()),
             "backend-protocol.schema.json": render(protocol_schema())}
    check = "--check" in sys.argv
    stale = []
    for name, text in files.items():
        path = out / name
        if check:
            if not path.exists() or path.read_text() != text:
                stale.append(name)
        else:
            path.write_text(text)
    if stale:
        print("stale schemas (run tools/generate_schemas.py):", ", ".join(stale))
        sys.exit(1)


if __name__ == "__main__":
    main()
