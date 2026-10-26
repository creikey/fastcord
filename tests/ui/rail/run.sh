#!/bin/sh
# Rail / DM / profile scripts against tests/ui/rail.jsonl (extra guilds, a
# folder, unread mentions, DMs, friends). Regenerate the fixture with
# python3 -I tests/ui/make_rail_fixture.py.
set -e
cd "$(dirname "$0")/../../.."
./build.sh debug
fail=0
for s in tests/ui/rail/*.txt; do
  name=$(basename "$s" .txt)
  if ./build/fastcord-debug -shot:build/ui-$name.png -dpi:1 -fixture:tests/ui/rail.jsonl -channel:1546820603343016006 -script:"$s"; then
    echo "PASS $name"
  else
    echo "FAIL $name"; fail=1
  fi
done
exit $fail
