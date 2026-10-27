## `dvs` — the DemoVideoScript command line (see demo_video_script/cli.nim).
## Out-of-process backends are reached with `--backend cmd:PROGRAM`.

import demo_video_script/cli

when isMainModule: dvsMain()
