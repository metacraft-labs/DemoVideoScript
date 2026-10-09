# DemoVideoScript

Project-neutral scenario format and runner: one script drives UI tests, documentation captures and demo videos on terminal, GUI and browser backends.

> **Status:** ☐ Planned — design stage; no implementation yet.

A *scenario* describes what a user does to an application and what they then see:
a declared **stage** that sets up initial conditions, followed by **steps** that are only
user input (keys, chords, typing, pointer gestures), observations of page objects, and
waits on named conditions. The same scenario file runs unchanged against a terminal, a
native window, a web or Electron application, or a WebDriver target, and serves as a UI
test, a test-run recording, a documentation capture, and the raw material of a narrated
video.

This repository will hold the format's JSON Schemas, the parser and linter, the single
runner that interprets scenarios, and a small conformance application with its scenario
corpus. Backends live in their own repositories:

- [DemoVideoScript-TermAssert](https://github.com/metacraft-labs/DemoVideoScript-TermAssert) — terminal applications
- [DemoVideoScript-GuiAssert](https://github.com/metacraft-labs/DemoVideoScript-GuiAssert) — native windows
- [DemoVideoScript-Playwright](https://github.com/metacraft-labs/DemoVideoScript-Playwright) — web and Electron applications
- [DemoVideoScript-WebDriverIO](https://github.com/metacraft-labs/DemoVideoScript-WebDriverIO) — WebDriver targets such as VS Code extensions

Videos are produced with [DemoVideoStudio](https://github.com/metacraft-labs/DemoVideoStudio).

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
