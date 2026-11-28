#!/usr/bin/env bash
# collect.sh <build-dir> <out-dir>: copies every failed DemoVideoScript run (a run directory
# with a failure/ subdirectory) under <build-dir>/scenario-runs into <out-dir>, and beside each
# lossless recording (session*.mkv) writes a copy a browser plays (session*.mp4: H.264 4:2:0,
# CRF 28, even size by cropping, never scaling). The .mkv is kept: it is the pixel-exact
# evidence; the .mp4 is for viewing. Prints the number of runs found as `found=N`.
# FFMPEG_BIN names the ffmpeg to use; without one on PATH, the copies are skipped with a note.
set -euo pipefail
build="$1"
out="$2"
ffmpeg="${FFMPEG_BIN:-ffmpeg}"
rm -rf "$out"
mkdir -p "$out"
found=0
if [ -d "$build/scenario-runs" ]; then
	while IFS= read -r -d '' f; do
		run="$(dirname "$f")"
		rel="${run#"$build/scenario-runs/"}"
		mkdir -p "$out/$rel"
		cp -R "$run/." "$out/$rel/"
		found=$((found + 1))
	done < <(find "$build/scenario-runs" -mindepth 4 -maxdepth 4 -type d -name failure -print0)
fi
if ! command -v "$ffmpeg" >/dev/null 2>&1; then
	[ "$found" -gt 0 ] && echo "collect: no ffmpeg; the runs carry their lossless recordings only" >&2
else
	while IFS= read -r -d '' mkv; do
		mp4="${mkv%.mkv}.mp4"
		if ! "$ffmpeg" -hide_banner -loglevel error -nostdin -y -i "$mkv" \
			-map 0:v:0 -map '0:a?' -vf 'crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0' \
			-c:v libx264 -pix_fmt yuv420p -crf 28 -preset veryfast -threads 4 \
			-c:a aac -movflags +faststart "$mp4"; then
			echo "collect: could not make a viewable copy of $mkv" >&2
			rm -f "$mp4"
		fi
	done < <(find "$out" -type f -name 'session*.mkv' -print0)
fi
echo "found=$found"
