#!/usr/bin/env bash
# The neutrality rule, as a gate: this repository knows no project's vocabulary.
#
# The format defines how page objects are declared, located, observed and acted
# on; it never declares one. Words that belong to one kind of application (a
# debugger's panes, editors, breakpoints, call stacks, traces) must not appear
# in the schemas, sources, conformance application, corpus or documentation.
#
# "tab" is deliberately not in the list: `Tab` is a key name of the format's own
# key vocabulary, and a tab character is what YAML forbids for indentation.
#
# A line may opt out with the marker `neutrality: allow` and a reason; there is
# one such line today: the planted word of the self-test in the Justfile.
#
#   tests/neutrality_scan.sh [path...]     (default: every tracked file)
set -euo pipefail
cd "$(dirname "$0")/.."
words='pane|panes|editor|editors|breakpoint|breakpoints|call[ -]stack|debugger|debuggee|codetracer|stack[ -]frame|replay[ -]server'
if [[ $# -gt 0 ]]; then
	files=("$@")
else
	# Lockfiles record upstream inputs' names, not this repository's content.
	mapfile -t files < <(git ls-files | grep -vE '^(tests/neutrality_scan.sh|flake.lock)$')
fi
found=0
for f in "${files[@]}"; do
	[[ -f $f ]] || continue
	if grep -nIiwE "$words" "$f" | grep -v 'neutrality: allow' | sed "s|^|$f:|"; then
		found=1
	fi
done
if [[ $found -ne 0 ]]; then
	echo "neutrality: project vocabulary found (see above); it belongs in a project's pack" >&2
	exit 1
fi
echo "neutrality: clean (${#files[@]} files)"
