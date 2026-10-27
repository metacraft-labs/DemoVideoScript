# The scenario format — reference (version 1)

A **scenario** is a script of what a user does to an application and what the user then
sees. It has two parts: the **stage**, which sets up the initial conditions by calling
procedures your project provides, and the **steps**, which are only user input,
observations and waits. The same file runs on a terminal, a native window, a web or
Electron page, or a WebDriver target, and serves as a UI test, a test-run recording, a
documentation capture and the raw material of a narrated video.

The format knows no application's vocabulary. Your project describes its UI in a
**pack** — the roles of its page objects, their properties and what input they accept —
and the scenario names those roles.

The published JSON Schemas are [`schemas/v1/scenario.schema.json`](../../schemas/v1/scenario.schema.json)
and [`schemas/v1/pack.schema.json`](../../schemas/v1/pack.schema.json); `dvs schema scenario`
prints the first. The parser and the schemas accept exactly the same files.

## A scenario file

```yaml
scenario: 1 # the format version; another version is refused
name: notes/archive-from-keyboard
pack: notes-app
summary: Archiving the selected note with its shortcut removes it from the list.
requires: [termassert] # only when an extension step needs a backend

stage:
  - use: seed-notes
    with: { fixture: fixtures/three-notes.json }
  - use: launch-app

steps:
  - expect: { at: note-list, count: 3 }
  - click: { at: 'note-list/note[title="Groceries"]', pace: thoughtful }
  - chord: { bound: notes.archive-selected }
  - wait: { until: note-list.loaded }
  - expect: { at: 'note-list/note[title="Groceries"]', absent: true }
```

Files are standard YAML (JSON is accepted too). The reader refuses, by name, YAML
features scenarios do not need: anchors, aliases, tags, explicit keys, several documents
in one file, tabs for indentation and duplicate keys.

**Quote a locator inside `{ … }`.** YAML does not allow `[`, `]` or `,` in an unquoted
value inside a flow mapping, so `{ at: note[title="x"] }` is not YAML; write
`{ at: 'note[title="x"]' }`. On its own line (`at: note[title="x"]`) no quotes are needed.

## Locators

A locator names one page object by its path of roles, with **semantic keys**:

| Locator                                           | Means                                           |
| ------------------------------------------------- | ----------------------------------------------- |
| `note-list`                                       | the note list (a child of the root role)        |
| `note-list/note[title="Groceries"]`               | the note whose title is Groceries               |
| `dialog[title="Rename"]/text-field[label="Name"]` | a field inside a dialog                         |
| `note[title="a", tag="b"]`                        | several keys                                    |
| `note-list/note[#3]`                              | the third note — allowed, and warned about (L4) |
| `focused`                                         | whatever has input focus                        |
| `focused/ancestor(note-list)`                     | the note list containing the focus              |

The first segment is the root role or one of its children; each further segment is a
child of the previous one. There are no coordinates and no backend selectors (CSS,
XPath, accessibility ids): a backend's binding uses those internally. Resolution has
three outcomes — one instance, none, or ambiguous — and only _one_ lets an action run.

## Steps

### Input actions

| Step                | Example                                                        | Notes                                                         |
| ------------------- | -------------------------------------------------------------- | ------------------------------------------------------------- |
| `key`               | `key: Enter`                                                   | one key, pressed and released                                 |
| `chord`             | `chord: Ctrl+K Ctrl+C`                                         | a sequence of chords, separated by one space                  |
| `chord` by binding  | `chord: { bound: notes.archive-selected }`                     | the chord currently bound to the operation, sent as real keys |
| `type`              | `type: "milk"` or `type: { text: milk, pace: quick }`          | typed key by key                                              |
| `press` / `release` | `press: Shift`, `press: { at: …, button: left }`               | held keys and buttons                                         |
| `move`              | `move: { at: search-field, pace: quick }`                      | pointer movement                                              |
| `hover`             | `hover: { at: …, for: 800ms }`                                 | move, then hold still                                         |
| `click`             | `click: { at: …, button: right, count: 2, modifiers: [Mod] }`  | `count` 1–3                                                   |
| `drag`              | `drag: { from: { at: …, anchor: handle }, to: …, via: [ … ] }` | press, moves, release                                         |
| `wheel`             | `wheel: { at: note-list, direction: down, amount: 3 }`         |                                                               |

