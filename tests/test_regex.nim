## The regular-expression subset of `matches`. Pure functions; no stand-ins.

import std/unittest
import demo_video_script/regex

suite "regex subset":
  test "matching":
    for (p, s, want) in [("^Gro", "Groceries", true), ("^Gro", "My Groceries", false),
        ("ies$", "Groceries", true), ("a|b", "xbx", true), ("^(ab)+$", "ababab", true),
        ("^(ab)+$", "ababa", false), ("\\d{2,3}", "a12", true), ("^\\d{2,3}$", "1234", false),
        ("[a-c]x", "bx", true), ("[^a-c]x", "bx", false), ("colou?r", "color", true),
        ("é+", "café", true), ("^(?:a|bc)*d$", "abcbcad", true), ("\\.", "a.b", true),
        ("\\.", "ab", false), ("^$", "", true), ("^(a*)*$", "aaaa", true),
        ("\\w+\\s\\w+", "two words", true), ("^\\S+$", "a b", false)]:
      checkpoint p & " / " & s
      check matches(p, s) == want

  test "unsupported syntax is refused, not matched approximately":
    for bad in ["(", "a)", "*a", "a{2", "[a", "\\q", "a*?", "(?=x)", "\\1"]:
      expect RegexError: discard compile(bad)
