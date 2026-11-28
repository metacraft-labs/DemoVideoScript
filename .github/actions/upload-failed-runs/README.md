# upload-failed-runs

Uploads the run directories of failed DemoVideoScript runs (those with a `failure/`
directory) under `<build-dir>/scenario-runs` as one job artifact. Passing runs and the rest
of the build directory are not uploaded.

```yaml
- if: failure()
  uses: metacraft-labs/DemoVideoScript/.github/actions/upload-failed-runs@<commit>
  with:
    build-dir: build
    name: scenario-runs-<lane>
```

## The recordings in the artifact

A run directory keeps everything the run wrote. For each lossless recording an arm wrote
(`session.mkv`, or `session.<client>.mkv` with several clients), the action adds one file
beside it:

| File | What it is for |
|---|---|
| `session*.mkv` | The evidence: the frames exactly as recorded (H.264 RGB at qp 0). Compare pixels, or cut stills, from this one. |
| `session*.mp4` | For viewing: H.264 4:2:0 at CRF 28 that any browser plays, at the recording's size (an odd edge cropped to even, never scaled), with `faststart`. |

The copy needs `ffmpeg` on the runner (or `FFMPEG_BIN`). Without one, the action says so
and the runs carry only their lossless recordings.

`collect.sh` is the step itself, and `tests/upload_failed_runs_test.sh` tests it.
