#!/bin/sh
# run.sh <scenario>...  — record ours, scrub, diff vs traffic/<scenario>.jsonl.
# Run from the repo root. Raw recordings stay in .secrets/raw (gitignored).
set -e
cd "$(dirname "$0")/../../.."
FLAGS="-collection:fc=src -vet-shadowing -strict-style"
# PARITY_NOBUILD=1: use the existing build/parity (keeps a long pass stable while sources change)
[ -n "$PARITY_NOBUILD" ] || odin build src/discord/parity -out:build/parity $FLAGS
[ -x build/scrub ] || ./build.sh tool scrub
[ -x build/trafficdiff ] || ./build.sh tool trafficdiff
mkdir -p .secrets/raw .secrets/ours
status=0
for s in "$@"; do
  rm -f ".secrets/raw/ours_$s.jsonl.netlog-a" ".secrets/raw/ours_$s.jsonl.netlog-b"
  build/parity "$s" ".secrets/raw/ours_$s.jsonl"
  raw=".secrets/raw/ours_$s.jsonl"
  nl=""
  [ -f "$raw.netlog-a" ] && nl="$nl -netlog-a:$raw.netlog-a"
  [ -f "$raw.netlog-b" ] && nl="$nl -netlog-b:$raw.netlog-b"
  build/scrub "$raw" ".secrets/ours/$s.jsonl" $nl
  if [ -f "traffic/$s.jsonl" ]; then
    build/trafficdiff "traffic/$s.jsonl" ".secrets/ours/$s.jsonl" || status=1
  else
    echo "no official fixture traffic/$s.jsonl yet"
  fi
  sleep "${PARITY_SLEEP:-45}"
done
exit $status
