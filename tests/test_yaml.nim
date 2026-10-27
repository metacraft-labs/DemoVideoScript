## Unit tests of the YAML reader on in-memory documents: the supported subset,
## positions, and the features it refuses by name. (The reader is also compared
## with an independent YAML 1.2 reader over every corpus file, in
## tests/schema_agreement.py.) No stand-ins.

import std/[json, unittest, strutils]
import demo_video_script/yaml

proc j(s: string): JsonNode = readYaml(s).toJson

suite "YAML reader":
  test "block and flow collections":
    check j("a: 1\nb: [x, 'y', \"z\"]\nc: { d: true, e: ~ }\n") ==
      %*{"a": 1, "b": ["x", "y", "z"], "c": {"d": true, "e": nil}}
  test "a sequence at its key's indentation":
    check j("steps:\n- key: Enter\n- key: Esc\n") ==
      %*{"steps": [{"key": "Enter"}, {"key": "Esc"}]}
  test "compact mappings in sequence items":
    check j("- click: a\n  dwell: 1s\n- key: b\n") ==
      %*[{"click": "a", "dwell": "1s"}, {"key": "b"}]
  test "core schema scalars":
    check j("[1, -2, 0x1F, 0o17, 1.5, 1e3, true, False, null, ~, 1.5s, '1']") ==
      %*[1, -2, 31, 15, 1.5, 1000.0, true, false, nil, nil, "1.5s", "1"]
  test "block scalars and chomping":
    check j("a: |\n  x\n  y\nb: >-\n  p\n  q\n") == %*{"a": "x\ny\n", "b": "p q"}
  test "multi-line plain scalar folds":
    check j("a: one\n  two\n") == %*{"a": "one two"}
  test "comments":
    check j("# c\na: 1 # trailing\n# end\n") == %*{"a": 1}
  test "positions":
    let n = readYaml("a:\n  b: [x,\n     y]\n")
    check n.get("a").get("b").items[1].line == 3
    check n.get("a").get("b").items[1].col == 6

  test "refusals name the feature":
    for (src, word) in [("a: &x 1\n", "anchors"), ("a: *x\n", "aliases"),
                        ("a: !!str 1\n", "tags"), ("? a\n: 1\n", "explicit keys"),
                        ("a: 1\n---\nb: 2\n", "several documents"),
                        ("a:\n\tb: 1\n", "tab"), ("a: 1\na: 2\n", "duplicate"),
                        ("a: { at: x[y=\"z\"] }\n", "must be quoted")]:
      var msg = ""
      try: discard readYaml(src)
      except YamlError as e: msg = e.msg
      check word in msg
