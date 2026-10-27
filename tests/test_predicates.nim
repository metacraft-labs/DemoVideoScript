## Unit tests of the predicate language: parsing and name checking against a
## real pack (the conformance pack, read from disk). No stand-ins.

import std/[unittest, os, strutils]
import demo_video_script

let packPath = currentSourcePath().parentDir.parentDir / "conformance/pack/notes-app.pack.yaml"
let (pack, packDiags) = parsePackFile(packPath)

suite "predicate language":
  test "the conformance pack's predicates parse and check":
    check not packDiags.hasErrors

  test "quantifiers, adjacent pairs, comparison, membership":
    check $parsePredicate("every adjacent pair (a, b) of note: a[key] <= b[key]") ==
      "(every adjacent pair (a, b) of note: a[key] <= b[key])"
    check $parsePredicate("every note: tag in note.tags") == "(every note: tag in note.tags)"
    check $parsePredicate("some n of note: n.title matches \"^G\" and n.selected") ==
      "(some n of note: n.title matches \"^G\" and n.selected)"
    check $parsePredicate("not (count(note) > 3) or count == -1") ==
      "not count(note) > 3 or count == -1"

  test "syntax errors carry a position":
    for s in ["every note", "a ==", "every adjacent (a, b) of note: true", "a = b", "(a"]:
      expect PredicateError: discard parsePredicate(s)

  test "names are checked against the pack":
    var problems: seq[string]
    var dyn: seq[tuple[param, role: string]]
    checkPredicate(pack, "note-list", ["key"],
      parsePredicate("every adjacent pair (a, b) of note: a[key] <= b[colour]"), problems, dyn)
    check problems.len == 1
    check "colour" in problems[0]
    check dyn == @[(param: "key", role: "note")]
    problems.setLen(0)
    checkPredicate(pack, "note-list", [], parsePredicate("every toolbar: true"), problems, dyn)
    check "not a child role" in problems[0]
    problems.setLen(0)
    checkPredicate(pack, "note-list", [], parsePredicate("colour == 1"), problems, dyn)
    check problems.len == 1
