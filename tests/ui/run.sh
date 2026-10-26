#!/bin/sh
# Runs every tests/ui/*.txt script headlessly against the chat fixture
# (fixture day 2026-10-26, UTC).
set -e
cd "$(dirname "$0")/../.."
./build.sh debug
fail=0
for s in tests/ui/*.txt; do
  name=$(basename "$s" .txt)
  # fixed clock and zone: message header timestamps are part of selections
  if TZ=UTC ./build/fastcord-debug -shot:build/ui-$name.png -dpi:1 -now:1793016000 -fixture:tests/ui/chat.jsonl -channel:1546820603343016006 -script:"$s"; then
    echo "PASS $name"
  else
    echo "FAIL $name"; fail=1
  fi
done
exit $fail
