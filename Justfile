## Justfile - DemoVideoScript.
##
## Build outputs go under BUILD_DIR (default: build/, ignored by git).

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

build_dir := env_var_or_default("BUILD_DIR", "build")
dvs := build_dir / "bin/dvs"
nim_flags := "--hints:off --styleCheck:usages --styleCheck:error --path:src"
unit_suites := "test_grammar test_yaml test_predicates test_regex test_pacing"
bin := build_dir / "bin"

# Build `dvs`, the reference backend (`dvs-refapp` over JSON lines, `dvs-ref`
# with it in process) and the deliberately broken backend the transport tests
# use. The test suites never build these themselves.
build:
    @mkdir -p {{bin}}
    nim c {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/dvs -o:{{dvs}} src/dvs.nim
    nim c {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/dvs-refapp -o:{{bin}}/dvs-refapp conformance/refapp/dvs_refapp.nim
    nim c {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/dvs-ref -o:{{bin}}/dvs-ref conformance/refapp/dvs_ref.nim
    nim c {{nim_flags}} --nimcache:{{build_dir}}/nimcache/broken-backend -o:{{bin}}/broken-backend tests/support/broken_backend.nim
    nim c {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/notes-tui -o:{{bin}}/notes-tui conformance/app/notes_tui.nim
    just build-web

# The conformance application's web build: build/web/{index.html,notes_web.js}.
build-web:
    @mkdir -p {{build_dir}}/web
    nim js {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/notes-web -o:{{build_dir}}/web/notes_web.js conformance/app/notes_web.nim
    cp conformance/app/web/index.html {{build_dir}}/web/index.html

# Unit suites, the command-line suite against the built binary, and the
# schema/parser agreement check against independent reference implementations.
test: build test-unit test-cli test-schema-agreement test-neutrality-self test-runner test-protocol test-conformance

test-unit:
    @mkdir -p {{build_dir}}/test-bin
    @for t in {{unit_suites}}; do \
      echo "== $t"; \
      nim c -r {{nim_flags}} --nimcache:{{build_dir}}/nimcache/$t -o:{{build_dir}}/test-bin/$t tests/$t.nim; \
    done

# The command-line suite needs the binary; `test` builds it first.
test-cli:
    @mkdir -p {{build_dir}}/test-bin
    DVS_BIN={{dvs}} nim c -r {{nim_flags}} --nimcache:{{build_dir}}/nimcache/test_cli -o:{{build_dir}}/test-bin/test_cli tests/test_cli.nim

# The runner against the reference backend, in process and over JSON lines.
test-runner:
    DVS_BIN_DIR={{bin}} nim c -r {{nim_flags}} --nimcache:{{build_dir}}/nimcache/test_runner -o:{{build_dir}}/test-bin/test_runner tests/test_runner.nim

# Every protocol message, both directions, against the published schema.
test-protocol:
    python3 tests/protocol_conformance.py {{dvs}} conformance/pack/notes-app.pack.yaml "cmd:{{bin}}/dvs-refapp" conformance/scenarios/*.yaml

# The conformance suite (fast and realistic) with every planted defect.
test-conformance:
    {{bin}}/dvs-ref conformance --pack conformance/pack/notes-app.pack.yaml --backend "cmd:{{bin}}/dvs-refapp" \
      --defect stale-read="cmd:{{bin}}/dvs-refapp --defect=stale-read" \
      --defect off-by-one="cmd:{{bin}}/dvs-refapp --defect=off-by-one" \
      --defect early-sync="cmd:{{bin}}/dvs-refapp --defect=early-sync" \
      --defect read-side-effect="cmd:{{bin}}/dvs-refapp --defect=read-side-effect" \
      conformance/scenarios/*.yaml

test-schema-agreement:
    python3 tests/schema_agreement.py {{dvs}}

# The neutrality scan must fail on a planted word, or it checks nothing.
test-neutrality-self:
    #!/usr/bin/env bash
    set -euo pipefail
    planted=$(mktemp --suffix=.md)
    trap 'rm -f "$planted"' EXIT
    echo "Click the editor pane." > "$planted"  # neutrality: allow (the planted word of the self-test)
    if bash tests/neutrality_scan.sh "$planted" >/dev/null 2>&1; then
      echo "neutrality scan did not catch a planted word" >&2; exit 1
    fi
    echo "neutrality scan catches a planted word"

lint: lint-schemas lint-nim lint-corpus lint-neutrality lint-nix

# The committed schemas equal the generator's output.
lint-schemas:
    python3 tools/generate_schemas.py --check

lint-nim:
    nim check {{nim_flags}} src/dvs.nim
    @for t in {{unit_suites}} test_cli test_runner; do nim check {{nim_flags}} tests/$t.nim; done
    nim check {{nim_flags}} conformance/refapp/dvs_ref.nim

# The conformance corpus lints clean against its pack.
lint-corpus: build
    {{dvs}} lint --pack conformance/pack/notes-app.pack.yaml conformance/scenarios/*.yaml

lint-neutrality:
    bash tests/neutrality_scan.sh

lint-nix:
    nixfmt --check flake.nix

format: format-nix format-schemas

format-nix:
    nixfmt flake.nix

format-schemas:
    python3 tools/generate_schemas.py

clean:
    rm -rf {{build_dir}}
