## Unit tests of the string grammars (keys, chords, locators, durations,
## invocations). Pure functions over strings: no stand-ins of any kind.

import std/unittest
import demo_video_script/grammar

suite "keys and chords":
  test "named keys, single characters and modifiers are keys":
    for k in ["Enter", "Esc", "F12", "Plus", "Shift", "a", "Z", "#", "é"]:
      check k.isKeyName
    for k in ["Return", "", " ", "+", "ab", "Ctrl+S"]:
      check not k.isKeyName

  test "a chord keeps every modifier":
    let c = parseChord("Ctrl+Shift+Alt+Meta+k")
    check c.modifiers == {modCtrl, modShift, modAlt, modMeta}
    check c.key == "k"
    check $c == "Ctrl+Shift+Alt+Meta+k"

  test "a chord sequence is separated by single spaces":
    let cs = parseChordSequence("Ctrl+K Ctrl+C")
    check cs.len == 2
    check $cs == "Ctrl+K Ctrl+C"
    expect GrammarError: discard parseChordSequence("Ctrl+K  Ctrl+C")
    expect GrammarError: discard parseChordSequence("Ctrl++")
    expect GrammarError: discard parseChordSequence("Hyper+K")

  test "Mod is Meta on macOS and Ctrl elsewhere":
    let c = parseChord("Mod+s")
    check resolveMod(c, platMacos).modifiers == {modMeta}
    check resolveMod(c, platLinux).modifiers == {modCtrl}
    check resolveMod(c, platWindows).modifiers == {modCtrl}
    check resolveMod(parseChord("Shift+Mod+s"), platLinux).modifiers == {modShift, modCtrl}

  test "a key step refuses a chord":
    expect GrammarError: discard parseKey("Ctrl+S")
    check parseKey("Plus") == "Plus"

suite "durations":
  test "units":
    check parseDurationText("250ms") == 250
    check parseDurationText("1.5s") == 1500
    check parseDurationText("2m") == 120_000
    check parseDurationText("0s") == 0
  test "malformed":
    for s in ["1.5", "s", "1.s", ".5s", "1.5 s", "5mms", "-1s"]:
      expect GrammarError: discard parseDurationText(s)
  test "formatting":
    check formatDuration(1500) == "1500ms"
    check formatDuration(2000) == "2s"

suite "locators":
  test "semantic keys":
    let l = parseLocator("""dialog[title="Rename"]/text-field[label="Name"]""")
    check l.segments.len == 2
    check l.segments[0].role == "dialog"
    check l.segments[0].keys == @[(key: "title", value: "Rename")]
    check $l == """dialog[title="Rename"]/text-field[label="Name"]"""

  test "several keys, escapes, ordinal, focus and ancestors":
    let l = parseLocator("""note[title="a \"b\"", tag="x"]""")
    check l.segments[0].keys == @[(key: "title", value: "a \"b\""), (key: "tag", value: "x")]
    check parseLocator("note-list/note[#3]").segments[1].ordinal == 3
    check parseLocator("note-list/note[#3]").hasOrdinal
    let f = parseLocator("focused/ancestor(note)")
    check f.segments[0].kind == segFocused
    check f.segments[1].kind == segAncestor
    check f.segments[1].role == "note"

  test "no coordinates, no backend selectors":
    for s in ["note@(1,2)", "#notes > li", "//div[@id='x']", "note[title=x]", "note[#0]",
              "ancestor(note)", "note/", "/note", "note[title=\"x\"", ""]:
      expect GrammarError: discard parseLocator(s)

  test "focused is a keyword only in first position":
    check parseLocator("focused").segments[0].kind == segFocused
    check parseLocator("a/focused").segments[1].kind == segRole

suite "invocations and signatures":
  test "arguments":
    let inv = parseInvocation("""between(1, -2.5, "x y", title)""")
    check inv.name == "between"
    check inv.args.len == 4
    check inv.args[0].kind == argNumber
    check inv.args[1].text == "-2.5"
    check inv.args[2].kind == argString
    check inv.args[2].text == "x y"
    check inv.args[3].kind == argWord
    check $inv == """between(1, -2.5, "x y", title)"""
  test "signatures":
    check parseSignature("sorted-by(key)").params == @["key"]
    check parseSignature("loaded").params.len == 0
    expect GrammarError: discard parseSignature("sorted by")
