#!/bin/sh
# Runs every tests/ui/*.txt script headlessly against the chat fixture
# (fixture day 2026-10-26, UTC), the tests/ui/rail/*.txt scripts against the
# rail fixture, then the dead-control sweep (tests/ui/sweep.txt; report and crops
# in build/sweep/). SWEEP=0 skips the sweep (it takes a minute or two).
set -e
cd "$(dirname "$0")/../.."
./build.sh debug
fail=0
for s in tests/ui/*.txt; do
  case "$(basename "$s")" in sweep.txt|sweep_allow.txt) continue;; esac  # sweep spec/allowlist, not scripts
  name=$(basename "$s" .txt)
  # fixed clock and zone: message header timestamps are part of selections
  if TZ=UTC ./build/fastcord-debug -shot:build/ui-$name.png -dpi:1 -now:1793016000 -fixture:tests/ui/chat.jsonl -channel:1546820603343016006 -script:"$s"; then
    echo "PASS $name"
  else
    echo "FAIL $name"; fail=1
  fi
done
for s in tests/ui/rail/*.txt; do
  name=$(basename "$s" .txt)
  if TZ=UTC ./build/fastcord-debug -shot:build/ui-$name.png -dpi:1 -now:1793016000 -fixture:tests/ui/rail.jsonl -channel:1546820603343016006 -script:"$s"; then
    echo "PASS rail/$name"
  else
    echo "FAIL rail/$name"; fail=1
  fi
done
if [ "${SWEEP:-1}" != 0 ]; then
  rm -rf build/sweep
  if TZ=UTC ./build/fastcord-debug -shot:build/sweep.png -dpi:1 -now:1793016000 -sweep:tests/ui/sweep.txt; then
    echo "PASS sweep"
  else
    echo "FAIL sweep (see build/sweep/report.txt)"; fail=1
  fi
fi
exit $fail
