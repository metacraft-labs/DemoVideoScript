#!/usr/bin/env bash
# The upload-failed-runs action's collect step (.github/actions/upload-failed-runs/collect.sh)
# on a real scenario-runs tree with real lossless recordings, decoded with the real ffmpeg:
# a failed run is collected with its lossless session.mkv kept and a session.mp4 beside it
# that a browser plays (H.264 4:2:0), as many frames and the same size (an odd edge cropped
# to even, never scaled); a passing run is not collected. No stand-ins.
# Each check is a condition string that check() evaluates, so its variables and the
# probe function are used inside quotes, where shellcheck cannot see them.
# shellcheck disable=SC2016,SC2034,SC2329
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
collect="$root/.github/actions/upload-failed-runs/collect.sh"
ffmpeg="${FFMPEG_BIN:-ffmpeg}"
ffprobe="${ffmpeg%ffmpeg}ffprobe"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }
probe() { "$ffprobe" -v error -select_streams v:0 -count_frames -show_entries "stream=$2" -of csv=p=0 "$1"; }

# a lossless recording as the arms write it: H.264 RGB at qp 0, in Matroska
lossless() { "$ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=$2:rate=10:duration=3" \
	-c:v libx264rgb -qp 0 -preset ultrafast -pix_fmt rgb24 "$1"; }
b="$work/build/scenario-runs"
mkdir -p "$b/s/playwright/run-a/failure" "$b/s/playwright/run-b/failure" "$b/s/playwright/run-ok"
lossless "$b/s/playwright/run-a/session.mkv" 640x360
lossless "$b/s/playwright/run-b/session.b.mkv" 641x359
lossless "$b/s/playwright/run-ok/session.mkv" 640x360
echo '{}' >"$b/s/playwright/run-a/manifest.json"

found="$(bash "$collect" "$work/build" "$work/out" | sed -n 's/^found=//p')"
o="$work/out/s/playwright"
check "the two failed runs are found" '[ "$found" = 2 ]'
check "a passing run is not collected" '[ ! -e "$o/run-ok" ]'
check "the run's files are copied" '[ -f "$o/run-a/manifest.json" ]'
check "the lossless recording is kept" '[ -f "$o/run-a/session.mkv" ] && [ "$(probe "$o/run-a/session.mkv" pix_fmt)" = gbrp ]'
check "a viewable copy is beside it, H.264 4:2:0" '[ "$(probe "$o/run-a/session.mp4" codec_name,pix_fmt)" = "h264,yuv420p" ]'
check "as many frames, at the same size" \
	'[ "$(probe "$o/run-a/session.mp4" width,height,nb_read_frames)" = "$(probe "$o/run-a/session.mkv" width,height,nb_read_frames)" ]'
check "smaller than the lossless recording" '[ "$(stat -c %s "$o/run-a/session.mp4")" -lt "$(stat -c %s "$o/run-a/session.mkv")" ]'
check "a client's recording gets its copy too, its odd edges cropped to even" \
	'[ "$(probe "$o/run-b/session.b.mp4" width,height)" = "640,358" ] && [ -f "$o/run-b/session.b.mkv" ]'
check "the copy starts playing before it has all loaded (faststart)" \
	'head -c 64 "$o/run-a/session.mp4" | grep -aq moov || head -c 4096 "$o/run-a/session.mp4" | grep -aq moov'
[ "$fail" = 0 ] && echo "upload-failed-runs: ok"
exit "$fail"
