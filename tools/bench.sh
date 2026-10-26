#!/bin/sh
# UI benchmark: builds build/fastcord-dev, makes the fixture if missing, runs every tests/bench/*.txt
# headless against it, profiles each, and compares with the saved baseline and the counter budget.
#   tools/bench.sh            run all; compare with build/bench/baseline.jsonl and tests/bench/budget.json
#   tools/bench.sh chat       run only tests/bench/chat.txt
#   tools/bench.sh --save     run all, then save the result as the new local baseline
# Outputs in build/bench/: latest.jsonl, <script>.txt (profile report), <script>.folded (stacks for
# tools/folded.py or speedscope.app). See README "Performance".
cd "$(dirname "$0")/.."
set -e
save=0
only=""
for a in "$@"; do
  case $a in --save) save=1 ;; *) only=$a ;; esac
done
EXE=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; esac
PY=python3
# Windows ships a python3 alias that only opens the Store, so probe by running it.
$PY -c '' >/dev/null 2>&1 || PY=python
./build.sh dev
mkdir -p build/bench
[ -f build/bench/heavy.jsonl ] || $PY -I tests/bench/make_bench_fixture.py build/bench/heavy.jsonl
rm -f build/bench/latest.jsonl
for s in tests/bench/*.txt; do
  name=$(basename "$s" .txt)
  [ -z "$only" ] || [ "$only" = "$name" ] || continue
  # TZ and -now pin timestamps and grouping, so counters are the same on every machine.
  TZ=UTC ./build/fastcord-dev$EXE -bench:build/bench/latest.jsonl -prof:build/bench/$name -dpi:1 -now:1793016000 \
    -fixture:build/bench/heavy.jsonl -channel:1600000000000100003 -script:"$s" > build/bench/$name.log 2>&1 \
    || { echo "FAIL $s (see build/bench/$name.log)"; tail -20 build/bench/$name.log; exit 1; }
done
set +e
$PY -I tools/bench_compare.py build/bench/latest.jsonl --baseline build/bench/baseline.jsonl --budget tests/bench/budget.json
rc=$?
[ $save = 1 ] && cp build/bench/latest.jsonl build/bench/baseline.jsonl && echo "saved build/bench/baseline.jsonl"
exit $rc
