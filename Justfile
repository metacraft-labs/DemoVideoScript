## Justfile - DemoVideoScript.
##
## Build outputs go under BUILD_DIR (default: build/, ignored by git).

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

build_dir := env_var_or_default("BUILD_DIR", "build")
dvs := build_dir / "bin/dvs"
nim_flags := "--hints:off --styleCheck:usages --styleCheck:error --path:src"
unit_suites := "test_grammar test_yaml test_predicates"

# Build the `dvs` command line.
build:
    @mkdir -p {{build_dir}}/bin
    nim c {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/dvs -o:{{dvs}} src/dvs.nim

# Unit suites, the command-line suite against the built binary, and the
# schema/parser agreement check against independent reference implementations.
test: build test-unit test-cli test-schema-agreement test-neutrality-self

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
    @for t in {{unit_suites}} test_cli; do nim check {{nim_flags}} tests/$t.nim; done

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
