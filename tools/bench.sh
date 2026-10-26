#!/bin/sh
# UI benchmark: builds build/fastcord-dev, makes the fixture if it is missing or stale, runs every
# tests/bench/*.txt headless against it, profiles each, and compares with the saved baseline and the
# counter budget.
#   tools/bench.sh            run all; compare with build/bench/baseline.jsonl and tests/bench/budget.json
#   tools/bench.sh chat       run only tests/bench/chat.txt
#   tools/bench.sh --save     run all, then save the result as the new local baseline
#   tools/bench.sh --live     run tests/bench/account.txt on the real account (read-only) and on the
#                             fixture, side by side; writes build/bench/shape.json, the live account's shape.
#                             Copy it to tests/bench/shape.json to make the fixture follow the account.
# Outputs in build/bench/: latest.jsonl, <script>.txt (profile report), <script>.folded (stacks for
# tools/folded.py or speedscope.app). See README "Performance".
cd "$(dirname "$0")/.."
set -e
save=0
live=0
only=""
for a in "$@"; do
  case $a in --save) save=1 ;; --live) live=1 ;; *) only=$a ;; esac
done
EXE=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; esac
PY=python3
# Windows ships a python3 alias that only opens the Store, so probe by running it.
$PY -c '' >/dev/null 2>&1 || PY=python
./build.sh dev
mkdir -p build/bench
GEN=tests/bench/make_bench_fixture.py
SHAPE=tests/bench/shape.json
if [ ! -f build/bench/heavy.jsonl ] || [ $GEN -nt build/bench/heavy.jsonl ] || [ $SHAPE -nt build/bench/heavy.jsonl ]; then
  $PY -I $GEN build/bench/heavy.jsonl $SHAPE
fi
# Avatars, icons and emoji come from build/bench/media instead of the CDN. TZ and -now pin timestamps
# and grouping, so counters are the same on every machine.
fixture() {
  FASTCORD_MEDIA_DIR=build/bench/media TZ=UTC ./build/fastcord-dev$EXE -dpi:1 -now:1793016000 -fixture:build/bench/heavy.jsonl "$@"
}
if [ $live = 1 ]; then
  rm -f build/bench/live.jsonl build/bench/fixture.jsonl
  ./build/fastcord-dev$EXE -bench:build/bench/live.jsonl -dpi:1 -live:15 -shape:build/bench/shape.json \
    -script:tests/bench/account.txt > build/bench/live.log 2>&1 || { echo "FAIL live run (see build/bench/live.log)"; exit 1; }
  fixture -bench:build/bench/fixture.jsonl -shape:build/bench/fixture_shape.json -script:tests/bench/account.txt \
    > build/bench/fixture.log 2>&1 || { echo "FAIL fixture run (see build/bench/fixture.log)"; exit 1; }
  echo "live account (baseline column: the fixture; near 1.00x means they match):"
  $PY -I tools/bench_compare.py build/bench/live.jsonl --baseline build/bench/fixture.jsonl
  $PY -I - build/bench/shape.json build/bench/fixture_shape.json <<'EOF'
import json, sys
a, b = (json.load(open(p, encoding='utf-8')) for p in sys.argv[1:3])
diff = [k for k in a if k != 'rail' and a[k] != b.get(k)]
print('shape: ' + (', '.join('%s live %s fixture %s' % (k, a[k], b.get(k)) for k in diff) or 'counts match'))
print('rail: ' + ('matches' if a.get('rail') == b.get('rail') else 'differs'))
EOF
  exit 0
fi
rm -f build/bench/latest.jsonl
for s in tests/bench/*.txt; do
  name=$(basename "$s" .txt)
  [ -z "$only" ] || [ "$only" = "$name" ] || continue
  # account.txt starts at home like a fresh launch; the others open the bench channel.
  ch=-channel:1600000000000100003
  [ "$name" = account ] && ch=""
  fixture -bench:build/bench/latest.jsonl -prof:build/bench/$name $ch -script:"$s" > build/bench/$name.log 2>&1 \
    || { echo "FAIL $s (see build/bench/$name.log)"; tail -20 build/bench/$name.log; exit 1; }
done
set +e
$PY -I tools/bench_compare.py build/bench/latest.jsonl --baseline build/bench/baseline.jsonl --budget tests/bench/budget.json
rc=$?
[ $save = 1 ] && cp build/bench/latest.jsonl build/bench/baseline.jsonl && echo "saved build/bench/baseline.jsonl"
exit $rc