A target is a locator, or `{ at: <locator>, anchor: <anchor> }`; anchors are declared by
the role (`title-end`, `caret-at(3)`), and `center` is implicit.

**Keys** are spelled `Enter`, `Esc`, `Tab`, `Backspace`, `Delete`, `Insert`, `Home`,
`End`, `PageUp`, `PageDown`, `Up`, `Down`, `Left`, `Right`, `Space`, `Plus` (the `+` key),
`F1`–`F24`, the modifiers `Ctrl`, `Shift`, `Alt`, `Meta` and `Mod`, or one character.
`Mod` is the platform's primary modifier: `Meta` on macOS, `Ctrl` elsewhere. A backend
that cannot deliver a key refuses the step; it never sends a different key.

There is no step that calls application code, sets a value or moves focus directly.
Focus moves the way a user moves it.

Every input action is followed by the pack's `settled` condition. `settle: false` opts
out; then the next observation needs an explicit wait (L5).

### Observations

```yaml
- expect:
    at: 'note-list/note[title="Groceries"]'
    selected: true # equality
    body: { contains: milk } # a matcher
    geometry: { inside: note-list, visible: true }
- expect: { at: note-list, assert: "sorted-by(title)" }
- expect: { at: focused, role: search-field }
- expect: { at: dialog, absent: true }
```

| Matcher                     | Meaning                                                                     |
| --------------------------- | --------------------------------------------------------------------------- |
| a value, or `{ equals: v }` | equal (`{ equals: … }` for a record)                                        |
| `{ contains: v }`           | text contains `v`; lines: some line contains it; lists: some item equals it |
| `{ matches: re }`           | regular expression                                                          |
| `{ one-of: [a, b] }`        | any of the values                                                           |
| `{ lt / le / gt / ge: n }`  | numeric comparisons                                                         |
| `{ count: matcher }`        | the number of items                                                         |
| `{ subsequence: [ … ] }`    | these items, in this order, possibly with others between                    |
| `{ unordered: [ … ] }`      | exactly these items, in any order                                           |

`geometry` relations: `above`, `below`, `left-of`, `right-of`, `inside`, `overlaps`,
`aligned-left`, `aligned-top`, `spans-width-of`, `spans-height-of` (each takes a
locator), and `visible: true|false`. Positions are asserted as relations because
absolute numbers differ by backend, font and window size.

`assert` invokes a **named assertion** the role declares, with literal arguments; a bare
word is a string.

### Waits

```yaml
- wait: note-list.loaded # a role's sync condition
- wait: { until: idle, timeout: 5s } # a pack sync condition
- wait: { until: { at: dialog, present: true } } # an observation
```

A wait never passes by timing out. `settled` is always available.

### Flows, beats, captures and extension steps

```yaml
- flow: rename-note
  with: { title: Groceries, to: Shopping }
- beat: archive
  steps: […]
- capture: { name: after-archive, of: note-list }
- ext: termassert.golden # needs `requires: [termassert]`
  with: { file: goldens/list.txt }
```

A flow is a named sequence of ordinary steps declared by the pack; it can contain
nothing a scenario could not. A beat groups steps under a name that narration and video
tools refer to. An extension step is a backend-specific primitive.

### Timing and presentation annotations

Any step may carry:

| Annotation                                   | Meaning                                                        |
| -------------------------------------------- | -------------------------------------------------------------- |
| `id: name`                                   | a name to anchor narration, captions and callouts to           |
| `lead-in: 500ms`                             | pause before the step (realistic runs only)                    |
| `dwell: 1.5s`                                | hold the result on screen after the step (realistic runs only) |
| `chapter: Title`                             | a chapter marker in the recording                              |
| `narration: { text, from?, to?, voice? }`    | spoken text over a span of steps or beats                      |
| `caption: { text, from?, to?, style? }`      | on-screen text over a span                                     |
| `callout: { at, anchor?, text, from?, to? }` | an annotation drawn on a page object                           |
| `alternatives: { <capability>: [steps] }`    | an input-only alternative for backends lacking a capability    |

