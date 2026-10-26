#!/bin/sh
# chrome_color_fixtures.sh <size> <svg>... : headless Chrome renders each SVG in an
# <img> at <size>px on a transparent page -> <svg>.chrome<size>.png
# (src/vector/testdata/color/*.chrome72.png; also used for the Twemoji comparison).
S=$1; shift
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
T=$(mktemp -d)
for f in "$@"; do
  a=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
  printf '<html><body style="margin:0;background:transparent"><img src="%s" width="%s" height="%s" style="display:block"></body></html>' "$a" "$S" "$S" > "$T/p.html"
  "$CH" --headless=new --disable-gpu --force-device-scale-factor=1 --hide-scrollbars --default-background-color=00000000 \
    --window-size="$S,$S" --allow-file-access-from-files --user-data-dir="$T/prof" --screenshot="${f%.svg}.chrome$S.png" "file://$T/p.html" >/dev/null 2>&1
done
