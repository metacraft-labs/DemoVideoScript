# Recordings, lanes and documentation captures

## A run directory

Every run can leave a recording: a directory with a manifest and the media.

```text
<build>/scenario-runs/<scenario>/<backend>/<run-id>/
  manifest.json            the entry point (below)
  session.cast | .mp4 | .webm   the backend's media, when the run recorded
  steps/<index>-<kind>.*   a still after each step (text, SVG or PNG: the backend's)
  steps/<index>-<name>.*   the still of a `capture` step
  steps/<index>-state.json the step's result: what it resolved and what it observed
  failure/observation.json the failing step
  failure/surface.*        the screen when it failed
  failure/backend.log      what the backend wrote about itself
```

`--record on-failure` (the default) keeps a failed run's directory and deletes a
passing one's; `--record always` keeps both; `--record off` writes nothing. The runner
prints `recording: <dir>` for every failed run. `<build>` is `--build`, else `BUILD_DIR`,
else `build`. `--out DIR` names the directory instead; a recording is never written to
the home directory itself, nor inside the user's configuration, state, data or cache
directories, nor into a shared system directory (`/etc`, `/var`, `/usr`, `/nix`, `/opt`).

**Retention.** After a run, the runs of the same scenario and backend are pruned: the
newest 5 are kept, and every failed run younger than 7 days (`--keep-runs`,
`--keep-failure-days`, or a lane's `retention`). Only directories with a manifest are
runs; nothing else is touched.

### The manifest

`manifest.json` (`"format": "demo-video-script.run.v1"`) is the place to start reading a
run, for a person or an agent:

| Field                                                    |                                                                                                                                                                                                                                                                        |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scenario`, `pack`, `backend`                            | what ran where (the backend's `hello`)                                                                                                                                                                                                                                 |
| `runId`, `startedAt`                                     | the run directory's name; when it started (UTC)                                                                                                                                                                                                                        |
| `mode`, `seed`, `deterministic`, `environment`, `pinned` | how it ran                                                                                                                                                                                                                                                             |
| `outcome`, `message`                                     | `passed`, `failed`, `unsupported` or `error`, and why                                                                                                                                                                                                                  |
| `steps[]`                                                | per step: `index`, `path` (where it is in the file), `kind`, `status`, `message`, `startMs`/`endMs` (the run's clock), `virtualStartMs`/`virtualEndMs` (the virtual timeline), `resolved` locators and chords, `observed` values, `artifacts`, a capture step's `name` |
| `media`, `recordingStartMs`                              | the session media, and when on the run's clock it started                                                                                                                                                                                                              |
| `unsupported`, `diagnostics`                             | the capabilities a backend lacked; lint findings                                                                                                                                                                                                                       |

Read the manifest and the state files first; open the media only at the step that
failed.

### CI

`.github/actions/upload-failed-runs` uploads the run directories of failed runs (the
ones with a `failure/` directory) as a job artifact:

```yaml
- if: failure()
  uses: metacraft-labs/DemoVideoScript/.github/actions/upload-failed-runs@<commit>
  with: { build-dir: build }
```

## Lanes

A lane says which scenarios a backend is expected to run, and which it is expected not to
be able to run:

```yaml
lane: 1
name: terminal
pack: ../pack/notes-app.pack.yaml
backend: cmd:dvs-termassert-notes --serve # or a backend linked in process
modes: [fast, realistic] # default: fast
applicable: [archive-from-keyboard.yaml, drag-to-reorder.yaml]
unsupported: [search-and-matchers.yaml]
retention: { runs: 5, failure-days: 7 }
```

`dvs lane <lane.yaml>` fails when an applicable scenario is `unsupported`, fails, or
errs, and when a scenario expected `unsupported` runs (its expectation is stale); the
expected `unsupported` ones are listed in its summary with the capabilities they lack.

## Documentation captures

`--deterministic` makes a run a documentation capture:

- **Virtual timing**: no waits are enacted, and the timeline in the manifest (and in a
  cast) is the scenario's own — pacing, dwells and lead-ins — never how long the machine
  took.
- **Environment substitutions**: `--env NAME=VALUE`, given to the stage as `$env`; the
  binding sets them for the application it starts.
- **Pinned regions**: `--pin <locator>` names a volatile region (a clock, a timestamp);
  every capture and cast frame masks it. Masking is a capability, `record.mask`: on a
  backend without it, a run with `--pin` is `unsupported` before anything runs.
- **Stability**: every `capture` is taken twice, 1.2 s apart. If anything else changed, the
  run fails — `an undeclared volatile region` — rather than publishing an unstable
  capture. Text and cast captures must be byte-identical; PNG captures must reach the
  SSIM of `--pixel-threshold` (default 0.995), a different guarantee from byte equality.

Two deterministic runs of the same scenario on a text backend produce byte-identical
captures and casts.

## Citations

A page cites a capture by scenario and capture name, never by a path:

```text
dvs capture-path scenario=notes/archive-from-keyboard capture=after-archive
dvs capture-path scenario=notes/archive-from-keyboard steps=3..5
```

The first prints the files of the capture, looked up in the newest run's manifest by the
step that produced it. The second prints the session media and the span from the start of
step 3 to the end of step 5 on its own timeline (virtual time for a deterministic run), so
a re-recorded cast does not move the span. `--backend` and `--build` select the runs.
