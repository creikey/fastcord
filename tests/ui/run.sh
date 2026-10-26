#!/bin/sh
# Runs every tests/ui/*.txt script headlessly against the chat fixture
# (fixture day 2026-10-26, UTC), the tests/ui/rail/*.txt scripts against the
# rail fixture, then the dead-control sweep (tests/ui/sweep.txt; report and crops
# in build/sweep/). SWEEP=0 skips the sweep (it takes a minute or two).
set -e
cd "$(dirname "$0")/../.."
./build.sh debug
fail=0
mkdir -p build/uires
rm -f build/uires/*
# Every script (and the sweep) is its own headless process; they run in parallel
# and their results print in a fixed order at the end.
run_script() { # <result name> <fixture> <script>
  if TZ=UTC ./build/fastcord-debug -shot:build/ui-$(basename "$3" .txt).png -dpi:1 -now:1793016000 -fixture:"$2" -channel:1546820603343016006 -script:"$3" > "build/uires/$1.log" 2>&1; then
    echo "PASS $1" > "build/uires/$1.res"
  else
    { echo "FAIL $1"; sed 's/^/    /' "build/uires/$1.log"; } > "build/uires/$1.res"
  fi
}
names=""
for s in tests/ui/*.txt; do
  case "$(basename "$s")" in sweep.txt|sweep_allow.txt) continue;; esac  # sweep spec/allowlist, not scripts
  # fixed clock and zone: message header timestamps are part of selections
  n=$(basename "$s" .txt); names="$names $n"
  run_script "$n" tests/ui/chat.jsonl "$s" &
done
for s in tests/ui/rail/*.txt; do
  n=rail_$(basename "$s" .txt); names="$names $n"
  run_script "$n" tests/ui/rail.jsonl "$s" &
done
if [ "${SWEEP:-1}" != 0 ]; then
  rm -rf build/sweep
  names="$names sweep"
  ( if TZ=UTC ./build/fastcord-debug -shot:build/sweep.png -dpi:1 -now:1793016000 -sweep:tests/ui/sweep.txt > build/uires/sweep.log 2>&1; then
      echo "PASS sweep" > build/uires/sweep.res
    else
      { echo "FAIL sweep (see build/sweep/report.txt)"; tail -30 build/uires/sweep.log | sed 's/^/    /'; } > build/uires/sweep.res
    fi ) &
fi
wait
for n in $names; do
  cat "build/uires/$n.res"
  grep -q "^FAIL" "build/uires/$n.res" && fail=1
done
exit $fail
