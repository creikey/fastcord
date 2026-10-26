#!/bin/sh
# session.sh [scenario...] — one human-paced session: A launches once (cold_start),
# B the first time a scenario uses it, then every scenario in turn, each
# recorded separately and diffed against its fixture's action windows.
# Run from anywhere; raw recordings stay in .secrets/raw (gitignored).
set -e
cd "$(dirname "$0")/../../.."
FLAGS="-collection:fc=src -vet-shadowing -strict-style"
odin build src/discord/parity -out:build/parity $FLAGS
./build.sh tool scrub >/dev/null
./build.sh tool trafficdiff >/dev/null
mkdir -p .secrets/raw .secrets/ours
if [ $# -eq 0 ]; then
  set -- cold_start send_message typing add_reaction remove_reaction delete_message \
    edit_message reply upload_image open_profile_popout open_full_profile \
    emoji_picker_reaction add_custom_reaction gif_send open_image_attachment \
    scroll_history quick_switcher_nav switch_theme join_voice_channel status_change \
    custom_status open_guild_and_channel open_dm close_dm start_group_dm create_guild \
    _cleanup mark_as_read voice_with_b _reset_friendship friend_request_send \
    friend_request_accept send_dm friend_remove
fi
for s in "$@"; do rm -f ".secrets/raw/ours_$s.jsonl.netlog-a" ".secrets/raw/ours_$s.jsonl.netlog-b"; done
build/parity session .secrets/raw "$@"
CORE="-ignore:/science -ignore:/assets/ -ignore:collectibles-shop -ignore:latency.discord.media -ignore:/cdn-cgi/"
printf '%-24s %5s %5s\n' scenario all core
for s in "$@"; do
  raw=".secrets/raw/ours_$s.jsonl"
  nl=""
  [ -f "$raw.netlog-a" ] && nl="$nl -netlog-a:$raw.netlog-a"
  [ -f "$raw.netlog-b" ] && nl="$nl -netlog-b:$raw.netlog-b"
  build/scrub "$raw" ".secrets/ours/$s.jsonl" $nl >/dev/null
  [ -f "traffic/$s.jsonl" ] || continue
  mode="-actions"
  [ "$s" = cold_start ] && mode=""
  build/trafficdiff $mode "traffic/$s.jsonl" ".secrets/ours/$s.jsonl" > ".secrets/ours/$s.diff" || true
  all=$(tail -1 ".secrets/ours/$s.diff" | sed 's/traffic matches/0/' | cut -d' ' -f1)
  # shellcheck disable=SC2086
  core=$(build/trafficdiff $mode $CORE "traffic/$s.jsonl" ".secrets/ours/$s.jsonl" | tail -1 | sed 's/traffic matches/0/' | cut -d' ' -f1)
  printf '%-24s %5s %5s\n' "$s" "$all" "$core"
done