`type`, `move`, `hover`, `click` and `drag` take `pace`: a preset (`texting`, `quick`,
`thoughtful`, `careful`) or parameters (`preset`, `key-mean`, `key-sigma`, `key-min`,
`key-max`, `curvature`, `overshoot`, `commit-pause`, `seed`).

Durations are `250ms`, `1.5s`, `2m`, or a number of seconds. Spans are anchored to
steps, never to seconds, so narration starts at the right moment on every backend.

## The pack file

```yaml
pack: 1
name: notes-app
root: window
roles:
  window:
    properties: { title: text }
    children: { toolbar: one, note-list: one, dialog: optional }
  note-list:
    properties: { count: int, order: lines }
    children: { note: many }
    affordances: [drop-target, wheel, focusable]
    assertions:
      sorted-by(key): "every adjacent pair (a, b) of note: a[key] <= b[key]"
    sync:
      loaded: ~ # detected by the backend binding
  note:
    keys: [title]
    properties: { title: text, selected: bool, body: lines, tags: lines }
    affordances: [click, double-click, context-click, drag-source]
    anchors: [title-end]
sync:
  settled: ~
flows:
  open-note(title):
    - click: { at: 'note-list/note[title="${title}"]' }
stages:
  seed-notes: { params: { fixture: text } }
```

Property types: `text`, `lines`, `bool`, `int`, `number`, `enum{a,b}`, `record`,
`list<record>`; `geometry` and `present` are implicit. Affordances: `click`,
`double-click`, `context-click`, `drag-source`, `drop-target`, `wheel`, `text-entry`,
`focusable`. Children are `one`, `optional` or `many`.

Stages are declared by signature only: their code is your project's, written in each
backend's language, and runs before the first step. After the stage ends, nothing can
call it.

### The predicate language

Named assertions and sync conditions are predicates over a role instance (its
properties), its children and the assertion's parameters:

```text
every adjacent pair (a, b) of note: a[key] <= b[key]
every note: tag in note.tags
some n of note: n.title matches "^G" and n.selected
none note: note.selected
count(note) <= n
```

Operators: `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`, `contains`, `matches`, `and`, `or`,
`not`. A bare name is a bound variable, a parameter, or a property of the role, in that
order. `x[p]` reads the property named by parameter `p`. Predicates are evaluated by the
runner, once, for every backend.

## Lint rules

`dvs lint` reports each finding with its rule, file, line and column.

| Rule | Finding                                                                                                                                                    | Severity |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| L1   | `steps` contains something that is not an input action, observation, wait, flow call, beat, capture, extension step or annotation — including a stage call | error    |
| L2   | a locator, key, anchor or observed property does not resolve against the pack                                                                              | error    |
| L3   | an input action's target role does not declare the affordance                                                                                              | error    |
| L4   | an ordinal locator (`[#n]`)                                                                                                                                | warning  |
| L5   | an observation directly after an input with `settle: false` and no wait                                                                                    | error    |
| L6   | a `dwell` or `lead-in` followed by an observation with no wait between                                                                                     | warning  |
| L7   | a named assertion, sync condition, flow or stage referenced but not declared, or given the wrong arguments                                                 | error    |
| L8   | an extension step whose backend the scenario does not `require`                                                                                            | error    |
| L9   | narration, a caption or a callout anchored to a step id or beat that does not exist                                                                        | error    |
| L10  | a pack role, property, flow or assertion named like a format keyword                                                                                       | error    |
| L11  | a flow that, expanded, breaks L1                                                                                                                           | error    |
| L12  | two steps with the same id, two beats with the same name, or two captures with the same name                                                               | error    |

## The command line

```text
dvs lint <scenario>... [--pack <pack.yaml>] [--json]   exit 0 clean, 1 warnings, 2 errors
dvs lint --pack <pack.yaml>                             lint a pack on its own
dvs parse <scenario>                                    print the normalised scenario (JSON)
dvs schema scenario|pack                                print a published schema
```

The normalised form expands every shorthand and is itself a valid scenario.
