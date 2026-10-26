#!/bin/sh
# run.sh <scenario>...  — record ours, scrub, diff vs traffic/<scenario>.jsonl.
# Run from the repo root. Raw recordings stay in .secrets/raw (gitignored).
set -e
cd "$(dirname "$0")/../../.."
FLAGS="-collection:fc=src -vet-shadowing -strict-style"
odin build src/discord/parity -out:build/parity $FLAGS
[ -x build/scrub ] || ./build.sh tool scrub
[ -x build/trafficdiff ] || ./build.sh tool trafficdiff
mkdir -p .secrets/raw .secrets/ours
status=0
for s in "$@"; do
  build/parity "$s" ".secrets/raw/ours_$s.jsonl"
  build/scrub ".secrets/raw/ours_$s.jsonl" ".secrets/ours/$s.jsonl"
  if [ -f "traffic/$s.jsonl" ]; then
    build/trafficdiff "traffic/$s.jsonl" ".secrets/ours/$s.jsonl" || status=1
  else
    echo "no official fixture traffic/$s.jsonl yet"
  fi
  sleep 45
done
exit $status
